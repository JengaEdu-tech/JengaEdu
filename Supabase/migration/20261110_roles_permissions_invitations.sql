-- JengaEdu roles, permissions and invitations
-- Run AFTER multi-school-foundation.sql and multi-school-approval-migration.sql.
-- Back up your database before production use.

-- 1. Expand membership roles.
alter table public.school_memberships
  drop constraint if exists school_memberships_role_check;

alter table public.school_memberships
  add constraint school_memberships_role_check
  check (role in ('school_admin','teacher','staff','bursar','accountant','librarian'));

-- Membership suspension is separate from the school-wide active/suspended state.
alter table public.school_memberships
  add column if not exists status text not null default 'active'
  check (status in ('active','suspended'));

create or replace function public.is_school_member(target_school uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.school_memberships
    where school_id=target_school and user_id=auth.uid() and status='active');
$$;

-- 2. Platform roles. The original platform_admins table remains the owner/manager list.
-- Add an explicit role so the owner can invite platform managers without giving
-- everyone owner-level powers.
alter table public.platform_admins
  add column if not exists role text not null default 'platform_owner'
  check (role in ('platform_owner','platform_manager'));

-- Existing platform admins remain owners unless explicitly changed.
update public.platform_admins
set role = 'platform_owner'
where role is null;

create or replace function public.platform_role()
returns text
language sql stable security definer set search_path=public
as $$
  select role from public.platform_admins where user_id = auth.uid() limit 1
$$;

create or replace function public.is_platform_owner()
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1 from public.platform_admins
    where user_id = auth.uid() and role = 'platform_owner'
  )
$$;

-- Only the platform owner may approve, reject or suspend schools.
create or replace function public.set_school_status(p_school_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_owner() then
   raise exception 'Platform owner access required';
 end if;
 if p_status not in ('active','suspended','rejected') then
   raise exception 'Invalid school status';
 end if;
 update public.schools set status=p_status where id=p_school_id;
 if not found then raise exception 'School not found'; end if;
end $$;
grant execute on function public.set_school_status(uuid,text) to authenticated;

-- 3. Invitation records. An invitation is scoped to one school and role.
create table if not exists public.school_invitations (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  email text not null,
  role text not null check (role in ('school_admin','teacher','staff','bursar','accountant','librarian')),
  token uuid not null default gen_random_uuid() unique,
  invited_by uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','cancelled','expired')),
  expires_at timestamptz not null default (now() + interval '7 days'),
  created_at timestamptz not null default now()
);

create unique index if not exists school_invitations_pending_email_idx
on public.school_invitations (school_id, lower(email))
where status = 'pending';

alter table public.school_invitations enable row level security;

-- Helper: current user is an active school admin for the target school.
create or replace function public.is_active_school_admin(target_school uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select exists(
    select 1
    from public.school_memberships m
    join public.schools s on s.id = m.school_id
    where m.school_id = target_school
      and m.user_id = auth.uid()
      and m.role = 'school_admin'
      and m.status = 'active'
      and s.status = 'active'
  )
$$;

-- School admins create invitations only for their own active school.
drop policy if exists "school admins manage invitations" on public.school_invitations;
create policy "school admins manage invitations"
on public.school_invitations
for all to authenticated
using (public.is_active_school_admin(school_id) or public.is_platform_admin())
with check (public.is_active_school_admin(school_id) or public.is_platform_admin());

-- 4. Secure invitation creation.
create or replace function public.create_school_invitation(
  p_school_id uuid,
  p_email text,
  p_role text
)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if not public.is_active_school_admin(p_school_id) and not public.is_platform_admin() then
    raise exception 'School administrator access required';
  end if;

  if p_role not in ('school_admin','teacher','staff','bursar','accountant','librarian') then
    raise exception 'Invalid school role';
  end if;

  if length(trim(coalesce(p_email,''))) < 5 then
    raise exception 'A valid email is required';
  end if;

  insert into public.school_invitations(school_id,email,role,invited_by)
  values(p_school_id,lower(trim(p_email)),p_role,auth.uid())
  on conflict (school_id, lower(email)) where status='pending'
  do update set role=excluded.role, invited_by=excluded.invited_by,
                expires_at=now()+interval '7 days', created_at=now()
  returning id into v_id;

  return v_id;
end $$;
grant execute on function public.create_school_invitation(uuid,text,text) to authenticated;

-- 5. Secure invitation acceptance. The signed-in user's email must match.
create or replace function public.accept_school_invitation(p_token uuid)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  v_inv public.school_invitations%rowtype;
  v_email text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select lower(email) into v_email from auth.users where id=auth.uid();
  select * into v_inv
  from public.school_invitations
  where token=p_token and status='pending' and expires_at>now()
  for update;

  if not found then raise exception 'Invitation is invalid or expired'; end if;
  if lower(v_inv.email) <> lower(coalesce(v_email,'')) then
    raise exception 'This invitation belongs to a different email address';
  end if;

  insert into public.school_memberships(school_id,user_id,role,status)
  values(v_inv.school_id,auth.uid(),v_inv.role,'active')
  on conflict (school_id,user_id) do update set role=excluded.role,status='active';

  update public.school_invitations
  set status='accepted'
  where id=v_inv.id;

  return v_inv.school_id;
end $$;
grant execute on function public.accept_school_invitation(uuid) to authenticated;

-- 6. Membership visibility and management.
drop policy if exists "members view own memberships" on public.school_memberships;
create policy "members view own memberships"
on public.school_memberships
for select to authenticated
using (
  user_id=auth.uid()
  or public.is_platform_admin()
  or public.is_active_school_admin(school_id)
);

drop policy if exists "school admins manage memberships" on public.school_memberships;
create policy "school admins manage memberships"
on public.school_memberships
for all to authenticated
using (public.is_active_school_admin(school_id) or public.is_platform_admin())
with check (public.is_active_school_admin(school_id) or public.is_platform_admin());

-- Suspended memberships must lose school-state access immediately.
drop policy if exists "active members read own school state" on public.school_state_shared;
drop policy if exists "active admins create own school state" on public.school_state_shared;
drop policy if exists "active members update own school state" on public.school_state_shared;
create policy "active members read own school state" on public.school_state_shared
for select to authenticated using (
  exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id
    where m.user_id=auth.uid() and m.school_id::text=school_state_shared.id
      and m.status='active' and s.status='active')
);
create policy "active admins create own school state" on public.school_state_shared
for insert to authenticated with check (
  exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id
    where m.user_id=auth.uid() and m.role='school_admin' and m.status='active'
      and m.school_id::text=school_state_shared.id and s.status='active')
);
create policy "active members update own school state" on public.school_state_shared
for update to authenticated using (
  exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id
    where m.user_id=auth.uid() and m.school_id::text=school_state_shared.id
      and m.status='active' and s.status='active')
) with check (
  exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id
    where m.user_id=auth.uid() and m.school_id::text=school_state_shared.id
      and m.status='active' and s.status='active')
);

-- IMPORTANT:
-- The existing school_state_shared policies control access at the school level.
-- For feature-level restrictions, keep major configuration and destructive actions
-- behind school_admin-only database functions or policies. Teachers should not rely
-- only on hidden buttons in the browser.
