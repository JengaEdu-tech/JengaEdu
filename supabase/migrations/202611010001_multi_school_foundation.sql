-- JengaEdu Multi-School foundation. REVIEW and run only after a database backup.
-- This does not alter or delete existing school_state records.
create extension if not exists pgcrypto;
create table if not exists public.schools (
 id uuid primary key default gen_random_uuid(), name text not null, slug text not null unique,
 school_type text not null default 'Comprehensive', county text, country text not null default 'Kenya',
 logo_url text, status text not null default 'pending' check(status in ('pending','active','suspended')),
 created_at timestamptz not null default now());
create table if not exists public.school_memberships (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null default 'school_admin' check(role in ('school_admin','teacher','bursar','staff')),
 created_at timestamptz not null default now(), unique(school_id,user_id));
create table if not exists public.platform_admins(user_id uuid primary key references auth.users(id) on delete cascade,created_at timestamptz not null default now());
alter table public.schools enable row level security;
alter table public.school_memberships enable row level security;
alter table public.platform_admins enable row level security;
create or replace function public.is_platform_admin() returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from public.platform_admins where user_id=auth.uid());$$;
create or replace function public.is_school_member(target_school uuid) returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from public.school_memberships where school_id=target_school and user_id=auth.uid());$$;
create policy "members view their schools" on public.schools for select using(public.is_school_member(id) or public.is_platform_admin());
create policy "platform admins manage schools" on public.schools for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "members view own memberships" on public.school_memberships for select using(user_id=auth.uid() or public.is_platform_admin());
create policy "platform admins manage memberships" on public.school_memberships for all using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy "platform admins view themselves" on public.platform_admins for select using(user_id=auth.uid());
-- Signup MUST run in a trusted Edge Function/service-role environment (never browser): create Auth user,
-- create school row, create membership, verify email, then activate school.
-- Before production: add/backfill school_id on every school-owned table/state, enforce RLS,
-- scope all app reads/writes to active school, and test two-school isolation.
