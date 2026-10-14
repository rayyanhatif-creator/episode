-- Permit multiple participants to share a family/team and track three hint requests per family.
alter table public.teams add column if not exists hints_used integer not null default 0 check (hints_used between 0 and 3);
alter table public.team_stage_assignments add column if not exists hint_used boolean not null default false;
create table if not exists public.team_sessions (
 id uuid primary key default extensions.gen_random_uuid(),
 team_id uuid not null references public.teams(id) on delete cascade,
 token_hash text not null unique,
 created_at timestamptz not null default now(),
 is_active boolean not null default true
);
alter table public.team_sessions enable row level security;
revoke all on public.team_sessions from anon, authenticated;

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
  insert into public.teams(name,session_token_hash) values(trim(p_team_name),tok_hash) returning * into t;
  update public.family_codes set used_by_team=t.id,used_at=now() where id=fc.id;
 else
  select * into t from public.teams where id=fc.used_by_team and is_active=true for update;
  if not found then return jsonb_build_object('success',false,'message','تعذر العثور على الأسرة. تواصلوا مع المشرف.'); end if;
 end if;
 insert into public.team_sessions(team_id,token_hash) values(t.id,tok_hash);
 insert into public.audit_logs(action,entity_type,entity_id,details) values('team_joined','team',t.id::text,jsonb_build_object('team_name',t.name,'family_name',fc.family_name));
 return jsonb_build_object('success',true,'team_id',t.id,'team_name',t.name,'session_token',tok);
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
  select t.id,s.id,q.id from public.stage_questions q left join (select question_id,count(*) assigned_count from public.team_stage_assignments where stage_id=target_stage_id group by question_id) ac on ac.question_id=q.id where q.stage_id=target_stage_id order by coalesce(ac.assigned_count,0),random() limit 1 on conflict(team_id,stage_id) do nothing;
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
 return jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress,'hints_used',t.hints_used,'hints_remaining',greatest(0,3-t.hints_used)),'stages',stage_list);
end; $$;

create or replace function public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text,p_phase text default 'riddle')
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.teams%rowtype; s public.stages%rowtype; a public.team_stage_assignments%rowtype; q public.stage_questions%rowtype; ok boolean; target_stage_id uuid; awarded integer;
begin
 if p_phase not in ('riddle','final') then return jsonb_build_object('success',false,'message','خطوة إجابة غير صالحة.'); end if;
 if p_answer is null or char_length(trim(p_answer))=0 or char_length(p_answer)>200 then return jsonb_build_object('success',false,'message','اكتب إجابة صالحة.'); end if;
 select tm.* into t from public.teams tm where tm.is_active=true and (tm.session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') or exists(select 1 from public.team_sessions ts where ts.team_id=tm.id and ts.token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and ts.is_active=true)) for update;
 if not found then return jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); end if;
 if not coalesce((select is_open from public.game_settings where id=true),false) then return jsonb_build_object('success',false,'message','المشرف أوقف المسابقة مؤقتًا.'); end if;
 select st.id into target_stage_id from public.stages st where not exists(select 1 from public.team_stage_assignments aa where aa.team_id=t.id and aa.stage_id=st.id and aa.completed=true) and not exists(select 1 from public.answer_submissions olda where olda.team_id=t.id and olda.stage_id=st.id and olda.status='accepted') order by st.sort_order limit 1;
 if target_stage_id is null or target_stage_id<>p_stage_id then return jsonb_build_object('success',false,'message','أكملوا المرحلة المتاحة أمامكم أولًا.'); end if;
 select * into s from public.stages where id=p_stage_id;
 select * into a from public.team_stage_assignments where team_id=t.id and stage_id=s.id for update;
 if not found then return jsonb_build_object('success',false,'message','تعذر تجهيز سؤال فريقكم. حدّثوا الصفحة وحاولوا مجددًا.'); end if;
 if a.completed then return jsonb_build_object('success',true,'correct',true,'phase_complete',true,'message','أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.'); end if;
 select * into q from public.stage_questions where id=a.question_id;
 if p_phase='riddle' then
  if a.hint_unlocked then return jsonb_build_object('success',false,'message','لقد فتحتم التلميح بالفعل. أكملوا حل الورقة.'); end if;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.answer_hash;
  insert into public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) values(t.id,s.id,trim(p_answer),ok,case when ok then 'pending' else 'rejected' end);
  if ok then update public.team_stage_assignments set hint_unlocked=true where id=a.id; return jsonb_build_object('success',true,'correct',true,'phase_complete',false,'hint_unlocked',true,'message','إجابة صحيحة! ظهر لكم تلميح مكان الورقة؛ ابحثوا عنها واكتبوا الحل النهائي.'); end if;
  return jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الإجابة غير صحيحة. حاولوا مرة ثانية.');
 else
  if not a.hint_unlocked then return jsonb_build_object('success',false,'message','حلّوا السؤال أولًا لفتح تلميح مكان الورقة.'); end if;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.final_answer_hash;
  insert into public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) values(t.id,s.id,trim(p_answer),ok,case when ok then 'accepted' else 'rejected' end);
  if ok then
   awarded:=case when a.hint_used then floor(q.points_reward/2.0)::integer else q.points_reward end;
   update public.team_stage_assignments set completed=true,points_awarded=awarded,completed_at=now() where id=a.id;
   update public.teams set points=points+awarded,progress=progress+1 where id=t.id;
   insert into public.audit_logs(action,entity_type,entity_id,details) values('stage_completed','stage',s.id::text,jsonb_build_object('team_id',t.id,'question_id',q.id,'points',awarded,'used_hint',a.hint_used));
   return jsonb_build_object('success',true,'correct',true,'phase_complete',true,'points_awarded',awarded,'message',case when a.hint_used then 'حل صحيح! حصلتم على نصف نقاط السؤال لاستخدام التلميحة. ستنتقلون تلقائيًا للمرحلة التالية.' else 'حل صحيح! اكتملت المرحلة وأُضيفت نقاطها إلى رصيدكم. ستنتقلون تلقائيًا إلى المرحلة التالية.' end);
  end if;
  return jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الحل غير صحيح. راجعوا الورقة وحاولوا مرة ثانية.');
 end if;
