-- JengaEdu commercial platform foundations
-- ADDITIVE migration. Back up the project before applying. Does not rewrite legacy school_state_shared.
-- Requires schools, school_memberships and is_school_member() from the existing multi-school migrations.

begin;

-- Do not grant access to a suspended school merely because an old membership remains.
create or replace function public.is_active_school_member(target_school uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.school_memberships m
    join public.schools s on s.id=m.school_id
    where m.school_id=target_school and m.user_id=auth.uid() and s.status='active'
  );
$$;
revoke all on function public.is_active_school_member(uuid) from public, anon;
grant execute on function public.is_active_school_member(uuid) to authenticated;

-- ---------- Public cross-school learning library ----------
create table if not exists public.learning_resources (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  school_name text not null,
  uploaded_by uuid not null references auth.users(id) on delete restrict,
  title text not null check (length(trim(title)) between 3 and 180),
  description text not null default '',
  resource_type text not null check (resource_type in ('video','exam','notes','revision','assignment','other')),
  subject text not null default '',
  grade text not null default '',
  curriculum text not null default 'Kenya CBC',
  academic_year integer,
  storage_path text not null unique,
  original_filename text not null,
  mime_type text not null,
  file_size_bytes bigint not null check(file_size_bytes > 0),
  is_published boolean not null default false,
  moderation_status text not null default 'approved' check(moderation_status in ('pending','approved','rejected')),
  download_count bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists learning_resources_public_idx
  on public.learning_resources(resource_type, grade, subject, created_at desc)
  where is_published and moderation_status='approved';
create index if not exists learning_resources_school_idx on public.learning_resources(school_id, created_at desc);
alter table public.learning_resources enable row level security;

drop policy if exists "Public can discover published learning resources" on public.learning_resources;
create policy "Public can discover published learning resources"
 on public.learning_resources for select to anon, authenticated
 using (is_published and moderation_status='approved' and exists (
   select 1 from public.schools s where s.id=school_id and s.status='active'
 ));
drop policy if exists "School staff can view own learning resources" on public.learning_resources;
create policy "School staff can view own learning resources"
 on public.learning_resources for select to authenticated
 using (public.is_active_school_member(school_id));
drop policy if exists "School staff can upload learning resources" on public.learning_resources;
create policy "School staff can upload learning resources"
 on public.learning_resources for insert to authenticated
 with check (public.is_active_school_member(school_id) and uploaded_by=auth.uid());
drop policy if exists "Owners and school admins can edit own resources" on public.learning_resources;
create policy "Owners and school admins can edit own resources"
 on public.learning_resources for update to authenticated
 using (uploaded_by=auth.uid() or exists(select 1 from public.school_memberships m where m.school_id=learning_resources.school_id and m.user_id=auth.uid() and m.role='school_admin'))
 with check (public.is_active_school_member(school_id));
drop policy if exists "Owners and school admins can delete own resources" on public.learning_resources;
create policy "Owners and school admins can delete own resources"
 on public.learning_resources for delete to authenticated
 using (uploaded_by=auth.uid() or exists(select 1 from public.school_memberships m where m.school_id=learning_resources.school_id and m.user_id=auth.uid() and m.role='school_admin'));

grant select on public.learning_resources to anon, authenticated;
grant insert, update, delete on public.learning_resources to authenticated;

-- Private bucket: public visitors obtain short-lived signed URLs only for approved/published rows.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('jengaedu-learning','jengaedu-learning',false,524288000,
  array['video/mp4','video/webm','video/quicktime','application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','image/jpeg','image/png'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "School staff upload to own library folder" on storage.objects;
create policy "School staff upload to own library folder" on storage.objects
 for insert to authenticated with check (
   bucket_id='jengaedu-learning'
   and (storage.foldername(name))[1] in (select m.school_id::text from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and s.status='active')
 );
drop policy if exists "Public can read only published library files" on storage.objects;
create policy "Public can read only published library files" on storage.objects
 for select to anon, authenticated using (
   bucket_id='jengaedu-learning' and exists (
     select 1 from public.learning_resources r join public.schools s on s.id=r.school_id
     where r.storage_path=storage.objects.name and r.is_published and r.moderation_status='approved' and s.status='active'
   )
 );
drop policy if exists "Uploader or school admin can delete library files" on storage.objects;
create policy "Uploader or school admin can delete library files" on storage.objects
 for delete to authenticated using (
   bucket_id='jengaedu-learning' and (storage.foldername(name))[1] in
   (select m.school_id::text from public.school_memberships m where m.user_id=auth.uid() and m.role in ('school_admin','teacher'))
 );

-- ---------- Senior School timetable records ----------
create table if not exists public.school_timetables (
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null references public.schools(id) on delete cascade,
 academic_year integer not null,
 term text not null,
 section text not null check(section in ('ECDE','Primary','Junior','Senior')),
 grade text not null,
 stream text not null default '',
 day_of_week smallint not null check(day_of_week between 1 and 5),
 period_no smallint not null check(period_no between 1 and 16),
 starts_at time not null,
 ends_at time not null,
 subject text not null,
 teacher_id text,
 teacher_name text not null default '',
 room text not null default '',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(ends_at>starts_at),
 unique(school_id,academic_year,term,grade,stream,day_of_week,period_no)
);
create index if not exists school_timetables_teacher_idx on public.school_timetables(school_id,academic_year,term,teacher_id,day_of_week,period_no);
alter table public.school_timetables enable row level security;
drop policy if exists "Members manage own school timetables" on public.school_timetables;
create policy "Members manage own school timetables" on public.school_timetables
 for all to authenticated using(public.is_active_school_member(school_id)) with check(public.is_active_school_member(school_id));
grant select,insert,update,delete on public.school_timetables to authenticated;

-- ---------- Double-entry accounting ----------
create table if not exists public.finance_accounts (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 code text not null, name text not null, account_type text not null check(account_type in ('asset','liability','equity','income','expense')),
 parent_id uuid references public.finance_accounts(id), is_system boolean not null default false, is_active boolean not null default true,
 created_at timestamptz not null default now(), unique(school_id,code)
);
create table if not exists public.finance_periods (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 period_name text not null, starts_on date not null, ends_on date not null, status text not null default 'open' check(status in ('open','closed')),
 check(ends_on>=starts_on), unique(school_id,period_name)
);
create table if not exists public.finance_journals (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 period_id uuid references public.finance_periods(id), entry_date date not null, reference text not null, description text not null,
 source text not null default 'manual' check(source in ('manual','fee_receipt','expense','payroll','procurement','mpesa','opening_balance')),
 status text not null default 'draft' check(status in ('draft','posted','void')),
 created_by uuid references auth.users(id), posted_by uuid references auth.users(id), posted_at timestamptz,
 created_at timestamptz not null default now(), unique(school_id,reference)
);
create table if not exists public.finance_journal_lines (
 id uuid primary key default gen_random_uuid(), journal_id uuid not null references public.finance_journals(id) on delete cascade,
 school_id uuid not null references public.schools(id) on delete cascade,
 account_id uuid not null references public.finance_accounts(id), description text not null default '',
 debit numeric(14,2) not null default 0 check(debit>=0), credit numeric(14,2) not null default 0 check(credit>=0),
 check(not (debit>0 and credit>0)), check(debit>0 or credit>0)
);
create index if not exists finance_journals_date_idx on public.finance_journals(school_id,entry_date desc,status);
create index if not exists finance_lines_account_idx on public.finance_journal_lines(school_id,account_id);

-- Fee ledgers, payment channels, expenses, procurement and payroll registers.
create table if not exists public.fee_ledger_entries (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 learner_ref text not null, academic_year integer not null, term text not null,
 entry_type text not null check(entry_type in ('charge','payment','waiver','scholarship','refund','adjustment')),
 amount numeric(14,2) not null check(amount>0), payment_method text, receipt_reference text, mpesa_transaction_code text,
 entry_date date not null default current_date, notes text not null default '', journal_id uuid references public.finance_journals(id),
 recorded_by uuid references auth.users(id), created_at timestamptz not null default now(),
 unique(school_id,receipt_reference)
);
create table if not exists public.finance_expenses (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 expense_date date not null, category text not null, supplier text not null default '', description text not null,
 amount numeric(14,2) not null check(amount>0), payment_method text not null default 'Cash', reference text not null default '',
 status text not null default 'approved' check(status in ('draft','pending','approved','paid','rejected')),
 attachment_path text, journal_id uuid references public.finance_journals(id), created_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.procurement_orders (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 order_number text not null, supplier text not null, order_date date not null default current_date, expected_date date,
 status text not null default 'draft' check(status in ('draft','approved','part_received','received','cancelled')),
 total_amount numeric(14,2) not null default 0 check(total_amount>=0), notes text not null default '', created_by uuid references auth.users(id),
 unique(school_id,order_number)
);
create table if not exists public.payroll_runs (
 id uuid primary key default gen_random_uuid(), school_id uuid not null references public.schools(id) on delete cascade,
 period_label text not null, pay_date date, status text not null default 'draft' check(status in ('draft','approved','paid')),
 gross_total numeric(14,2) not null default 0, deductions_total numeric(14,2) not null default 0, net_total numeric(14,2) not null default 0,
 created_by uuid references auth.users(id), created_at timestamptz not null default now(), unique(school_id,period_label)
);

-- All financial tables are tenant-isolated. Membership controls visibility; application roles control actions.
do $$ declare t text; begin
 foreach t in array array['finance_accounts','finance_periods','finance_journals','finance_journal_lines','fee_ledger_entries','finance_expenses','procurement_orders','payroll_runs'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists "Members access own school %I" on public.%I',t,t);
  execute format('create policy "Members access own school %I" on public.%I for all to authenticated using(public.is_active_school_member(school_id)) with check(public.is_active_school_member(school_id))',t,t);
  execute format('grant select,insert,update,delete on public.%I to authenticated',t);
 end loop;
end $$;

-- Posted journals must balance. This trigger validates when a journal is posted/updated;
-- create journal in draft, insert all lines, then change status to posted.
create or replace function public.assert_jengaedu_journal_balanced()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_status text; v_debit numeric(14,2); v_credit numeric(14,2);
begin
 if tg_table_name='finance_journals' then
   v_id := coalesce(new.id, old.id);
 else
   v_id := coalesce(new.journal_id, old.journal_id);
 end if;
 select status into v_status from public.finance_journals where id=v_id;
 if v_status='posted' then
  select coalesce(sum(debit),0),coalesce(sum(credit),0) into v_debit,v_credit from public.finance_journal_lines where journal_id=v_id;
  if v_debit=0 or v_debit<>v_credit then raise exception 'A posted journal must have equal non-zero debit and credit totals'; end if;
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists finance_journal_balance_guard on public.finance_journals;
create constraint trigger finance_journal_balance_guard after insert or update of status on public.finance_journals
 deferrable initially deferred for each row execute function public.assert_jengaedu_journal_balanced();
drop trigger if exists finance_journal_line_balance_guard on public.finance_journal_lines;
create constraint trigger finance_journal_line_balance_guard after insert or update or delete on public.finance_journal_lines
 deferrable initially deferred for each row execute function public.assert_jengaedu_journal_balanced();

commit;

-- Post-migration smoke tests:
-- 1) Create two active test schools and users; confirm neither school can read the other's records.
-- 2) As anon, select learning_resources: only approved + published rows from active schools should appear.
-- 3) Confirm an anon user can create a signed URL only for an approved/published storage_path.
-- 4) Draft a journal, add equal debit/credit lines, post it; test that an unbalanced posting fails.
-- 5) Confirm a teacher cannot alter a resource uploaded by another school (unless school-admin role).
