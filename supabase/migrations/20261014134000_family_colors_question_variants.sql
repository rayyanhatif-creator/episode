-- Assign a persistent color to each family and bind question variants to that color.
alter table public.family_codes
  add column if not exists color text not null default 'white';
alter table public.teams
  add column if not exists color text not null default 'white';

alter table public.family_codes drop constraint if exists family_codes_color_check;
alter table public.family_codes add constraint family_codes_color_check
  check (color in ('white','blue','yellow'));
alter table public.teams drop constraint if exists teams_color_check;
alter table public.teams add constraint teams_color_check
  check (color in ('white','blue','yellow'));

update public.teams t
set color = fc.color
from public.family_codes fc
where fc.used_by_team = t.id
  and t.color is distinct from fc.color;

update public.team_stage_assignments a
set question_id = q.id
from public.teams t, public.stage_questions q
where a.team_id = t.id
  and q.stage_id = a.stage_id
  and q.variant_no = case t.color when 'white' then 1 when 'blue' then 2 when 'yellow' then 3 else 1 end
  and a.completed = false
  and a.question_id is distinct from q.id;

create or replace view public.public_leaderboard as
select id, name, points, progress, color
from public.teams
where is_active = true;

create or replace function public.join_game(p_team_name text,p_session_code text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare cfg public.game_settings%rowtype; tok text; tok_hash text; t public.teams%rowtype; fc public.family_codes%rowtype;
begin
 select * into cfg from public.game_settings where id=true;
 if not found then return jsonb_build_object('success',false,'message','إعدادات المسابقة غير جاهزة.'); end if;
 if char_length(trim(coalesce(p_team_name,''))) not between 2 and 50 then return jsonb_build_object('success',false,'message','اكتب اسم الفريق بين حرفين و50 حرفًا.'); end if;
 select * into fc from public.family_codes where code_hash=encode(extensions.digest(lower(trim(p_session_code)),'sha256'),'hex') and is_active=true for update;
 if not found then return jsonb_build_object('success',false,'message','رمز الأسرة غير صحيح أو غير فعال. اطلب الرمز من المشرف.'); end if;
 tok:=encode(extensions.gen_random_bytes(32),'hex'); tok_hash:=encode(extensions.digest(tok,'sha256'),'hex');
 if fc.used_by_team is null then
  insert into public.teams(name,session_token_hash,color) values(trim(p_team_name),tok_hash,fc.color) returning * into t;
  update public.family_codes set used_by_team=t.id,used_at=now() where id=fc.id;
 else
  select * into t from public.teams where id=fc.used_by_team and is_active=true for update;
  if not found then return jsonb_build_object('success',false,'message','تعذر العثور على الأسرة. تواصلوا مع المشرف.'); end if;
  if t.color is distinct from fc.color then
   update public.teams set color=fc.color where id=t.id returning * into t;
  end if;
 end if;
 insert into public.team_sessions(team_id,token_hash) values(t.id,tok_hash);
 insert into public.audit_logs(action,entity_type,entity_id,details) values('team_joined','team',t.id::text,jsonb_build_object('team_name',t.name,'family_name',fc.family_name,'color',fc.color));
 return jsonb_build_object('success',true,'team_id',t.id,'team_name',t.name,'color',t.color,'session_token',tok);
exception when unique_violation then return jsonb_build_object('success',false,'message','تعذر إنشاء جلسة جديدة. حاول مرة أخرى.');
end; $$;

create or replace function public.get_team_game_state(p_session_token text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.teams%rowtype; stage_list jsonb; cfg public.game_settings%rowtype; s public.stages%rowtype; target_stage_id uuid;
begin
 if p_session_token is null or char_length(p_session_token)<20 then return jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.'); end if;
 select tm.* into t from public.teams tm where tm.is_active=true and (tm.session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') or exists(select 1 from public.team_sessions ts where ts.team_id=tm.id and ts.token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and ts.is_active=true)) limit 1;
 if not found then return jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); end if;
 select * into cfg from public.game_settings where id=true;
 select st.id into target_stage_id from public.stages st where not exists(select 1 from public.team_stage_assignments a where a.team_id=t.id and a.stage_id=st.id and a.completed=true) and not exists(select 1 from public.answer_submissions olda where olda.team_id=t.id and olda.stage_id=st.id and olda.status='accepted') order by st.sort_order limit 1;
 if target_stage_id is not null then
  select * into s from public.stages where id=target_stage_id;
  insert into public.team_stage_assignments(team_id,stage_id,question_id)
  select t.id,s.id,q.id
  from public.stage_questions q
  where q.stage_id=target_stage_id
    and q.variant_no = case t.color when 'white' then 1 when 'blue' then 2 when 'yellow' then 3 else 1 end
  on conflict(team_id,stage_id) do nothing;
 end if;
 select count(*)::integer into t.progress from public.team_stage_assignments where team_id=t.id and completed=true;
 select coalesce(sum(points_awarded),0)::integer into t.points from public.team_stage_assignments where team_id=t.id and completed=true;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',st.id,'title',st.title,'number',st.number,'description',st.description,'sort_order',st.sort_order,'points_reward',coalesce(q.points_reward,st.points_reward),
  'status',case when coalesce(a.completed,false) or exists(select 1 from public.answer_submissions olda where olda.team_id=t.id and olda.stage_id=st.id and olda.status='accepted') then 'completed' when st.id=target_stage_id then 'current' else 'locked' end,
  'prompt',case when coalesce(cfg.is_open,false) and st.id=target_stage_id then q.prompt else null end,
  'hint',case when coalesce(cfg.is_open,false) and st.id=target_stage_id and coalesce(a.hint_unlocked,false) then q.hint else null end,
  'hint_unlocked',coalesce(a.hint_unlocked,false) and coalesce(cfg.is_open,false) and st.id=target_stage_id,
  'hint_used',coalesce(a.hint_used,false),'final_answer_required',coalesce(a.hint_unlocked,false) and coalesce(cfg.is_open,false) and st.id=target_stage_id,'question_id',q.id
 ) order by st.sort_order),'[]'::jsonb) into stage_list
 from public.stages st left join public.team_stage_assignments a on a.team_id=t.id and a.stage_id=st.id left join public.stage_questions q on q.id=a.question_id;
 return jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress,'color',t.color,'hints_used',t.hints_used,'hints_remaining',greatest(0,3-t.hints_used)),'stages',stage_list);
end; $$;

grant select on public.public_leaderboard to anon, authenticated;
