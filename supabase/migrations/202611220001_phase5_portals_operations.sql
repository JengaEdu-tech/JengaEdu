-- JengaEdu Phase 5: secure multi-user portals, school operations and AI papers.
-- Apply after 202611210001_v5_multischool_timetable.sql.
-- Back up the database first. This migration is additive and does not rewrite legacy JSONB data.

begin;

-- Fine-grained permission helper. Keep all decisions in Postgres, not in browser-only checks.
create or replace function public.has_school_role(p_school_id uuid, p_roles text[])
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and exists (
    select 1 from public.school_memberships m
    join public.schools s on s.id=m.school_id
    where m.school_id=p_school_id and m.user_id=auth.uid()
      and m.status='active' and s.status='active'
      and m.role=any(p_roles)
  );
$$;
revoke all on function public.has_school_role(uuid,text[]) from public,anon;
grant execute on function public.has_school_role(uuid,text[]) to authenticated;

create or replace function public.is_school_platform_owner()
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $$
 select auth.uid() is not null and exists(
   select 1 from public.platform_admins p where p.user_id=auth.uid()
 );
$$;
revoke all on function public.is_school_platform_owner() from public,anon;
grant execute on function public.is_school_platform_owner() to authenticated;

-- Portal account links are explicitly approved by a school administrator.
create table if not exists public.school_portal_links (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 learner_id text not null,
 portal_role text not null check (portal_role in ('parent','learner')),
 relationship text,
 created_at timestamptz not null default now(),
 created_by uuid references auth.users(id),
 unique(school_id,user_id,learner_id,portal_role)
);
create index if not exists school_portal_links_user_idx on public.school_portal_links(user_id,school_id);
alter table public.school_portal_links enable row level security;

drop policy if exists portal_link_self_read on public.school_portal_links;
create policy portal_link_self_read on public.school_portal_links
 for select to authenticated using (user_id=auth.uid());
drop policy if exists portal_link_admin_manage on public.school_portal_links;
create policy portal_link_admin_manage on public.school_portal_links
 for all to authenticated
 using (public.has_school_role(school_id,array['school_admin','headteacher']) or public.is_school_platform_owner())
 with check (public.has_school_role(school_id,array['school_admin','headteacher']) or public.is_school_platform_owner());
grant select,insert,update,delete on public.school_portal_links to authenticated;

-- Invitations are email-bound and expire. A trusted Edge Function sends the email;
-- acceptance must use the same verified Supabase Auth email.
create table if not exists public.school_portal_invitations (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 email text not null,
 portal_role text not null check (portal_role in ('parent','learner')),
 learner_ids text[] not null default '{}',
 token uuid not null unique default gen_random_uuid(),
 status text not null default 'pending' check (status in ('pending','accepted','cancelled','expired')),
 expires_at timestamptz not null default now()+interval '7 days',
 invited_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 accepted_at timestamptz
);
create index if not exists school_portal_invites_school_idx on public.school_portal_invitations(school_id,status);
alter table public.school_portal_invitations enable row level security;
drop policy if exists portal_invites_admin_read on public.school_portal_invitations;
create policy portal_invites_admin_read on public.school_portal_invitations
 for select to authenticated using (public.has_school_role(school_id,array['school_admin','headteacher']) or public.is_school_platform_owner());
drop policy if exists portal_invites_admin_insert on public.school_portal_invitations;
create policy portal_invites_admin_insert on public.school_portal_invitations
 for insert to authenticated with check (
   (public.has_school_role(school_id,array['school_admin','headteacher']) or public.is_school_platform_owner())
   and invited_by=auth.uid()
 );
drop policy if exists portal_invites_admin_update on public.school_portal_invitations;
create policy portal_invites_admin_update on public.school_portal_invitations
 for update to authenticated using (public.has_school_role(school_id,array['school_admin','headteacher']) or public.is_school_platform_owner())
 with check (public.has_school_role(school_id,array['school_admin','headteacher']) or public.is_school_platform_owner());
grant select,insert,update on public.school_portal_invitations to authenticated;

create or replace function public.accept_school_portal_invitation(p_token uuid)
returns integer language plpgsql security definer
set search_path=public,auth,pg_temp as $$
declare v_inv public.school_portal_invitations%rowtype; v_email text; v_count integer:=0; v_learner text;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Sign in first'; end if;
 select lower(email) into v_email from auth.users where id=auth.uid();
 select * into v_inv from public.school_portal_invitations
  where token=p_token and status='pending' and expires_at>now() for update;
 if not found then raise exception using errcode='22023',message='Invitation is invalid, expired or already used'; end if;
 if lower(v_inv.email)<>lower(coalesce(v_email,'')) then
  raise exception using errcode='42501',message='Sign in with the invited email address';
 end if;
 foreach v_learner in array v_inv.learner_ids loop
  insert into public.school_portal_links(school_id,user_id,learner_id,portal_role,created_by)
  values(v_inv.school_id,auth.uid(),v_learner,v_inv.portal_role,v_inv.invited_by)
  on conflict do nothing;
  v_count:=v_count+1;
 end loop;
 update public.school_portal_invitations set status='accepted',accepted_at=now() where id=v_inv.id;
 return v_count;
