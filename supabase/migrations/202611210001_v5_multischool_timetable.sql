-- JengaEdu V5: multi-school hardening + normalized timetable mirror.
-- Additive migration. Back up the database and review the existing membership
-- roles before applying. The legacy JSONB workspace remains in place.

begin;

-- 1) Membership lifecycle and role vocabulary.
alter table public.school_memberships
  add column if not exists status text not null default 'active';
update public.school_memberships set status='active' where status is null;
alter table public.school_memberships alter column status set default 'active';
alter table public.school_memberships alter column status set not null;
alter table public.school_memberships
  drop constraint if exists school_memberships_status_check;
alter table public.school_memberships
  add constraint school_memberships_status_check
  check (status in ('active','suspended','pending'));

do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.school_memberships'::regclass
      and contype='c'
      and pg_get_constraintdef(oid) ilike '%role%'
  loop
    execute format('alter table public.school_memberships drop constraint %I',c.conname);
  end loop;
end $$;
update public.school_memberships set role=case lower(role)
  when 'admin' then 'school_admin' when 'administrator' then 'school_admin'
  when 'head' then 'headteacher' when 'deputy' then 'deputy_headteacher'
  when 'finance' then 'bursar' else lower(role) end;
alter table public.school_memberships
  add constraint school_memberships_role_check
  check (role in ('school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff','parent','learner'));

-- Extend the staff invitation role set to match the V5 school roles.
alter table public.school_invitations drop constraint if exists school_invitations_role_check;
alter table public.school_invitations add constraint school_invitations_role_check
  check (role in ('school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff'));

-- 2) School-scoped authorization helpers. SECURITY DEFINER is tightly scoped
-- and exposes only boolean decisions, not membership rows.
create or replace function public.is_school_member(target_school uuid)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select auth.uid() is not null and exists(
    select 1 from public.school_memberships m
    where m.school_id=target_school and m.user_id=auth.uid() and m.status='active'
  );
$$;
revoke all on function public.is_school_member(uuid) from public,anon;
grant execute on function public.is_school_member(uuid) to authenticated;

create or replace function public.is_active_school_member(target_school uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $$
  select auth.uid() is not null and exists (
    select 1 from public.school_memberships m
    join public.schools s on s.id=m.school_id
    join public.school_subscriptions sub on sub.school_id=s.id
    where m.school_id=target_school and m.user_id=auth.uid()
      and m.status='active' and s.status='active'
      and ((sub.status='trialing' and sub.trial_ends_at + interval '7 days' > now())
        or (sub.status='active' and sub.current_period_end + interval '7 days' > now())
        or (sub.status='past_due' and sub.grace_ends_at > now()))
  );
$$;
revoke all on function public.is_active_school_member(uuid) from public,anon;
grant execute on function public.is_active_school_member(uuid) to authenticated;

create or replace function public.has_school_role(p_school_id uuid,p_roles text[])
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $$
  select auth.uid() is not null and public.is_active_school_member(p_school_id) and exists (
    select 1 from public.school_memberships m
    where m.school_id=p_school_id and m.user_id=auth.uid()
      and m.status='active' and m.role=any(p_roles)
  );
$$;
revoke all on function public.has_school_role(uuid,text[]) from public,anon;
grant execute on function public.has_school_role(uuid,text[]) to authenticated;
create or replace function public.is_active_school_admin(target_school uuid)
returns boolean language sql stable security definer set search_path=public,auth,pg_temp as $$
  select public.has_school_role(target_school,array['school_admin']);
$$;
revoke all on function public.is_active_school_admin(uuid) from public,anon;
grant execute on function public.is_active_school_admin(uuid) to authenticated;

create or replace function public.create_school_invitation(p_school_id uuid,p_email text,p_role text)
returns uuid language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_id uuid;
begin
  if not public.has_school_role(p_school_id,array['school_admin']) and not public.is_platform_admin() then
    raise exception using errcode='42501',message='School administrator access required';
  end if;
  if p_role not in ('school_admin','headteacher','deputy_headteacher','teacher','staff','support_staff','bursar','accountant','librarian') then
    raise exception using errcode='22023',message='Invalid school role';
  end if;
  if length(trim(coalesce(p_email,'')))<5 then raise exception using errcode='22023',message='A valid email is required'; end if;
  insert into public.school_invitations(school_id,email,role,invited_by)
  values(p_school_id,lower(trim(p_email)),p_role,auth.uid())
  on conflict (school_id,lower(email)) where status='pending'
  do update set role=excluded.role,invited_by=excluded.invited_by,expires_at=now()+interval '7 days',created_at=now()
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.create_school_invitation(uuid,text,text) from public,anon;
grant execute on function public.create_school_invitation(uuid,text,text) to authenticated;

-- 3) Workspace membership management must be explicit and school-scoped.
create or replace function public.set_school_member_role(p_school_id uuid,p_user_id uuid,p_role text)
returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $$
declare v_admin_count integer;
begin
  if not public.has_school_role(p_school_id,array['school_admin']) and not public.is_platform_admin() then
    raise exception using errcode='42501',message='School administrator permission required';
  end if;
  if p_role not in ('school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff') then
    raise exception using errcode='22023',message='Invalid staff role';
  end if;
  if not exists(select 1 from public.school_memberships where school_id=p_school_id and user_id=p_user_id) then
    raise exception using errcode='P0002',message='School membership not found';
  end if;
  if p_role<>'school_admin' then
    select count(*) into v_admin_count from public.school_memberships
      where school_id=p_school_id and role='school_admin' and status='active' and user_id<>p_user_id;
    if v_admin_count=0 and exists(select 1 from public.school_memberships where school_id=p_school_id and user_id=p_user_id and role='school_admin' and status='active') then
      raise exception using errcode='23514',message='A school must retain at least one active school administrator';
    end if;
  end if;
  update public.school_memberships set role=p_role where school_id=p_school_id and user_id=p_user_id;
