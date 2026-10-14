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
 scrambled_sentence text,
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
returns boolean language sql stable security definer set search_path = '' as $admin$
 select coalesce((auth.jwt()->'app_metadata'->>'role')='game_admin',false);
$admin$;
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
returns jsonb language sql stable security invoker set search_path = '' as $game_status$
 select jsonb_build_object(
  'success',true,
  'is_open',coalesce((select is_open from public.game_settings where id=true),false),
  'game_title',coalesce((select game_title from public.game_settings where id=true),'شفرة الكنز')
 );
$game_status$;
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
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.teams%rowtype;
  stage_list jsonb;
begin
  if p_session_token IS null OR char_length(p_session_token) < 20 then
    return jsonb_build_object('success', false, 'message', 'جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
  end IF;
  select * into t from public.teams
  where session_token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex') and is_active = true;
  if NOT FOUND then
    return jsonb_build_object('success', false, 'message', 'انتهت جلسة الفريق. سجّل الدخول برمز الأسرة مرة أخرى.');
  end IF;
  select count(distinct stage_id)::integer into t.progress from public.answer_submissions
  where team_id = t.id and status = 'accepted';
  select coalesce(sum(s.points_reward), 0)::integer into t.points from public.stages s
  where exists (select 1 from public.answer_submissions a where a.team_id = t.id and a.stage_id = s.id and a.status = 'accepted');
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'title', s.title, 'number', s.number, 'description', s.description,
    'sort_order', s.sort_order, 'points_reward', s.points_reward,
    'status', case
      when exists (select 1 from public.answer_submissions a where a.team_id = t.id and a.stage_id = s.id and a.status = 'accepted') then 'completed'
      when s.status = 'current' then 'current' else 'locked' end,
    'prompt', case when s.status = 'current' then s.prompt else null end,
    'hint', case when s.status = 'current' then s.hint else null end,
    'scrambled_sentence', case when s.status = 'current' then s.scrambled_sentence else null end
  ) order by s.sort_order), '[]'::jsonb) into stage_list from public.stages s;
  return jsonb_build_object('success', true,
    'team', jsonb_build_object('id', t.id, 'name', t.name, 'points', t.points, 'progress', t.progress),
    'stages', stage_list);
end;
$$;

create or replace function public.submit_stage_answer(p_session_token text, p_stage_id uuid, p_answer text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  t public.teams%rowtype; s public.stages%rowtype; ok boolean; already_done boolean;
begin
  if p_answer IS null OR char_length(trim(p_answer)) = 0 OR char_length(p_answer) > 200 then
    return jsonb_build_object('success', false, 'message', 'اكتب إجابة صالحة.');
  end IF;
  select * into t from public.teams
  where session_token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex') and is_active = true FOR UPDATE;
  if NOT FOUND then return jsonb_build_object('success', false, 'message', 'انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); end IF;
  select * into s from public.stages where id = p_stage_id;
  if NOT FOUND then return jsonb_build_object('success', false, 'message', 'المرحلة غير موجودة.'); end IF;
  if s.status <> 'current' then
    return jsonb_build_object('success', false, 'message', 'هذه المرحلة مقفلة حاليًا من المشرف.');
  end IF;
  select exists(select 1 from public.answer_submissions where team_id = t.id and stage_id = s.id and status = 'accepted') into already_done;
  if already_done then
    return jsonb_build_object('success', true, 'correct', true, 'already_completed', true, 'message', 'أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.');
  end IF;
  ok := encode(extensions.digest(lower(trim(p_answer)), 'sha256'), 'hex') = s.answer_hash;
  INSERT into public.answer_submissions(team_id, stage_id, answer_text, is_correct, status)
  values(t.id, s.id, trim(p_answer), ok, case when ok then 'accepted' else 'rejected' end);
  if ok then
    update public.teams set points = points + s.points_reward, progress = progress + 1 where id = t.id;
    INSERT into public.audit_logs(action, entity_type, entity_id, details)
    values('correct_answer', 'stage', s.id::text, jsonb_build_object('team_id', t.id, 'points', s.points_reward));
    return jsonb_build_object('success', true, 'correct', true, 'already_completed', false,
      'points_awarded', s.points_reward, 'message', 'إجابة صحيحة! أُضيفت نقاط المرحلة إلى رصيد فريقكم.');
  end IF;
  return jsonb_build_object('success', true, 'correct', false, 'message', 'مو هي الإجابة الصحيحة، راجعوا الأدلة وحاولوا مرة ثانية.');
end;
$$;
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


-- Three question variants per stage, per-team assignments, and pause-safe family login.
CREATE TABLE IF NOT EXISTS public.stage_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stage_id uuid NOT NULL REFERENCES public.stages(id) ON DELETE CASCADE,
  variant_no integer NOT NULL CHECK (variant_no BETWEEN 1 AND 3),
  prompt text NOT NULL,
  answer_hash text NOT NULL,
  hint text NOT NULL DEFAULT '',
  scrambled_sentence text NOT NULL DEFAULT '',
  final_answer_hash text NOT NULL,
  points_reward integer NOT NULL DEFAULT 100 CHECK (points_reward BETWEEN 0 AND 10000),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(stage_id, variant_no)
);
CREATE TABLE IF NOT EXISTS public.team_stage_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  stage_id uuid NOT NULL REFERENCES public.stages(id) ON DELETE CASCADE,
  question_id uuid NOT NULL REFERENCES public.stage_questions(id) ON DELETE CASCADE,
  hint_unlocked boolean NOT NULL DEFAULT false,
  completed boolean NOT NULL DEFAULT false,
  points_awarded integer NOT NULL DEFAULT 0 CHECK (points_awarded >= 0),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  UNIQUE(team_id, stage_id)
);
ALTER TABLE public.stage_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_stage_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin manages stage questions" ON public.stage_questions;
CREATE POLICY "admin manages stage questions" ON public.stage_questions FOR ALL TO authenticated USING (public.is_game_admin()) WITH CHECK (public.is_game_admin());
DROP POLICY IF EXISTS "admin reads team stage assignments" ON public.team_stage_assignments;
CREATE POLICY "admin reads team stage assignments" ON public.team_stage_assignments FOR SELECT TO authenticated USING (public.is_game_admin());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.stage_questions TO authenticated;
GRANT SELECT ON public.team_stage_assignments TO authenticated;

