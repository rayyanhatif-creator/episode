-- Lock each family code to the first browser/device that claims it.
alter table public.family_codes add column if not exists claimed_device_id text;
alter table public.family_codes drop constraint if exists family_codes_claimed_device_id_check;
alter table public.family_codes add constraint family_codes_claimed_device_id_check
  check (claimed_device_id is null or char_length(claimed_device_id) between 16 and 128);

create or replace function public.claim_family_device(p_team_id uuid,p_device_id text)
returns boolean language plpgsql security definer set search_path to '' as $$
declare fc public.family_codes%rowtype;
begin
 if p_device_id is null or char_length(p_device_id) not between 16 and 128 then return false; end if;
 select * into fc from public.family_codes where used_by_team=p_team_id and is_active=true for update;
 if not found then return false; end if;
 if fc.claimed_device_id is null then
  update public.family_codes set claimed_device_id=p_device_id where id=fc.id;
  return true;
 end if;
 return fc.claimed_device_id=p_device_id;
end; $$;
revoke all on function public.claim_family_device(uuid,text) from public,anon,authenticated;

alter function public.join_game(text,text) rename to join_game_internal;
alter function public.get_team_game_state(text) rename to get_team_game_state_internal;
alter function public.submit_stage_answer(text,uuid,text,text) rename to submit_stage_answer_internal;
alter function public.request_team_hint(text,uuid) rename to request_team_hint_internal;

revoke all on function public.join_game_internal(text,text) from public,anon,authenticated;
revoke all on function public.get_team_game_state_internal(text) from public,anon,authenticated;
revoke all on function public.submit_stage_answer_internal(text,uuid,text,text) from public,anon,authenticated;
revoke all on function public.request_team_hint_internal(text,uuid) from public,anon,authenticated;

create function public.join_game(p_team_name text,p_session_code text,p_device_id text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare fc public.family_codes%rowtype; result jsonb;
begin
 if p_device_id is null or char_length(p_device_id) not between 16 and 128 then
  return jsonb_build_object('success',false,'message','تعذر التحقق من هذا الجهاز. حدّث الصفحة وحاول مرة أخرى.');
 end if;
 select * into fc from public.family_codes
 where code_hash=encode(extensions.digest(lower(trim(p_session_code)),'sha256'),'hex') and is_active=true
 for update;
 if not found then return jsonb_build_object('success',false,'message','رمز الأسرة غير صحيح أو غير فعال. اطلب الرمز من المشرف.'); end if;
 if fc.claimed_device_id is not null and fc.claimed_device_id<>p_device_id then
  return jsonb_build_object('success',false,'code','device_mismatch','message','هذا الرمز مرتبط بجوال آخر، ولا يمكن استخدامه من جوال ثانٍ.');
 end if;
 if fc.claimed_device_id is null then
  update public.family_codes set claimed_device_id=p_device_id where id=fc.id;
 end if;
 result:=public.join_game_internal(p_team_name,p_session_code);
 return result;
end; $$;

create function public.get_team_game_state(p_session_token text,p_device_id text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.teams%rowtype;
begin
 select tm.* into t from public.teams tm
 where tm.is_active=true and
  (tm.session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') or
   exists(select 1 from public.team_sessions ts where ts.team_id=tm.id and ts.token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and ts.is_active=true))
 limit 1;
 if not found then return public.get_team_game_state_internal(p_session_token); end if;
 if not public.claim_family_device(t.id,p_device_id) then
  return jsonb_build_object('success',false,'code','device_mismatch','message','هذه الأسرة مرتبطة بجوال آخر. لا يمكن فتح الجلسة من جهاز ثانٍ.');
 end if;
 return public.get_team_game_state_internal(p_session_token);
end; $$;

create function public.submit_stage_answer(p_session_token text,p_stage_id uuid,p_answer text,p_device_id text,p_phase text default 'riddle')
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.teams%rowtype;
begin
 select tm.* into t from public.teams tm
 where tm.is_active=true and
  (tm.session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') or
   exists(select 1 from public.team_sessions ts where ts.team_id=tm.id and ts.token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and ts.is_active=true))
 limit 1;
 if not found then return public.submit_stage_answer_internal(p_session_token,p_stage_id,p_answer,p_phase); end if;
 if not public.claim_family_device(t.id,p_device_id) then
  return jsonb_build_object('success',false,'code','device_mismatch','message','هذه الأسرة مرتبطة بجوال آخر. لا يمكن إرسال الإجابات من جهاز ثانٍ.');
 end if;
 return public.submit_stage_answer_internal(p_session_token,p_stage_id,p_answer,p_phase);
end; $$;

create function public.request_team_hint(p_session_token text,p_stage_id uuid,p_device_id text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare t public.teams%rowtype;
begin
 select tm.* into t from public.teams tm
 where tm.is_active=true and
  (tm.session_token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') or
   exists(select 1 from public.team_sessions ts where ts.team_id=tm.id and ts.token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and ts.is_active=true))
 limit 1;
 if not found then return public.request_team_hint_internal(p_session_token,p_stage_id); end if;
 if not public.claim_family_device(t.id,p_device_id) then
  return jsonb_build_object('success',false,'code','device_mismatch','message','هذه الأسرة مرتبطة بجوال آخر. لا يمكن طلب التلميحات من جهاز ثانٍ.');
 end if;
 return public.request_team_hint_internal(p_session_token,p_stage_id);
end; $$;

revoke all on function public.join_game(text,text,text) from public;
revoke all on function public.get_team_game_state(text,text) from public;
revoke all on function public.submit_stage_answer(text,uuid,text,text,text) from public;
revoke all on function public.request_team_hint(text,uuid,text) from public;
grant execute on function public.join_game(text,text,text) to anon,authenticated;
grant execute on function public.get_team_game_state(text,text) to anon,authenticated;
grant execute on function public.submit_stage_answer(text,uuid,text,text,text) to anon,authenticated;
grant execute on function public.request_team_hint(text,uuid,text) to anon,authenticated;