end $$;
revoke all on function public.accept_school_portal_invitation(uuid) from public,anon;
grant execute on function public.accept_school_portal_invitation(uuid) to authenticated;

-- Portal-safe learner snapshot: only the linked learner record is returned.
-- Legacy data is held in one school JSON document; this function filters it server-side.
create or replace function public.get_my_portal_learners(p_school_id uuid)
returns jsonb language sql stable security definer
set search_path=public,auth,pg_temp as $$
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',l.item->>'id','adm',l.item->>'adm','name',l.item->>'name',
   'class',l.item->>'class','stream',l.item->>'stream',
   'parent',l.item->>'parent','photoData',l.item->>'photoData'
 )),'[]'::jsonb)
 from public.school_portal_links x
 join public.school_state_shared s on s.id=x.school_id::text
 cross join lateral jsonb_array_elements(coalesce(s.data->'learners','[]'::jsonb)) l(item)
 where x.school_id=p_school_id and x.user_id=auth.uid()
   and l.item->>'id'=x.learner_id
   and x.portal_role in ('parent','learner')
   and exists(select 1 from public.schools sc where sc.id=x.school_id and sc.status='active')
$$;
revoke all on function public.get_my_portal_learners(uuid) from public,anon;
grant execute on function public.get_my_portal_learners(uuid) to authenticated;

-- Normalized school operations and communications, separate from the legacy JSON blob.
create table if not exists public.school_operations_tasks (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 title text not null,
 category text not null default 'General',
 due_date date,
 assigned_to uuid references auth.users(id),
 status text not null default 'open' check(status in ('open','in_progress','done','cancelled')),
 notes text,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.school_operations_tasks enable row level security;
drop policy if exists operations_task_read on public.school_operations_tasks;
create policy operations_task_read on public.school_operations_tasks for select to authenticated
 using(public.is_active_school_member(school_id));
drop policy if exists operations_task_write on public.school_operations_tasks;
create policy operations_task_write on public.school_operations_tasks for all to authenticated
 using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','staff','support_staff']))
 with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','staff','support_staff']));
grant select,insert,update,delete on public.school_operations_tasks to authenticated;

create table if not exists public.school_message_campaigns (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 title text not null,
 channel text not null check(channel in ('sms','whatsapp')),
 message_body text not null,
 recipient_count integer not null default 0,
 status text not null default 'draft' check(status in ('draft','queued','submitted','failed','cancelled')),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.school_message_campaigns enable row level security;
drop policy if exists message_campaign_read on public.school_message_campaigns;
create policy message_campaign_read on public.school_message_campaigns for select to authenticated
 using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher','bursar']));
drop policy if exists message_campaign_write on public.school_message_campaigns;
create policy message_campaign_write on public.school_message_campaigns for insert to authenticated
 with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher']) and created_by=auth.uid());
grant select,insert on public.school_message_campaigns to authenticated;

create table if not exists public.school_ai_question_papers (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 title text not null,
 class_name text not null,
 subject text not null,
 term text,
 academic_year text,
 curriculum text not null default 'Kenya CBC/CBE',
 paper_json jsonb not null default '{}'::jsonb,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.school_ai_question_papers enable row level security;
drop policy if exists ai_paper_read on public.school_ai_question_papers;
create policy ai_paper_read on public.school_ai_question_papers for select to authenticated
 using(public.is_active_school_member(school_id));
drop policy if exists ai_paper_write on public.school_ai_question_papers;
create policy ai_paper_write on public.school_ai_question_papers for all to authenticated
 using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher']))
 with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher']) and created_by=auth.uid());
grant select,insert,update,delete on public.school_ai_question_papers to authenticated;

-- Ensure delivery attempts are partitioned by school; the Edge Function already supplies school_id.
alter table public.notification_delivery_logs
 add column if not exists school_id uuid references public.schools(id) on delete cascade;
create index if not exists notification_delivery_logs_school_idx
 on public.notification_delivery_logs(school_id,created_at desc);

-- Restrict private delivery logs to authorized school staff in that same school.
drop policy if exists notification_delivery_logs_select_auth on public.notification_delivery_logs;
drop policy if exists notification_delivery_logs_staff_read on public.notification_delivery_logs;
create policy notification_delivery_logs_staff_read on public.notification_delivery_logs
 for select to authenticated using (
   school_id is not null and public.has_school_role(school_id,
     array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant'])
 );

commit;