INSERT INTO public.stage_questions(stage_id, variant_no, prompt, answer_hash, hint, scrambled_sentence, final_answer_hash, points_reward)
SELECT s.id, v.variant_no, s.prompt, s.answer_hash, coalesce(s.hint,''), coalesce(s.scrambled_sentence,''), s.answer_hash, s.points_reward
FROM public.stages s CROSS JOIN (VALUES (1),(2),(3)) AS v(variant_no)
ON CONFLICT (stage_id, variant_no) DO NOTHING;

INSERT INTO public.team_stage_assignments(team_id, stage_id, question_id, hint_unlocked, completed, points_awarded, completed_at)
SELECT a.team_id, a.stage_id, q.id, true, true, s.points_reward, coalesce(a.submitted_at,now())
FROM public.answer_submissions a
JOIN public.stages s ON s.id=a.stage_id
JOIN public.stage_questions q ON q.stage_id=s.id AND q.variant_no=1
WHERE a.status='accepted'
ON CONFLICT (team_id,stage_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.join_game(p_team_name text,p_session_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE cfg public.game_settings%rowtype; tok text; t public.teams%rowtype; fc public.family_codes%rowtype;
BEGIN
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','إعدادات المسابقة غير جاهزة.'); END IF;
 SELECT * INTO fc FROM public.family_codes
 WHERE code_hash=encode(extensions.digest(lower(trim(p_session_code)),'sha256'),'hex')
 AND is_active=true
 AND (used_by_team IS NULL OR EXISTS (SELECT 1 FROM public.teams existing_team WHERE existing_team.id=public.family_codes.used_by_team AND existing_team.name=trim(p_team_name)))
 FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','رمز الأسرة غير صحيح أو سبق استخدامه. اطلب رمزًا جديدًا من المشرف.'); END IF;
 IF char_length(trim(p_team_name)) NOT BETWEEN 2 AND 50 THEN RETURN jsonb_build_object('success',false,'message','اسم الفريق يجب أن يكون بين حرفين و50 حرفًا.'); END IF;
 tok:=encode(extensions.gen_random_bytes(32),'hex');
 IF fc.used_by_team IS NULL THEN
  INSERT INTO public.teams(name,session_token_hash) VALUES(trim(p_team_name),encode(extensions.digest(tok,'sha256'),'hex')) RETURNING * INTO t;
  UPDATE public.family_codes SET used_by_team=t.id,used_at=now() WHERE id=fc.id;
 ELSE
  UPDATE public.teams SET session_token_hash=encode(extensions.digest(tok,'sha256'),'hex') WHERE id=fc.used_by_team AND name=trim(p_team_name) RETURNING * INTO t;
 END IF;
 INSERT INTO public.audit_logs(action,entity_type,entity_id,details) VALUES('team_joined','team',t.id::text,jsonb_build_object('team_name',t.name,'family_name',fc.family_name));
 RETURN jsonb_build_object('success',true,'team_id',t.id,'team_name',t.name,'session_token',tok);
EXCEPTION WHEN unique_violation THEN RETURN jsonb_build_object('success',false,'message','اسم الفريق مستخدم بالفعل. اختر اسمًا آخر.');
END;
$$;

CREATE OR REPLACE FUNCTION public.get_team_game_state(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; stage_list jsonb; cfg public.game_settings%rowtype; s public.stages%rowtype;
BEGIN
 IF p_session_token IS NULL OR char_length(p_session_token)<20 THEN
  RETURN jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
 END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 FOR s IN SELECT * FROM public.stages ORDER BY sort_order LOOP
  IF s.status='current' THEN
   INSERT INTO public.team_stage_assignments(team_id,stage_id,question_id)
   SELECT t.id,s.id,q.id FROM public.stage_questions q
   LEFT JOIN (SELECT question_id,count(*) AS assigned_count FROM public.team_stage_assignments WHERE stage_id=s.id GROUP BY question_id) ac ON ac.question_id=q.id
   WHERE q.stage_id=s.id ORDER BY coalesce(ac.assigned_count,0),random() LIMIT 1
   ON CONFLICT(team_id,stage_id) DO NOTHING;
  END IF;
 END LOOP;
 SELECT count(*)::integer INTO t.progress FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(sum(points_awarded),0)::integer INTO t.points FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',s.id,'title',s.title,'number',s.number,'description',s.description,'sort_order',s.sort_order,
  'points_reward',coalesce(q.points_reward,s.points_reward),
  'status',CASE WHEN coalesce(a.completed,false) OR EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=s.id AND olda.status='accepted') THEN 'completed' WHEN s.status='current' THEN 'current' ELSE 'locked' END,
  'prompt',CASE WHEN s.status='current' AND NOT coalesce(a.completed,false) THEN q.prompt ELSE null END,
  'hint',CASE WHEN s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.hint ELSE null END,
  'hint_unlocked',coalesce(a.hint_unlocked,false),
  'scrambled_sentence',CASE WHEN s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.scrambled_sentence ELSE null END,
  'final_answer_required',coalesce(a.hint_unlocked,false),
  'question_id',q.id
 ) ORDER BY s.sort_order),'[]'::jsonb) INTO stage_list
 FROM public.stages s LEFT JOIN public.team_stage_assignments a ON a.team_id=t.id AND a.stage_id=s.id
 LEFT JOIN public.stage_questions q ON q.id=a.question_id;
 RETURN jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),'stages',stage_list);
