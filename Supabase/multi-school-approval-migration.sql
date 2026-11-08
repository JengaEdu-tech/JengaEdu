-- JengaEdu secure school registration and owner-only approval workflow.
-- Run after Supabase/multi-school-foundation.sql. Back up first.

alter table public.schools drop constraint if exists schools_status_check;
alter table public.schools add constraint schools_status_check check(status in ('pending','active','suspended','rejected'));

-- Public/authenticated users may create only their own pending school through this function.
create or replace function public.register_school_application(p_name text,p_school_type text,p_county text,p_country text default 'Kenya')
returns uuid language plpgsql security definer set search_path=public as $$
declare v_school uuid; v_slug text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if exists(select 1 from public.school_memberships where user_id=auth.uid()) then raise exception 'This account is already linked to a school'; end if;
 if length(trim(coalesce(p_name,''))) < 2 then raise exception 'School name is required'; end if;
 v_slug:=lower(regexp_replace(trim(p_name),'[^a-zA-Z0-9]+','-','g'))||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,8);
 insert into public.schools(name,slug,school_type,county,country,status) values(trim(p_name),v_slug,coalesce(nullif(trim(p_school_type),''),'Comprehensive'),nullif(trim(p_county),''),coalesce(nullif(trim(p_country),''),'Kenya'),'pending') returning id into v_school;
 insert into public.school_memberships(school_id,user_id,role) values(v_school,auth.uid(),'school_admin');
 return v_school;
end $$;
grant execute on function public.register_school_application(text,text,text,text) to authenticated;

-- Only the platform owner can change status. No browser table update policy grants this power.
create or replace function public.set_school_status(p_school_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform owner access required'; end if;
 if p_status not in ('active','suspended','rejected') then raise exception 'Invalid school status'; end if;
 update public.schools set status=p_status where id=p_school_id;
 if not found then raise exception 'School not found'; end if;
end $$;
grant execute on function public.set_school_status(uuid,text) to authenticated;

-- Replace the old single-school state policies with tenant isolation.
drop policy if exists "school_state_shared_select_auth" on public.school_state_shared;
drop policy if exists "school_state_shared_insert_auth" on public.school_state_shared;
drop policy if exists "school_state_shared_update_auth" on public.school_state_shared;
create policy "active members read own school state" on public.school_state_shared for select to authenticated using (
 exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and m.school_id::text=school_state_shared.id and s.status='active'));
create policy "active admins create own school state" on public.school_state_shared for insert to authenticated with check (
 exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and m.role='school_admin' and m.school_id::text=school_state_shared.id and s.status='active'));
create policy "active members update own school state" on public.school_state_shared for update to authenticated using (
 exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and m.school_id::text=school_state_shared.id and s.status='active')) with check (
 exists(select 1 from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and m.school_id::text=school_state_shared.id and s.status='active'));

-- Owner dashboard needs to see all schools; school users see only their own.
drop policy if exists "members view their schools" on public.schools;
create policy "members view their schools" on public.schools for select using(public.is_school_member(id) or public.is_platform_admin());

-- ONE-TIME OWNER SETUP: replace with your already-created platform owner Auth UUID.
-- insert into public.platform_admins(user_id) values ('YOUR-OWNER-AUTH-UUID') on conflict do nothing;