end $$;
revoke all on function public.set_school_member_role(uuid,uuid,text) from public,anon;
grant execute on function public.set_school_member_role(uuid,uuid,text) to authenticated;

create or replace function public.set_school_member_status(p_school_id uuid,p_user_id uuid,p_status text)
returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $$
declare v_admin_count integer;
begin
  if not public.has_school_role(p_school_id,array['school_admin']) and not public.is_platform_admin() then
    raise exception using errcode='42501',message='School administrator permission required';
  end if;
  if p_status not in ('active','suspended','pending') then
    raise exception using errcode='22023',message='Invalid membership status';
  end if;
  if not exists(select 1 from public.school_memberships where school_id=p_school_id and user_id=p_user_id) then
    raise exception using errcode='P0002',message='School membership not found';
  end if;
  if p_user_id=auth.uid() and p_status<>'active' then
    raise exception using errcode='23514',message='You cannot suspend your own active administrator account';
  end if;
  if p_status<>'active' and exists(select 1 from public.school_memberships where school_id=p_school_id and user_id=p_user_id and role='school_admin' and status='active') then
    select count(*) into v_admin_count from public.school_memberships where school_id=p_school_id and role='school_admin' and status='active' and user_id<>p_user_id;
    if v_admin_count=0 then raise exception using errcode='23514',message='A school must retain at least one active administrator'; end if;
  end if;
  update public.school_memberships set status=p_status where school_id=p_school_id and user_id=p_user_id;
end $$;
revoke all on function public.set_school_member_status(uuid,uuid,text) from public,anon;
grant execute on function public.set_school_member_status(uuid,uuid,text) to authenticated;

create or replace function public.remove_school_member(p_school_id uuid,p_user_id uuid)
returns void language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_admin_count integer;
begin
  if auth.uid() is null or (not public.has_school_role(p_school_id,array['school_admin']) and not public.is_platform_admin()) then
    raise exception using errcode='42501',message='School administrator permission required';
  end if;
  if p_user_id=auth.uid() then raise exception using errcode='23514',message='You cannot remove your own active account'; end if;
  if exists(select 1 from public.school_memberships where school_id=p_school_id and user_id=p_user_id and role='school_admin' and status='active') then
    select count(*) into v_admin_count from public.school_memberships where school_id=p_school_id and role='school_admin' and status='active' and user_id<>p_user_id;
    if v_admin_count=0 then raise exception using errcode='23514',message='A school must retain at least one active administrator'; end if;
  end if;
  update public.school_memberships set status='suspended' where school_id=p_school_id and user_id=p_user_id;
  if not found then raise exception using errcode='P0002',message='School membership not found'; end if;
end $$;
revoke all on function public.remove_school_member(uuid,uuid) from public,anon;
grant execute on function public.remove_school_member(uuid,uuid) to authenticated;

-- Tighten calendar/opportunity writes and subscription billing visibility.
DO $$ DECLARE t text; p record; BEGIN
  FOREACH t IN ARRAY ARRAY['school_events','school_opportunities','school_subscriptions','subscription_invoices','subscription_payment_attempts'] LOOP
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
      EXECUTE format('drop policy if exists %I on public.%I',p.policyname,t);
    END LOOP;
  END LOOP;
END $$;

create policy school_events_public_read on public.school_events for select to anon,authenticated
  using(visibility='public' and exists(select 1 from public.schools s where s.id=school_id and s.status='active'));
create policy school_events_member_read on public.school_events for select to authenticated
  using(public.is_active_school_member(school_id));
create policy school_events_staff_insert on public.school_events for insert to authenticated
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher']) and created_by=auth.uid());
create policy school_events_admin_update on public.school_events for update to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));
create policy school_events_admin_delete on public.school_events for delete to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));