END;
$$;

DROP FUNCTION IF EXISTS public.submit_stage_answer(text,uuid,text);
CREATE OR REPLACE FUNCTION public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text,p_phase text DEFAULT 'riddle')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; s public.stages%rowtype; a public.team_stage_assignments%rowtype; q public.stage_questions%rowtype; ok boolean;
BEGIN
 IF p_phase NOT IN ('riddle','final') THEN RETURN jsonb_build_object('success',false,'message','خطوة إجابة غير صالحة.'); END IF;
 IF p_answer IS NULL OR char_length(trim(p_answer))=0 OR char_length(p_answer)>200 THEN RETURN jsonb_build_object('success',false,'message','اكتب إجابة صالحة.'); END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 IF NOT coalesce((SELECT is_open FROM public.game_settings WHERE id=true),false) THEN RETURN jsonb_build_object('success',false,'message','المشرف أوقف المسابقة مؤقتًا.'); END IF;
 SELECT * INTO s FROM public.stages WHERE id=p_stage_id;
 IF NOT FOUND OR s.status<>'current' THEN RETURN jsonb_build_object('success',false,'message','هذه المرحلة مقفلة حاليًا من المشرف.'); END IF;
 SELECT * INTO a FROM public.team_stage_assignments WHERE team_id=t.id AND stage_id=s.id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','تعذر تجهيز سؤال فريقكم. حدّثوا الصفحة وحاولوا مجددًا.'); END IF;
 IF a.completed THEN RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'message','أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.'); END IF;
 SELECT * INTO q FROM public.stage_questions WHERE id=a.question_id;
 IF p_phase='riddle' THEN
  IF a.hint_unlocked THEN RETURN jsonb_build_object('success',false,'message','لقد فتحتم التلميح بالفعل. أكملوا حل الورقة.'); END IF;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.answer_hash;
  INSERT INTO public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) VALUES(t.id,s.id,trim(p_answer),ok,CASE WHEN ok THEN 'pending' ELSE 'rejected' END);
  IF ok THEN UPDATE public.team_stage_assignments SET hint_unlocked=true WHERE id=a.id;
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',false,'hint_unlocked',true,'message','إجابة صحيحة! ظهر لكم التلميح؛ ابحثوا عن الورقة واكتبوا الحل النهائي.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الإجابة غير صحيحة. حاولوا مرة ثانية.');
 ELSE
  IF NOT a.hint_unlocked THEN RETURN jsonb_build_object('success',false,'message','حلّوا السؤال أولًا لفتح التلميح.'); END IF;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.final_answer_hash;
  INSERT INTO public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) VALUES(t.id,s.id,trim(p_answer),ok,CASE WHEN ok THEN 'accepted' ELSE 'rejected' END);
  IF ok THEN
   UPDATE public.team_stage_assignments SET completed=true,points_awarded=q.points_reward,completed_at=now() WHERE id=a.id;
   UPDATE public.teams SET points=points+q.points_reward,progress=progress+1 WHERE id=t.id;
   INSERT INTO public.audit_logs(action,entity_type,entity_id,details) VALUES('stage_completed','stage',s.id::text,jsonb_build_object('team_id',t.id,'question_id',q.id,'points',q.points_reward));
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'points_awarded',q.points_reward,'message','حل صحيح! اكتملت المرحلة وأُضيفت نقاطها إلى رصيدكم.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الحل غير صحيح. راجعوا الكلمات الموجودة على الورقة وحاولوا مرة ثانية.');
 END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.join_game(text,text) FROM public;