end; $$;

create or replace function public.request_team_hint(p_session_token text,p_stage_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.teams%rowtype; a public.team_stage_assignments%rowtype; target_stage_id uuid;
begin
 select tm.* into t from public.teams tm where tm.is_active=true and (tm.session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') or exists(select 1 from public.team_sessions ts where ts.team_id=tm.id and ts.token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and ts.is_active=true)) for update;
 if not found then return jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّلوا الدخول مرة أخرى.'); end if;
 if not coalesce((select is_open from public.game_settings where id=true),false) then return jsonb_build_object('success',false,'message','المسابقة متوقفة مؤقتًا.'); end if;
 select st.id into target_stage_id from public.stages st where not exists(select 1 from public.team_stage_assignments aa where aa.team_id=t.id and aa.stage_id=st.id and aa.completed=true) and not exists(select 1 from public.answer_submissions olda where olda.team_id=t.id and olda.stage_id=st.id and olda.status='accepted') order by st.sort_order limit 1;
 if target_stage_id is null or target_stage_id<>p_stage_id then return jsonb_build_object('success',false,'message','يمكن طلب التلميحة للمرحلة الحالية فقط.'); end if;
 select * into a from public.team_stage_assignments where team_id=t.id and stage_id=p_stage_id for update;
 if not found then return jsonb_build_object('success',false,'message','لم يتم تجهيز سؤال هذه المرحلة بعد.'); end if;
 if a.completed then return jsonb_build_object('success',false,'message','هذه المرحلة مكتملة بالفعل.'); end if;
 if a.hint_used then return jsonb_build_object('success',false,'message','استخدمتم تلميحة لهذه المرحلة بالفعل.'); end if;
 if t.hints_used>=3 then return jsonb_build_object('success',false,'message','استهلكتم التلميحات الثلاث المتاحة للأسرة.'); end if;
 update public.team_stage_assignments set hint_used=true where id=a.id;
 update public.teams set hints_used=hints_used+1 where id=t.id returning * into t;
 return jsonb_build_object('success',true,'hints_used',t.hints_used,'hints_remaining',greatest(0,3-t.hints_used),'message','روحوا للمسؤول عن البرنامج يعطيكم التلميحة. عند استخدام التلميحة تحصلون على نصف نقاط السؤال فقط.');
end; $$;

revoke all on function public.request_team_hint(text,uuid) from public;
grant execute on function public.request_team_hint(text,uuid) to anon,authenticated;
grant execute on function public.join_game(text,text) to anon,authenticated;
grant execute on function public.get_team_game_state(text) to anon,authenticated;
grant execute on function public.submit_stage_answer(text,uuid,text,text) to anon,authenticated;
