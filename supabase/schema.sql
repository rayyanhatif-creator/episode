-- Shifrat Alkanz database schema. Run in Supabase SQL Editor on a NEW project.
create extension if not exists pgcrypto;

create table if not exists public.game_settings (
 id boolean primary key default true check(id),
 game_title text not null default 'شفرة الكنز',
 join_code_hash text,
 is_open boolean not null default false,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.teams (
 id uuid primary key default gen_random_uuid(),
 name text not null unique check(char_length(name) between 2 and 50),
 session_token_hash text not null unique,
 points integer not null default 0 check(points >= 0),
 progress integer not null default 0 check(progress >= 0),
 is_active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.family_codes (
 id uuid primary key default gen_random_uuid(),
 family_name text not null check(char_length(trim(family_name)) between 2 and 80),
 code_hash text not null unique,
 is_active boolean not null default true,
 used_by_team uuid unique references public.teams(id) on delete set null,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 used_at timestamptz
);
create table if not exists public.stages (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 sort_order integer not null unique check(sort_order > 0),
 number text generated always as (lpad(sort_order::text,2,'0')) stored,
 description text not null default '',
 prompt text not null,
 answer_hash text not null,
 hint text,
 status text not null default 'locked' check(status in ('locked','current','completed')),
 points_reward integer not null default 100 check(points_reward between 0 and 10000),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.answer_submissions (
 id uuid primary key default gen_random_uuid(),
 team_id uuid not null references public.teams(id) on delete cascade,
 stage_id uuid not null references public.stages(id) on delete cascade,
 answer_text text not null check(char_length(answer_text) <= 200),
 is_correct boolean not null default false,
 status text not null default 'pending' check(status in ('pending','accepted','rejected')),
 submitted_at timestamptz not null default now(),
 reviewed_at timestamptz,
 reviewed_by uuid references auth.users(id)
);
create table if not exists public.audit_logs (
 id bigint generated always as identity primary key,
 actor_id uuid references auth.users(id),
 action text not null,
 entity_type text not null,
 entity_id text,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists answer_submissions_team_time_idx on public.answer_submissions(team_id,submitted_at desc);
create index if not exists answer_submissions_status_idx on public.answer_submissions(status,submitted_at);
create unique index if not exists answer_submissions_one_accept_idx on public.answer_submissions(team_id,stage_id) where status='accepted';
alter table public.game_settings enable row level security;
alter table public.teams enable row level security;
alter table public.family_codes enable row level security;
alter table public.stages enable row level security;
alter table public.answer_submissions enable row level security;
alter table public.audit_logs enable row level security;

create or replace function public.is_game_admin()
returns boolean language sql stable security definer set search_path = '' as $
 select coalesce((auth.jwt()->'app_metadata'->>'role')='game_admin',false);
$;
revoke all on function public.is_game_admin() from public,anon;
grant execute on function public.is_game_admin() to authenticated;
drop view if exists public.public_stages;
create view public.public_stages with (security_invoker = true) as
 select id,title,number,description,status,sort_order,points_reward from public.stages;
create or replace view public.public_leaderboard with (security_invoker = true) as
 select id,name,points,progress from public.teams where is_active=true;
revoke all on public.public_stages from anon,authenticated;
revoke all on public.public_leaderboard from anon,authenticated;
grant select on public.public_stages to anon,authenticated;
grant select on public.public_leaderboard to anon,authenticated;
revoke all on public.stages from anon;
grant select (id,title,number,description,status,sort_order,points_reward) on public.stages to anon;
revoke all on public.teams from anon;
grant select (id,name,points,progress,is_active) on public.teams to anon;

create or replace function public.get_game_status()
returns jsonb language sql stable security definer set search_path = '' as $
 select jsonb_build_object(
  'success',true,
  'is_open',coalesce((select is_open from public.game_settings where id=true),false),
  'game_title',coalesce((select game_title from public.game_settings where id=true),'شفرة الكنز')
 );
$;
revoke all on function public.get_game_status() from public;
grant execute on function public.get_game_status() to anon,authenticated;

create policy "admin manages game settings" on public.game_settings for all to authenticated using(public.is_game_admin()) with check(public.is_game_admin());
drop policy if exists "public reads game status" on public.game_settings;
create policy "public reads game status" on public.game_settings for select to anon using(true);
revoke all on public.game_settings from anon;
grant select (is_open,game_title) on public.game_settings to anon;
create policy "admin manages teams" on public.teams for all to authenticated using(public.is_game_admin()) with check(public.is_game_admin());
drop policy if exists "admin manages family codes" on public.family_codes;
create policy "admin manages family codes" on public.family_codes for all to authenticated using(public.is_game_admin()) with check(public.is_game_admin());
grant select,insert,update,delete on public.family_codes to authenticated;
drop policy if exists "public reads stage metadata" on public.stages;
create policy "public reads stage metadata" on public.stages for select to anon using(true);
drop policy if exists "public reads active team leaderboard" on public.teams;
create policy "public reads active team leaderboard" on public.teams for select to anon using(is_active=true);
create policy "admin manages stages" on public.stages for all to authenticated using(public.is_game_admin()) with check(public.is_game_admin());
create policy "admin reads submissions" on public.answer_submissions for select to authenticated using(public.is_game_admin());
create policy "admin manages submissions" on public.answer_submissions for all to authenticated using(public.is_game_admin()) with check(public.is_game_admin());
create policy "admin reads audit logs" on public.audit_logs for select to authenticated using(public.is_game_admin());
create policy "admin writes audit logs" on public.audit_logs for insert to authenticated with check(public.is_game_admin());

create or replace function public.join_game(p_team_name text,p_session_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cfg public.game_settings%rowtype; tok text; t public.teams%rowtype; fc public.family_codes%rowtype;
begin
 select * into cfg from public.game_settings where id=true;
 if not found or not cfg.is_open then return jsonb_build_object('success',false,'message','المسابقة غير مفتوحة حاليًا.'); end if;
 select * into fc from public.family_codes
 where code_hash=encode(extensions.digest(lower(trim(p_session_code)),'sha256'),'hex')
 and is_active=true
 and (used_by_team is null or exists (select 1 from public.teams existing_team where existing_team.id=public.family_codes.used_by_team and existing_team.name=trim(p_team_name)))
 for update;
 if not found then return jsonb_build_object('success',false,'message','رمز الأسرة غير صحيح أو سبق استخدامه. اطلب رمزًا جديدًا من المشرف.'); end if;
 if char_length(trim(p_team_name)) not between 2 and 50 then return jsonb_build_object('success',false,'message','اسم الفريق يجب أن يكون بين حرفين و50 حرفًا.'); end if;
 tok:=encode(extensions.gen_random_bytes(32),'hex');
 if fc.used_by_team is null then
  insert into public.teams(name,session_token_hash) values(trim(p_team_name),encode(extensions.digest(tok,'sha256'),'hex')) returning * into t;
  update public.family_codes set used_by_team=t.id,used_at=now() where id=fc.id;
 else
  update public.teams set session_token_hash=encode(extensions.digest(tok,'sha256'),'hex') where id=fc.used_by_team and name=trim(p_team_name) returning * into t;
 end if;
 insert into public.audit_logs(action,entity_type,entity_id,details) values('team_joined','team',t.id::text,jsonb_build_object('team_name',t.name,'family_name',fc.family_name));
 return jsonb_build_object('success',true,'team_id',t.id,'team_name',t.name,'session_token',tok);
exception when unique_violation then return jsonb_build_object('success',false,'message','اسم الفريق مستخدم بالفعل. اختر اسمًا آخر.');
end; $$;

create or replace function public.get_team_game_state(p_session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t public.teams%rowtype; unlocked_through integer; stage_list jsonb;
begin
 if p_session_token is null or char_length(p_session_token)<20 then
  return jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
 end if;
 select * into t from public.teams
 where session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and is_active=true;
 if not found then
  return jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول برمز الأسرة مرة أخرى.');
 end if;
 select count(distinct stage_id)::integer into t.progress from public.answer_submissions
 where team_id=t.id and status='accepted';
 select coalesce(sum(s.points_reward),0)::integer into t.points from public.stages s
 where exists (select 1 from public.answer_submissions a where a.team_id=t.id and a.stage_id=s.id and a.status='accepted');
 unlocked_through:=((t.progress/4)+1)*4;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',s.id,'title',s.title,'number',s.number,'description',s.description,'sort_order',s.sort_order,
  'points_reward',s.points_reward,
  'status',case when exists(select 1 from public.answer_submissions a where a.team_id=t.id and a.stage_id=s.id and a.status='accepted')
    then 'completed' when s.sort_order<=unlocked_through then 'current' else 'locked' end,
  'prompt',case when s.sort_order<=unlocked_through then s.prompt else null end,
  'hint',case when s.sort_order<=unlocked_through then s.hint else null end
 ) order by s.sort_order),'[]'::jsonb) into stage_list from public.stages s;
 return jsonb_build_object('success',true,
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),
  'stages',stage_list);
end; $$;

create or replace function public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t public.teams%rowtype; s public.stages%rowtype; ok boolean; unlocked_through integer; already_done boolean;
begin
 if p_answer is null or char_length(trim(p_answer))=0 or char_length(p_answer)>200 then
  return jsonb_build_object('success',false,'message','اكتب إجابة صالحة.');
 end if;
 select * into t from public.teams
 where session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and is_active=true for update;
 if not found then return jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); end if;
 select count(distinct stage_id)::integer into t.progress from public.answer_submissions
 where team_id=t.id and status='accepted';
 unlocked_through:=((t.progress/4)+1)*4;
 select * into s from public.stages where id=p_stage_id;
 if not found then return jsonb_build_object('success',false,'message','المرحلة غير موجودة.'); end if;
 if s.sort_order>unlocked_through then
  return jsonb_build_object('success',false,'message','أكمل المراحل الأربع الحالية أولًا لفتح المجموعة التالية.');
 end if;
 select exists(select 1 from public.answer_submissions where team_id=t.id and stage_id=s.id and status='accepted') into already_done;
 if already_done then
  return jsonb_build_object('success',true,'correct',true,'already_completed',true,'message','أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.');
 end if;
 ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=s.answer_hash;
 insert into public.answer_submissions(team_id,stage_id,answer_text,is_correct,status)
 values(t.id,s.id,trim(p_answer),ok,case when ok then 'accepted' else 'rejected' end);
 if ok then
  update public.teams set points=points+s.points_reward,progress=progress+1 where id=t.id;
  insert into public.audit_logs(action,entity_type,entity_id,details)
  values('correct_answer','stage',s.id::text,jsonb_build_object('team_id',t.id,'points',s.points_reward));
  return jsonb_build_object('success',true,'correct',true,'already_completed',false,
    'points_awarded',s.points_reward,'message','إجابة صحيحة! أُضيفت نقاط المرحلة إلى رصيد فريقكم.');
 end if;
 return jsonb_build_object('success',true,'correct',false,'message','مو هي الإجابة الصحيحة، راجعوا الأدلة وحاولوا مرة ثانية.');
end; $$;

revoke all on function public.join_game(text,text) from public;
revoke all on function public.get_team_game_state(text) from public;
revoke all on function public.submit_stage_answer(text,uuid,text) from public;
grant execute on function public.join_game(text,text) to anon,authenticated;
grant execute on function public.get_team_game_state(text) to anon,authenticated;
grant execute on function public.submit_stage_answer(text,uuid,text) to anon,authenticated;
insert into public.game_settings(id,game_title,is_open) values(true,'شفرة الكنز',false) on conflict(id) do nothing;
-- Enable Realtime for stages and teams in the Supabase dashboard if desired.
-- The database starts closed. Create family codes in the admin panel, add a first stage, then set game_settings.is_open=true in Supabase to start the game.
-- Set the administrator role for your chosen existing Auth user in Supabase SQL Editor:
-- update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"game_admin"}'::jsonb where email = 'YOUR_ADMIN_EMAIL';