REVOKE ALL ON FUNCTION public.get_team_game_state(text) FROM public;
REVOKE ALL ON FUNCTION public.submit_stage_answer(text,uuid,text,text) FROM public;
GRANT EXECUTE ON FUNCTION public.join_game(text,text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_team_game_state(text) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.submit_stage_answer(text,uuid,text,text) TO anon,authenticated;


-- Do not send current-stage prompts or hints to clients while the supervisor has paused the competition.
CREATE OR REPLACE FUNCTION public.get_team_game_state(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; stage_list jsonb; cfg public.game_settings%rowtype; s public.stages%rowtype;
BEGIN
 IF p_session_token IS NULL OR char_length(p_session_token)<20 THEN
  RETURN jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
 END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 FOR s IN SELECT * FROM public.stages ORDER BY sort_order LOOP
  IF s.status='current' THEN
   INSERT INTO public.team_stage_assignments(team_id,stage_id,question_id)
   SELECT t.id,s.id,q.id FROM public.stage_questions q
   LEFT JOIN (SELECT question_id,count(*) AS assigned_count FROM public.team_stage_assignments WHERE stage_id=s.id GROUP BY question_id) ac ON ac.question_id=q.id
   WHERE q.stage_id=s.id ORDER BY coalesce(ac.assigned_count,0),random() LIMIT 1
   ON CONFLICT(team_id,stage_id) DO NOTHING;
  END IF;
 END LOOP;
 SELECT count(*)::integer INTO t.progress FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(sum(points_awarded),0)::integer INTO t.points FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',s.id,'title',s.title,'number',s.number,'description',s.description,'sort_order',s.sort_order,
  'points_reward',coalesce(q.points_reward,s.points_reward),
  'status',CASE WHEN coalesce(a.completed,false) OR EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=s.id AND olda.status='accepted') THEN 'completed' WHEN s.status='current' THEN 'current' ELSE 'locked' END,
  'prompt',CASE WHEN coalesce(cfg.is_open,false) AND s.status='current' AND NOT coalesce(a.completed,false) THEN q.prompt ELSE null END,
  'hint',CASE WHEN coalesce(cfg.is_open,false) AND s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.hint ELSE null END,
  'hint_unlocked',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false),
  'scrambled_sentence',CASE WHEN coalesce(cfg.is_open,false) AND s.status='current' AND coalesce(a.hint_unlocked,false) THEN q.scrambled_sentence ELSE null END,
  'final_answer_required',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false),
  'question_id',q.id
 ) ORDER BY s.sort_order),'[]'::jsonb) INTO stage_list
 FROM public.stages s LEFT JOIN public.team_stage_assignments a ON a.team_id=t.id AND a.stage_id=s.id
 LEFT JOIN public.stage_questions q ON q.id=a.question_id;
 RETURN jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),'stages',stage_list);