create policy school_opportunities_public_read on public.school_opportunities for select to anon,authenticated
  using(status='published' and (deadline is null or deadline>=current_date)
    and exists(select 1 from public.schools s where s.id=school_id and s.status='active'));
create policy school_opportunities_member_read on public.school_opportunities for select to authenticated
  using(public.is_active_school_member(school_id));
create policy school_opportunities_admin_insert on public.school_opportunities for insert to authenticated
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']) and created_by=auth.uid());
create policy school_opportunities_admin_update on public.school_opportunities for update to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));
create policy school_opportunities_admin_delete on public.school_opportunities for delete to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));

-- Subscription status is readable by active members so the client can gate
-- access. Financial invoices and payment attempts are restricted to billing staff.
create policy school_subscriptions_member_read on public.school_subscriptions for select to authenticated
  using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id=school_subscriptions.school_id and m.user_id=auth.uid() and m.status='active'));
create policy subscription_invoices_billing_read on public.subscription_invoices for select to authenticated
  using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id=subscription_invoices.school_id and m.user_id=auth.uid() and m.status='active' and m.role in ('school_admin','bursar','accountant')));
create policy subscription_payment_attempts_billing_read on public.subscription_payment_attempts for select to authenticated
  using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id=subscription_payment_attempts.school_id and m.user_id=auth.uid() and m.status='active' and m.role in ('school_admin','bursar','accountant')));

-- 4) Replace permissive legacy JSONB policies with school-bound policies.
-- This is still a coarse workspace boundary; normalized modules below provide
-- more granular permissions. Do not treat JSONB as field-level authorization.
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='school_state_shared'
  loop execute format('drop policy if exists %I on public.school_state_shared',p.policyname); end loop;
