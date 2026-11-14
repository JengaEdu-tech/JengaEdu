-- JengaEdu: school calendar and cross-school public opportunities board
-- Additive migration. Requires schools, school_memberships and is_active_school_member(uuid).
begin;

create table if not exists public.school_events (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 school_name text not null,
 title text not null check(length(trim(title)) between 3 and 180),
 event_type text not null default 'Academic',
 description text not null default '',
 starts_at timestamptz not null,
 ends_at timestamptz,
 location text not null default '',
 visibility text not null default 'private' check(visibility in ('private','public')),
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(ends_at is null or ends_at >= starts_at)
);
create index if not exists school_events_public_date_idx
 on public.school_events(starts_at) where visibility='public';
create index if not exists school_events_school_date_idx
 on public.school_events(school_id,starts_at);
alter table public.school_events enable row level security;

drop policy if exists "Public can view published school events" on public.school_events;
create policy "Public can view published school events" on public.school_events
 for select to anon,authenticated using (
  visibility='public' and exists(select 1 from public.schools s where s.id=school_id and s.status='active')
 );
drop policy if exists "School members view own calendar" on public.school_events;
create policy "School members view own calendar" on public.school_events
 for select to authenticated using(public.is_active_school_member(school_id));
drop policy if exists "School members create own events" on public.school_events;
create policy "School members create own events" on public.school_events
 for insert to authenticated with check(public.is_active_school_member(school_id) and created_by=auth.uid());
drop policy if exists "School members update own events" on public.school_events;
create policy "School members update own events" on public.school_events
 for update to authenticated using(public.is_active_school_member(school_id))
 with check(public.is_active_school_member(school_id));
drop policy if exists "School members delete own events" on public.school_events;
create policy "School members delete own events" on public.school_events
 for delete to authenticated using(public.is_active_school_member(school_id));
grant select on public.school_events to anon,authenticated;
grant insert,update,delete on public.school_events to authenticated;

create table if not exists public.school_opportunities (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 publisher_name text not null,
 title text not null check(length(trim(title)) between 4 and 180),
 category text not null default 'Other',
 location text not null default '',
 deadline date,
 description text not null default '',
 requirements text not null default '',
 application_instructions text not null default '',
 contact_email text not null default '',
 contact_phone text not null default '',
 status text not null default 'draft' check(status in ('draft','published','closed')),
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists school_opportunities_public_idx
 on public.school_opportunities(deadline,created_at desc) where status='published';
create index if not exists school_opportunities_school_idx
 on public.school_opportunities(school_id,created_at desc);
alter table public.school_opportunities enable row level security;

drop policy if exists "Public can view published opportunities" on public.school_opportunities;
create policy "Public can view published opportunities" on public.school_opportunities
 for select to anon,authenticated using (
  status='published' and (deadline is null or deadline >= current_date)
  and exists(select 1 from public.schools s where s.id=school_id and s.status='active')
 );
drop policy if exists "School members view own opportunities" on public.school_opportunities;
create policy "School members view own opportunities" on public.school_opportunities
 for select to authenticated using(public.is_active_school_member(school_id));
drop policy if exists "School members create opportunities" on public.school_opportunities;
create policy "School members create opportunities" on public.school_opportunities
 for insert to authenticated with check(public.is_active_school_member(school_id) and created_by=auth.uid());
drop policy if exists "School members update opportunities" on public.school_opportunities;
create policy "School members update opportunities" on public.school_opportunities
 for update to authenticated using(public.is_active_school_member(school_id))
 with check(public.is_active_school_member(school_id));
drop policy if exists "School members delete opportunities" on public.school_opportunities;
create policy "School members delete opportunities" on public.school_opportunities
 for delete to authenticated using(public.is_active_school_member(school_id));
grant select on public.school_opportunities to anon,authenticated;
grant insert,update,delete on public.school_opportunities to authenticated;

commit;
