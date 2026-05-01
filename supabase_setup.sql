-- ============================================================================
-- LIFE HOUSE WORKSHOP STUDIO — SUPABASE SETUP
-- ============================================================================
-- Paste this entire file into the Supabase SQL Editor and click "Run".
-- One-time setup. Safe to re-run (uses IF NOT EXISTS / OR REPLACE).
-- ============================================================================

-- 1. ENUM for user roles -----------------------------------------------------
do $$ begin
  create type user_role as enum ('admin', 'member');
exception
  when duplicate_object then null;
end $$;

-- 2. PROFILES table ----------------------------------------------------------
-- Mirrors auth.users with your team-specific fields (role, name).
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  name        text,
  role        user_role not null default 'member',
  created_at  timestamptz not null default now()
);

-- 3. APP_STATE table ---------------------------------------------------------
-- Single key/value table that stores:
--   key='lh:edits:v1'         → JSON object of overrides for built-in decks
--   key='lh:custom-decks:v1'  → JSON object of custom workshops created by team
create table if not exists public.app_state (
  key         text primary key,
  value       jsonb not null,
  updated_by  uuid references auth.users(id) on delete set null,
  updated_at  timestamptz not null default now()
);

-- 4. AUTO-CREATE PROFILE on new signup --------------------------------------
-- The first user with email starting "julius@" is auto-promoted to admin.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_admin boolean;
begin
  is_admin := lower(new.email) like 'julius@%';
  insert into public.profiles (id, email, name, role)
  values (
    new.id,
    new.email,
    coalesce(split_part(new.email, '@', 1), new.email),
    case when is_admin then 'admin'::user_role else 'member'::user_role end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- 5. ROW LEVEL SECURITY ------------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.app_state enable row level security;

-- Helper: is the current user authenticated AND on an allowed domain?
-- The allowed domain is hard-coded here. Change 'lifehousereentry.com' if needed.
create or replace function public.user_is_allowed()
returns boolean
language sql
stable
as $$
  select
    auth.uid() is not null
    and lower(coalesce(auth.jwt() ->> 'email', '')) like '%@lifehousereentry.com'
$$;

-- Helper: is the current user an admin?
create or replace function public.user_is_admin()
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  )
$$;

-- ----- profiles policies ---------------------------------------------------
drop policy if exists "profiles: read all if allowed"   on public.profiles;
drop policy if exists "profiles: update own"            on public.profiles;
drop policy if exists "profiles: admin updates any"     on public.profiles;
drop policy if exists "profiles: insert self"           on public.profiles;

create policy "profiles: read all if allowed"
  on public.profiles for select
  using (public.user_is_allowed());

create policy "profiles: insert self"
  on public.profiles for insert
  with check (id = auth.uid());

create policy "profiles: update own"
  on public.profiles for update
  using (id = auth.uid());

create policy "profiles: admin updates any"
  on public.profiles for update
  using (public.user_is_admin());

-- ----- app_state policies --------------------------------------------------
drop policy if exists "app_state: read if allowed"   on public.app_state;
drop policy if exists "app_state: write if allowed"  on public.app_state;
drop policy if exists "app_state: update if allowed" on public.app_state;
drop policy if exists "app_state: delete if allowed" on public.app_state;

create policy "app_state: read if allowed"
  on public.app_state for select
  using (public.user_is_allowed());

create policy "app_state: write if allowed"
  on public.app_state for insert
  with check (public.user_is_allowed());

create policy "app_state: update if allowed"
  on public.app_state for update
  using (public.user_is_allowed());

create policy "app_state: delete if allowed"
  on public.app_state for delete
  using (public.user_is_allowed());

-- 6. REALTIME ----------------------------------------------------------------
-- Turn on realtime for app_state so updates from teammates show up live.
-- (Wrapped in DO block so re-running this script doesn't error out.)
do $$ begin
  alter publication supabase_realtime add table public.app_state;
exception
  when duplicate_object then null;
  when others then null;
end $$;

-- ============================================================================
-- DONE. Now go to the Authentication tab and:
--   1. Auth → Providers → Email → turn OFF "Confirm email" (so you can create
--      users with passwords without email confirmation).
--   2. Auth → URL Configuration → Site URL: paste your Netlify URL.
--   3. Auth → Users → Add user → Create new user → julius@lifehousereentry.com
--      with password Jupiter2433!  ← Check "Auto Confirm User"
-- ============================================================================