END;
$$;

-- Progress through stages per team automatically; no supervisor stage-unlock clicks are required.
CREATE OR REPLACE FUNCTION public.get_team_game_state(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; stage_list jsonb; cfg public.game_settings%rowtype; s public.stages%rowtype; target_stage_id uuid;
BEGIN
 IF p_session_token IS NULL OR char_length(p_session_token)<20 THEN
  RETURN jsonb_build_object('success',false,'message','جلسة الفريق غير صالحة. سجّل الدخول برمز الأسرة مرة أخرى.');
 END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 SELECT * INTO cfg FROM public.game_settings WHERE id=true;
 SELECT st.id INTO target_stage_id FROM public.stages st
 WHERE NOT EXISTS(SELECT 1 FROM public.team_stage_assignments a WHERE a.team_id=t.id AND a.stage_id=st.id AND a.completed=true)
 AND NOT EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=st.id AND olda.status='accepted')
 ORDER BY st.sort_order LIMIT 1;
 IF target_stage_id IS NOT NULL THEN
  SELECT * INTO s FROM public.stages WHERE id=target_stage_id;
  INSERT INTO public.team_stage_assignments(team_id,stage_id,question_id)
  SELECT t.id,s.id,q.id FROM public.stage_questions q
  LEFT JOIN (SELECT question_id,count(*) AS assigned_count FROM public.team_stage_assignments WHERE stage_id=target_stage_id GROUP BY question_id) ac ON ac.question_id=q.id
  WHERE q.stage_id=target_stage_id ORDER BY coalesce(ac.assigned_count,0),random() LIMIT 1
  ON CONFLICT(team_id,stage_id) DO NOTHING;
 END IF;
 SELECT count(*)::integer INTO t.progress FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(sum(points_awarded),0)::integer INTO t.points FROM public.team_stage_assignments WHERE team_id=t.id AND completed=true;
 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id',st.id,'title',st.title,'number',st.number,'description',st.description,'sort_order',st.sort_order,
  'points_reward',coalesce(q.points_reward,st.points_reward),
  'status',CASE WHEN coalesce(a.completed,false) OR EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=st.id AND olda.status='accepted') THEN 'completed' WHEN st.id=target_stage_id THEN 'current' ELSE 'locked' END,
  'prompt',CASE WHEN coalesce(cfg.is_open,false) AND st.id=target_stage_id THEN q.prompt ELSE null END,
  'hint',CASE WHEN coalesce(cfg.is_open,false) AND st.id=target_stage_id AND coalesce(a.hint_unlocked,false) THEN q.hint ELSE null END,
  'hint_unlocked',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false) AND st.id=target_stage_id,
  'scrambled_sentence',CASE WHEN coalesce(cfg.is_open,false) AND st.id=target_stage_id AND coalesce(a.hint_unlocked,false) THEN q.scrambled_sentence ELSE null END,
  'final_answer_required',coalesce(a.hint_unlocked,false) AND coalesce(cfg.is_open,false) AND st.id=target_stage_id,
  'question_id',q.id
 ) ORDER BY st.sort_order),'[]'::jsonb) INTO stage_list
 FROM public.stages st LEFT JOIN public.team_stage_assignments a ON a.team_id=t.id AND a.stage_id=st.id
 LEFT JOIN public.stage_questions q ON q.id=a.question_id;
 RETURN jsonb_build_object('success',true,'game_open',coalesce(cfg.is_open,false),
  'team',jsonb_build_object('id',t.id,'name',t.name,'points',t.points,'progress',t.progress),'stages',stage_list);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text,p_phase text DEFAULT 'riddle')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.teams%rowtype; s public.stages%rowtype; a public.team_stage_assignments%rowtype; q public.stage_questions%rowtype; ok boolean; target_stage_id uuid;