end $$;
alter table public.school_state_shared enable row level security;
create policy jenga_v5_state_select on public.school_state_shared
  for select to authenticated
  using (public.is_platform_admin() or (case when id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.has_school_role(id::uuid,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']) else false end));
create policy jenga_v5_state_insert on public.school_state_shared
  for insert to authenticated
  with check (public.is_platform_admin() or (case when id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.has_school_role(id::uuid,array['school_admin']) else false end));
create policy jenga_v5_state_update on public.school_state_shared
  for update to authenticated
  using (public.is_platform_admin() or (case when id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.has_school_role(id::uuid,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']) else false end))
  with check (public.is_platform_admin() or (case when id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then public.has_school_role(id::uuid,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']) else false end));
grant select,insert,update on public.school_state_shared to authenticated;

-- Scope the existing patch-save RPC to the role in the exact target school.
-- This removes the old global current_school_role() first-membership ambiguity.
create or replace function public.apply_school_state_patch(
  p_id text,
  p_patch jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  current_data jsonb;
  next_data jsonb;
  item record;
  row_key text;
  incoming jsonb;
  removed_ids jsonb;
  existing_rows jsonb;
  merged_rows jsonb;
  obj_key text;
  obj_change jsonb;
  field_key text;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Authentication required';
  end if;
  if not public.is_platform_admin() and not (case
    when p_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.has_school_role(p_id::uuid,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff'])
    else false end) then
    raise exception using errcode='42501', message='You do not have active write access to this school workspace';
  end if;
  if jsonb_typeof(p_patch) <> 'object' then
    raise exception using errcode='22023', message='Invalid change set';
  end if;

  select data into current_data
    from public.school_state_shared
   where id=p_id
   for update;
  if current_data is null then
    raise exception using errcode='P0002', message='School shared record not found';
  end if;
  next_data := current_data;

  -- Apply deletions first, then upserts. Marks are uniquely identified by
  -- learner + assessment + subject, even if two clients generated different IDs.
  for row_key in select jsonb_object_keys(coalesce(p_patch->'deletes','{}'::jsonb))
  loop
    if row_key not in ('learners','teachers','teacherLoads','payments','marks','attendance','timetable','exams','audit','academicPeriods','questionPapers','questionBank','capitationTransactions','bomBudgets','mealRecords','alumni','certificates','notificationLog','bookCategories','bookCatalogue','bookPurchases','classBookInventory','bookIssues','inventoryTransactions','stationeryCategories','stationeryItems','stationeryPurchases','stationeryIssuance','suppliers','stockAdjustments','reorderLevels','schoolWorkers','schoolExpenses') then
      raise exception using errcode='22023', message='Unsupported record collection';
    end if;
    removed_ids := coalesce(p_patch->'deletes'->row_key,'[]'::jsonb);
    select coalesce(jsonb_agg(r.value order by r.ordinality),'[]'::jsonb)
      into merged_rows
      from jsonb_array_elements(coalesce(next_data->row_key,'[]'::jsonb)) with ordinality r(value,ordinality)
     where not exists (
       select 1 from jsonb_array_elements_text(removed_ids) d(id)
       where d.id = r.value->>'id'
     );
    next_data := jsonb_set(next_data,array[row_key],merged_rows,true);
  end loop;

  for row_key in select jsonb_object_keys(coalesce(p_patch->'upserts','{}'::jsonb))
  loop
    if row_key not in ('learners','teachers','teacherLoads','payments','marks','attendance','timetable','exams','audit','academicPeriods','questionPapers','questionBank','capitationTransactions','bomBudgets','mealRecords','alumni','certificates','notificationLog','bookCategories','bookCatalogue','bookPurchases','classBookInventory','bookIssues','inventoryTransactions','stationeryCategories','stationeryItems','stationeryPurchases','stationeryIssuance','suppliers','stockAdjustments','reorderLevels','schoolWorkers','schoolExpenses') then
      raise exception using errcode='22023', message='Unsupported record collection';
    end if;
    incoming := coalesce(p_patch->'upserts'->row_key,'[]'::jsonb);
    if jsonb_typeof(incoming) <> 'array' then
      raise exception using errcode='22023', message='Record changes must be arrays';
    end if;

    if row_key='learners' then
      -- Enforce admission-number uniqueness for newly inserted/changed learners.
      if exists (
        select 1
          from jsonb_array_elements(incoming) n(value)
          join jsonb_array_elements(coalesce(next_data->'learners','[]'::jsonb)) prior_row(value)
            on upper(trim(prior_row.value->>'adm'))=upper(trim(n.value->>'adm'))
           and prior_row.value->>'id' <> n.value->>'id'
      ) or exists (
        select 1
          from jsonb_array_elements(incoming) n(value)
         where nullif(trim(n.value->>'adm'),'') is not null
         group by upper(trim(n.value->>'adm'))
        having count(*) > 1
      ) then
        raise exception using errcode='23505', message='Admission number already exists';
      end if;
    elsif row_key='payments' then
      if exists (
        select 1
          from jsonb_array_elements(incoming) n(value)
          join jsonb_array_elements(coalesce(next_data->'payments','[]'::jsonb)) prior_payment(value)
            on lower(trim(prior_payment.value->>'receipt'))=lower(trim(n.value->>'receipt'))
           and prior_payment.value->>'id' <> n.value->>'id'
         where nullif(trim(n.value->>'receipt'),'') is not null
      ) or exists (
        select 1 from jsonb_array_elements(incoming) n(value)
         where nullif(trim(n.value->>'receipt'),'') is not null
         group by lower(trim(n.value->>'receipt'))
        having count(*) > 1
      ) then
        raise exception using errcode='23505', message='Duplicate fee receipt/reference number';
      end if;
    end if;

    select coalesce(jsonb_agg(r.value order by r.ordinality),'[]'::jsonb)
      into existing_rows
      from jsonb_array_elements(coalesce(next_data->row_key,'[]'::jsonb)) with ordinality r(value,ordinality)
     where not exists (
       select 1 from jsonb_array_elements(incoming) n(value)
        where n.value->>'id'=r.value->>'id'
           or (row_key='marks'
               and n.value->>'learner'=r.value->>'learner'
               and n.value->>'exam'=r.value->>'exam'
               and n.value->>'subject'=r.value->>'subject')
     );
    merged_rows := existing_rows || incoming;
    next_data := jsonb_set(next_data,array[row_key],merged_rows,true);
  end loop;

  -- Merge changed object properties, preserving concurrent changes to other keys.
  for obj_key in select jsonb_object_keys(coalesce(p_patch->'objects','{}'::jsonb))
  loop
    if obj_key not in ('settings','fees','subjectConfigs','timetableMeta') then
      raise exception using errcode='22023', message='Unsupported school settings object';
    end if;
    obj_change := p_patch->'objects'->obj_key;
    if obj_change ? 'replace' then
      next_data := jsonb_set(next_data,array[obj_key],obj_change->'replace',true);
    else
      if jsonb_typeof(next_data->obj_key) <> 'object' or next_data->obj_key is null then
        next_data := jsonb_set(next_data,array[obj_key],'{}'::jsonb,true);
      end if;
      for field_key in select jsonb_array_elements_text(coalesce(obj_change->'remove','[]'::jsonb))
      loop
        next_data := next_data #- array[obj_key,field_key];
      end loop;
      for item in select key,value from jsonb_each(coalesce(obj_change->'set','{}'::jsonb))
      loop
        next_data := jsonb_set(next_data,array[obj_key,item.key],item.value,true);
      end loop;
    end if;
  end loop;

  update public.school_state_shared
     set data=next_data, updated_at=clock_timestamp()
   where id=p_id;

  return jsonb_build_object(
    'data',next_data,
    'updated_at',(select updated_at from public.school_state_shared where id=p_id)
  );
end;
$$;

revoke all on function public.apply_school_state_patch(text,jsonb) from public,anon;
grant execute on function public.apply_school_state_patch(text,jsonb) to authenticated;
-- Legacy global-role lookup is no longer an authorization source. All V5
-- authorization uses has_school_role(school_id, roles) instead.
revoke all on function public.current_school_role() from public,anon,authenticated;

-- 5) School-scope legacy certificate and notification audit records.
alter table public.certificate_issues add column if not exists school_id uuid references public.schools(id) on delete cascade;
alter table public.certificate_issues drop constraint if exists certificate_issues_certificate_no_key;
create unique index if not exists certificate_issues_school_number_uq
  on public.certificate_issues(school_id,certificate_no) where school_id is not null;
update public.certificate_issues ci set school_id=s.id::uuid
from public.school_state_shared s
cross join lateral jsonb_array_elements(coalesce(s.data->'certificates','[]'::jsonb)) c
where s.id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and c->>'id'=ci.id and ci.school_id is null;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='certificate_issues'
  loop execute format('drop policy if exists %I on public.certificate_issues',p.policyname); end loop;
end $$;
alter table public.certificate_issues enable row level security;
create policy certificate_issues_school_read on public.certificate_issues for select to authenticated
  using(school_id is not null and public.is_active_school_member(school_id)
    and public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','bursar']));
revoke all on public.certificate_issues from public,anon,authenticated;
grant select on public.certificate_issues to authenticated;

create or replace function public.issue_leaving_certificate(p_school_id uuid,p_certificate jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare c jsonb; saved_at timestamptz;
begin
  if auth.uid() is null or not public.has_school_role(p_school_id,array['school_admin','headteacher']) then
    raise exception using errcode='42501',message='Only this school''s administrator or headteacher may issue certificates';
  end if;
  if p_certificate is null or nullif(trim(p_certificate->>'certificateNo'),'') is null
     or nullif(trim(p_certificate->>'learnerId'),'') is null
     or nullif(trim(p_certificate->>'learnerName'),'') is null
     or nullif(trim(p_certificate->>'leavingDate'),'') is null then
    raise exception using errcode='22023',message='Certificate payload is incomplete';
  end if;
  c:=p_certificate||jsonb_build_object('issuedByUserId',auth.uid()::text,'issueDate',clock_timestamp());
  insert into public.certificate_issues(id,school_id,certificate_no,learner_id,learner_name,admission_number,level,issue_date,issued_by,payload)
  values(c->>'id',p_school_id,upper(c->>'certificateNo'),c->>'learnerId',c->>'learnerName',coalesce(c->>'admissionNumber',''),coalesce(c->>'level',''),(c->>'issueDate')::timestamptz,auth.uid(),c);
  update public.school_state_shared set data=jsonb_set(data,'{certificates}',coalesce(data->'certificates','[]'::jsonb)||jsonb_build_array(c),true),updated_at=clock_timestamp()
   where id=p_school_id::text returning updated_at into saved_at;
  if saved_at is null then raise exception using errcode='P0002',message='School shared record not found'; end if;
  return jsonb_build_object('certificate',c,'updated_at',saved_at);
end $$;
revoke all on function public.issue_leaving_certificate(uuid,jsonb) from public,anon;
grant execute on function public.issue_leaving_certificate(uuid,jsonb) to authenticated;
-- Disable the previous single-school RPC signature that hard-coded 'JENGAEDU'.
revoke all on function public.issue_leaving_certificate(jsonb) from public,anon,authenticated;

alter table public.notification_delivery_logs add column if not exists school_id uuid references public.schools(id) on delete cascade;
update public.notification_delivery_logs set school_id=(provider_response->>'school_id')::uuid
where school_id is null and provider_response->>'school_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
create index if not exists notification_delivery_logs_school_created_idx on public.notification_delivery_logs(school_id,created_at desc);
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='notification_delivery_logs'
  loop execute format('drop policy if exists %I on public.notification_delivery_logs',p.policyname); end loop;
end $$;
alter table public.notification_delivery_logs enable row level security;
create policy notification_delivery_logs_school_read on public.notification_delivery_logs for select to authenticated
  using(school_id is not null and public.is_active_school_member(school_id)
    and public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','bursar','accountant']));
revoke insert,update,delete on public.notification_delivery_logs from anon,authenticated;
grant select on public.notification_delivery_logs to authenticated;

-- 6) Relational timetable model. Existing JSONB timetable data is retained.
create table if not exists public.school_timetable_rooms (
  id text not null,
  school_id uuid not null references public.schools(id) on delete cascade,
  name text not null,
  capacity integer not null default 0 check(capacity>=0),
  room_type text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(school_id,id)
);

create table if not exists public.school_teacher_availability (
  id bigint generated always as identity primary key,
  school_id uuid not null references public.schools(id) on delete cascade,
  teacher_id text not null,
  day_name text not null,
  period_slot text not null,
  available boolean not null default true,
  unique(school_id,teacher_id,day_name,period_slot)
);

create table if not exists public.school_teacher_workload_limits (
  school_id uuid not null references public.schools(id) on delete cascade,
  teacher_id text not null,
  max_weekly_periods integer not null default 0 check(max_weekly_periods>=0),
  max_consecutive_periods integer not null default 0 check(max_consecutive_periods>=0),
  primary key(school_id,teacher_id)
);

create table if not exists public.school_timetable_requirements (
  id text not null,
  school_id uuid not null references public.schools(id) on delete cascade,
  academic_year text not null,
  term text not null,
  class_name text not null,
  subject text not null,
  teacher_ids text[] not null default '{}',
  weekly_lessons integer not null default 1 check(weekly_lessons between 0 and 20),
  duration_periods integer not null default 1 check(duration_periods between 1 and 6),
  learner_ids text[] not null default '{}',
  room_required boolean not null default false,
  preferred_room text,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key(school_id,id)
);
alter table public.school_timetable_requirements add column if not exists preferred_room text;

create table if not exists public.school_timetable_lessons (
  id text not null,
  school_id uuid not null references public.schools(id) on delete cascade,
  academic_year text not null,
  term text not null,
  class_name text not null,
  subject text not null,
  teacher_id text,
  teacher_name text,
  day_name text not null,
  period_slot text not null,
  room_name text,
  room_required boolean not null default false,
  teaching_group_id text,
  learner_ids text[] not null default '{}',
  is_locked boolean not null default false,
  block_id text,
  block_position integer,
  source text not null default 'jengaedu-app',
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key(school_id,id)
);
alter table public.school_timetable_lessons add column if not exists room_required boolean not null default false;
create index if not exists school_timetable_lessons_period_idx
  on public.school_timetable_lessons(school_id,academic_year,term,day_name,period_slot);
create index if not exists school_timetable_lessons_class_idx
  on public.school_timetable_lessons(school_id,academic_year,term,class_name);
create index if not exists school_timetable_teacher_slot_idx
  on public.school_timetable_lessons(school_id,academic_year,term,day_name,period_slot,teacher_id);
create index if not exists school_timetable_room_slot_idx
  on public.school_timetable_lessons(school_id,academic_year,term,day_name,period_slot,room_name);

-- 6) Enable RLS and add strict school-scoped policies.
DO $$
DECLARE t text; p record;
BEGIN
  FOREACH t IN ARRAY ARRAY['school_timetable_rooms','school_teacher_availability','school_teacher_workload_limits','school_timetable_requirements','school_timetable_lessons'] LOOP
    EXECUTE format('alter table public.%I enable row level security',t);
    FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=t LOOP
      EXECUTE format('drop policy if exists %I on public.%I',p.policyname,t);
    END LOOP;
  END LOOP;
END $$;

-- School administrators may see the staff roster in their own workspace.
drop policy if exists school_admins_view_school_members on public.school_memberships;
create policy school_admins_view_school_members on public.school_memberships
  for select to authenticated using(public.has_school_role(school_id,array['school_admin']));

create policy timetable_rooms_read on public.school_timetable_rooms for select to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']));
create policy timetable_rooms_write on public.school_timetable_rooms for all to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));
create policy teacher_availability_read on public.school_teacher_availability for select to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']));
create policy teacher_availability_write on public.school_teacher_availability for all to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));
create policy teacher_workload_limits_read on public.school_teacher_workload_limits for select to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']));
create policy teacher_workload_limits_write on public.school_teacher_workload_limits for all to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));
create policy timetable_requirements_read on public.school_timetable_requirements for select to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']));
create policy timetable_requirements_write on public.school_timetable_requirements for all to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));
create policy timetable_lessons_read on public.school_timetable_lessons for select to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher','teacher','bursar','accountant','librarian','support_staff','staff']));
create policy timetable_lessons_write on public.school_timetable_lessons for all to authenticated
  using(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']))
  with check(public.has_school_role(school_id,array['school_admin','headteacher','deputy_headteacher']));

revoke insert,update,delete on public.school_timetable_rooms,public.school_teacher_availability,public.school_teacher_workload_limits,public.school_timetable_requirements,public.school_timetable_lessons from anon,authenticated;
grant select on public.school_timetable_rooms,public.school_teacher_availability,public.school_teacher_workload_limits,public.school_timetable_requirements,public.school_timetable_lessons to authenticated;

-- 7) Authorized atomic replacement of one school's timetable period.
create or replace function public.sync_school_timetable(
  p_school_id uuid,p_academic_year text,p_term text,p_lessons jsonb
) returns integer
language plpgsql security definer
set search_path=public,auth,pg_temp as $$
declare v_count integer;
begin
  if auth.uid() is null or not public.has_school_role(p_school_id,array['school_admin','headteacher','deputy_headteacher']) then
    raise exception using errcode='42501',message='Timetable administrator permission required';
  end if;
  if p_lessons is null or jsonb_typeof(p_lessons)<>'array' then
    raise exception using errcode='22023',message='Timetable lessons must be a JSON array';
  end if;
  if exists(select 1 from jsonb_array_elements(p_lessons) x where
    nullif(x->>'id','') is null or nullif(x->>'class','') is null or nullif(x->>'subject','') is null
    or nullif(x->>'day','') is null or nullif(x->>'time','') is null) then
    raise exception using errcode='22023',message='A timetable lesson is missing a required field';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_lessons) x
    where nullif(x->>'teacherId','') is not null
    group by x->>'day',x->>'time',x->>'teacherId' having count(*)>1
  ) then raise exception using errcode='23505',message='Teacher double-booking in timetable payload'; end if;
  if exists(
    select 1 from jsonb_array_elements(p_lessons) x
    where nullif(x->>'room','') is not null
    group by x->>'day',x->>'time',x->>'room' having count(*)>1
  ) then raise exception using errcode='23505',message='Room double-booking in timetable payload'; end if;
  if exists(
    select 1 from jsonb_array_elements(p_lessons) x
    where coalesce(x->>'groupId','')=''
    group by x->>'day',x->>'time',x->>'class' having count(*)>1
  ) then raise exception using errcode='23505',message='Whole-class double-booking in timetable payload'; end if;
  if exists(
    select 1
    from jsonb_array_elements(p_lessons) with ordinality a(value,ord)
    join jsonb_array_elements(p_lessons) with ordinality b(value,ord) on a.ord<b.ord
    where a.value->>'day'=b.value->>'day' and a.value->>'time'=b.value->>'time'
      and exists(
        select 1 from jsonb_array_elements_text(coalesce(a.value->'learnerIds','[]'::jsonb)) la(id)
        join jsonb_array_elements_text(coalesce(b.value->'learnerIds','[]'::jsonb)) lb(id) on la.id=lb.id
      )
  ) then raise exception using errcode='23505',message='Learner double-booking in timetable payload'; end if;
  delete from public.school_timetable_lessons
   where school_id=p_school_id and academic_year=p_academic_year and term=p_term;
  insert into public.school_timetable_lessons(
    id,school_id,academic_year,term,class_name,subject,teacher_id,teacher_name,day_name,period_slot,
    room_name,room_required,teaching_group_id,learner_ids,is_locked,block_id,block_position,source,created_by,updated_at
  )
  select x->>'id',p_school_id,p_academic_year,p_term,x->>'class',x->>'subject',
    nullif(x->>'teacherId',''),nullif(x->>'teacher',''),x->>'day',x->>'time',nullif(x->>'room',''),
    coalesce((x->>'roomRequired')::boolean,false),nullif(x->>'groupId',''),coalesce(array(select jsonb_array_elements_text(coalesce(x->'learnerIds','[]'::jsonb))),'{}'),
    coalesce((x->>'locked')::boolean,false),nullif(x->>'blockId',''),nullif(x->>'blockPosition','')::integer,
    coalesce(x->>'solver','jengaedu-app'),auth.uid(),clock_timestamp()
  from jsonb_array_elements(p_lessons) x;
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke all on function public.sync_school_timetable(uuid,text,text,jsonb) from public,anon;
grant execute on function public.sync_school_timetable(uuid,text,text,jsonb) to authenticated;

-- 8) Authorized replacement of timetable resources, availability and weekly requirements.
create or replace function public.sync_school_timetable_configuration(
  p_school_id uuid,p_rooms jsonb,p_availability jsonb,p_teacher_limits jsonb,p_requirements jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp as $$
declare v_rooms integer:=0; v_availability integer:=0; v_limits integer:=0; v_requirements integer:=0;
begin
  if auth.uid() is null or not public.has_school_role(p_school_id,array['school_admin','headteacher','deputy_headteacher']) then
    raise exception using errcode='42501',message='Timetable administrator permission required';
  end if;
  if jsonb_typeof(coalesce(p_rooms,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_requirements,'[]'::jsonb))<>'array'
     or jsonb_typeof(coalesce(p_availability,'{}'::jsonb))<>'object' or jsonb_typeof(coalesce(p_teacher_limits,'{}'::jsonb))<>'object' then
    raise exception using errcode='22023',message='Invalid timetable configuration payload';
  end if;
  delete from public.school_timetable_rooms where school_id=p_school_id;
  insert into public.school_timetable_rooms(id,school_id,name,capacity,room_type,active)
  select coalesce(nullif(x->>'id',''),'room-'||md5(x::text)),p_school_id,x->>'name',greatest(0,coalesce((x->>'capacity')::integer,0)),nullif(x->>'type',''),coalesce((x->>'active')::boolean,true)
  from jsonb_array_elements(coalesce(p_rooms,'[]'::jsonb)) x where nullif(x->>'name','') is not null;
  get diagnostics v_rooms=row_count;

  delete from public.school_teacher_availability where school_id=p_school_id;
  insert into public.school_teacher_availability(school_id,teacher_id,day_name,period_slot,available)
  select p_school_id,a.key,split_part(slot.value,'|',1),substring(slot.value from position('|' in slot.value)+1),true
  from jsonb_each(coalesce(p_availability,'{}'::jsonb)) a
  cross join lateral jsonb_array_elements_text(case when jsonb_typeof(a.value)='array' then a.value else '[]'::jsonb end) slot(value)
  where position('|' in slot.value)>0
  union all
  select p_school_id,a.key,d.key,slot.value,true
  from jsonb_each(coalesce(p_availability,'{}'::jsonb)) a
  cross join lateral jsonb_each(case when jsonb_typeof(a.value)='object' then a.value else '{}'::jsonb end) d
  cross join lateral jsonb_array_elements_text(case when jsonb_typeof(d.value)='array' then d.value else '[]'::jsonb end) slot(value);
  get diagnostics v_availability=row_count;

  delete from public.school_teacher_workload_limits where school_id=p_school_id;
  insert into public.school_teacher_workload_limits(school_id,teacher_id,max_weekly_periods,max_consecutive_periods)
  select p_school_id,a.key,greatest(0,coalesce((a.value->>'max_weekly_periods')::integer,0)),greatest(0,coalesce((a.value->>'max_consecutive_periods')::integer,0))
  from jsonb_each(coalesce(p_teacher_limits,'{}'::jsonb)) a;
  get diagnostics v_limits=row_count;

  delete from public.school_timetable_requirements where school_id=p_school_id;
  insert into public.school_timetable_requirements(id,school_id,academic_year,term,class_name,subject,teacher_ids,weekly_lessons,duration_periods,learner_ids,room_required,preferred_room,active)
  select coalesce(nullif(x->>'id',''),'req-'||md5(x::text)),p_school_id,coalesce(x->>'year',''),coalesce(x->>'term',''),
    x->>'class',x->>'subject',coalesce(array(select jsonb_array_elements_text(coalesce(x->'teacher_ids','[]'::jsonb))),'{}'),
    greatest(0,least(20,coalesce((x->>'weekly_lessons')::integer,1))),greatest(1,least(6,coalesce((x->>'duration_periods')::integer,1))),
    coalesce(array(select jsonb_array_elements_text(coalesce(x->'learner_ids','[]'::jsonb))),'{}'),coalesce((x->>'room_required')::boolean,false),nullif(x->>'preferred_room',''),coalesce((x->>'active')::boolean,true)
  from jsonb_array_elements(coalesce(p_requirements,'[]'::jsonb)) x
  where nullif(x->>'class','') is not null and nullif(x->>'subject','') is not null;
  get diagnostics v_requirements=row_count;
  return jsonb_build_object('rooms',v_rooms,'availability',v_availability,'teacher_limits',v_limits,'requirements',v_requirements);
end $$;
revoke all on function public.sync_school_timetable_configuration(uuid,jsonb,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.sync_school_timetable_configuration(uuid,jsonb,jsonb,jsonb,jsonb) to authenticated;

-- 9) Idempotent backfill from UUID-keyed school_state_shared rows. Legacy rows
-- with non-UUID ids (for example 'JENGAEDU') are deliberately not guessed.
insert into public.school_timetable_lessons(
  id,school_id,academic_year,term,class_name,subject,teacher_id,teacher_name,day_name,period_slot,
  room_name,room_required,teaching_group_id,learner_ids,is_locked,block_id,block_position,source,updated_at
)
select coalesce(nullif(x->>'id',''),'legacy-'||md5(x::text)),s.id::uuid,
  coalesce(x->>'year',''),coalesce(x->>'term',''),coalesce(x->>'class',''),coalesce(x->>'subject',''),
  nullif(x->>'teacherId',''),nullif(x->>'teacher',''),coalesce(x->>'day',''),coalesce(x->>'time',''),
  nullif(x->>'room',''),coalesce((x->>'roomRequired')::boolean,false),nullif(x->>'groupId',''),
  coalesce(array(select jsonb_array_elements_text(coalesce(x->'learnerIds','[]'::jsonb))),'{}'),
  coalesce((x->>'locked')::boolean,false),nullif(x->>'blockId',''),nullif(x->>'blockPosition','')::integer,
  'jsonb-backfill',now()
from public.school_state_shared s
join public.schools sc on sc.id::text=s.id
cross join lateral jsonb_array_elements(coalesce(s.data->'timetable','[]'::jsonb)) x
where s.id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and nullif(x->>'class','') is not null and nullif(x->>'day','') is not null and nullif(x->>'time','') is not null
on conflict(school_id,id) do nothing;

commit;

-- Post-migration verification (run manually):
-- select school_id,count(*) from public.school_timetable_lessons group by school_id;
-- select policyname,tablename from pg_policies where schemaname='public' and tablename in
-- ('school_state_shared','school_timetable_lessons','school_timetable_rooms','school_teacher_availability');
-- Test with two Auth users in two different active schools before enabling public signup.
