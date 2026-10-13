-- Migration for existing installations: one-time family entry codes.
create extension if not exists pgcrypto;

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

alter table public.family_codes enable row level security;
drop policy if exists "admin manages family codes" on public.family_codes;
create policy "admin manages family codes" on public.family_codes
 for all to authenticated
 using (public.is_game_admin())
 with check (public.is_game_admin());
grant select,insert,update,delete on public.family_codes to authenticated;

create or replace function public.join_game(p_team_name text,p_session_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cfg public.game_settings%rowtype; tok text; t public.teams%rowtype; fc public.family_codes%rowtype;
begin
 select * into cfg from public.game_settings where id=true;
 if not found or not cfg.is_open then
  return jsonb_build_object('success',false,'message','المسابقة غير مفتوحة حاليًا.');
 end if;
 select * into fc from public.family_codes
 where code_hash=encode(extensions.digest(lower(trim(p_session_code)),'sha256'),'hex')
 and is_active=true and used_by_team is null for update;
 if not found then
  return jsonb_build_object('success',false,'message','رمز الأسرة غير صحيح أو سبق استخدامه. اطلب رمزًا جديدًا من المشرف.');
 end if;
 if char_length(trim(p_team_name)) not between 2 and 50 then
  return jsonb_build_object('success',false,'message','اسم الفريق يجب أن يكون بين حرفين و50 حرفًا.');
 end if;
 tok:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.teams(name,session_token_hash)
 values(trim(p_team_name),encode(extensions.digest(tok,'sha256'),'hex')) returning * into t;
 update public.family_codes set used_by_team=t.id,used_at=now() where id=fc.id;
 insert into public.audit_logs(action,entity_type,entity_id,details)
 values('team_joined','team',t.id::text,jsonb_build_object('team_name',t.name,'family_name',fc.family_name));
 return jsonb_build_object('success',true,'team_id',t.id,'team_name',t.name,'session_token',tok);
exception when unique_violation then
 return jsonb_build_object('success',false,'message','اسم الفريق مستخدم بالفعل. اختر اسمًا آخر.');
end; $$;

revoke all on function public.join_game(text,text) from public;
grant execute on function public.join_game(text,text) to anon,authenticated;

-- After creating an Auth user for the administrator, assign its role once in Supabase SQL Editor:
-- update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"game_admin"}'::jsonb where email = 'YOUR_ADMIN_EMAIL';