BEGIN
 IF p_phase NOT IN ('riddle','final') THEN RETURN jsonb_build_object('success',false,'message','خطوة إجابة غير صالحة.'); END IF;
 IF p_answer IS NULL OR char_length(trim(p_answer))=0 OR char_length(p_answer)>200 THEN RETURN jsonb_build_object('success',false,'message','اكتب إجابة صالحة.'); END IF;
 SELECT * INTO t FROM public.teams WHERE session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND is_active=true FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','انتهت جلسة الفريق. سجّل الدخول مرة أخرى.'); END IF;
 IF NOT coalesce((SELECT is_open FROM public.game_settings WHERE id=true),false) THEN RETURN jsonb_build_object('success',false,'message','المشرف أوقف المسابقة مؤقتًا.'); END IF;
 SELECT st.id INTO target_stage_id FROM public.stages st
 WHERE NOT EXISTS(SELECT 1 FROM public.team_stage_assignments aa WHERE aa.team_id=t.id AND aa.stage_id=st.id AND aa.completed=true)
 AND NOT EXISTS(SELECT 1 FROM public.answer_submissions olda WHERE olda.team_id=t.id AND olda.stage_id=st.id AND olda.status='accepted')
 ORDER BY st.sort_order LIMIT 1;
 IF target_stage_id IS NULL OR target_stage_id<>p_stage_id THEN RETURN jsonb_build_object('success',false,'message','أكملوا المرحلة المتاحة أمامكم أولًا.'); END IF;
 SELECT * INTO s FROM public.stages WHERE id=p_stage_id;
 SELECT * INTO a FROM public.team_stage_assignments WHERE team_id=t.id AND stage_id=s.id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'message','تعذر تجهيز سؤال فريقكم. حدّثوا الصفحة وحاولوا مجددًا.'); END IF;
 IF a.completed THEN RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'message','أنجزتم هذه المرحلة سابقًا، ونقاطها محفوظة.'); END IF;
 SELECT * INTO q FROM public.stage_questions WHERE id=a.question_id;
 IF p_phase='riddle' THEN
  IF a.hint_unlocked THEN RETURN jsonb_build_object('success',false,'message','لقد فتحتم التلميح بالفعل. أكملوا حل الورقة.'); END IF;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.answer_hash;
  INSERT INTO public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) VALUES(t.id,s.id,trim(p_answer),ok,CASE WHEN ok THEN 'pending' ELSE 'rejected' END);
  IF ok THEN UPDATE public.team_stage_assignments SET hint_unlocked=true WHERE id=a.id;
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',false,'hint_unlocked',true,'message','إجابة صحيحة! ظهر لكم التلميح؛ ابحثوا عن الورقة واكتبوا الحل النهائي.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الإجابة غير صحيحة. حاولوا مرة ثانية.');
 ELSE
  IF NOT a.hint_unlocked THEN RETURN jsonb_build_object('success',false,'message','حلّوا السؤال أولًا لفتح التلميح.'); END IF;
  ok:=encode(extensions.digest(lower(trim(p_answer)),'sha256'),'hex')=q.final_answer_hash;
  INSERT INTO public.answer_submissions(team_id,stage_id,answer_text,is_correct,status) VALUES(t.id,s.id,trim(p_answer),ok,CASE WHEN ok THEN 'accepted' ELSE 'rejected' END);
  IF ok THEN
   UPDATE public.team_stage_assignments SET completed=true,points_awarded=q.points_reward,completed_at=now() WHERE id=a.id;
   UPDATE public.teams SET points=points+q.points_reward,progress=progress+1 WHERE id=t.id;
   INSERT INTO public.audit_logs(action,entity_type,entity_id,details) VALUES('stage_completed','stage',s.id::text,jsonb_build_object('team_id',t.id,'question_id',q.id,'points',q.points_reward));
   RETURN jsonb_build_object('success',true,'correct',true,'phase_complete',true,'points_awarded',q.points_reward,'message','حل صحيح! اكتملت المرحلة وأُضيفت نقاطها إلى رصيدكم. ستنتقلون تلقائيًا إلى المرحلة التالية.');
  END IF;
  RETURN jsonb_build_object('success',true,'correct',false,'phase_complete',false,'message','الحل غير صحيح. راجعوا الكلمات الموجودة على الورقة وحاولوا مرة ثانية.');
 END IF;
END;
$$;

-- Latest schema updates: shared family sessions and hint-request penalties.
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
