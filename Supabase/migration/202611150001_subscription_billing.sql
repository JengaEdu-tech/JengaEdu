-- JengaEdu commercial subscriptions: KES 1,000/school/month, 60-day trial.
-- Run AFTER multi-school-foundation.sql and multi-school-approval-migration.sql.
-- Back up production first. This migration is additive and preserves existing school data.

begin;

create table if not exists public.subscription_plans (
  id text primary key,
  name text not null,
  currency char(3) not null default 'KES' check (currency='KES'),
  monthly_amount numeric(12,2) not null check (monthly_amount >= 0),
  trial_days integer not null default 60 check (trial_days between 0 and 365),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.subscription_plans(id,name,currency,monthly_amount,trial_days)
values ('school-monthly','JengaEdu School Monthly','KES',1000,60)
on conflict (id) do update set name=excluded.name,currency=excluded.currency,
 monthly_amount=excluded.monthly_amount,trial_days=excluded.trial_days;

create table if not exists public.school_subscriptions (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null unique references public.schools(id) on delete cascade,
  plan_id text not null references public.subscription_plans(id),
  status text not null default 'pending_approval'
    check(status in ('pending_approval','trialing','active','past_due','suspended','cancelled')),
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  current_period_start timestamptz,
  current_period_end timestamptz,
  grace_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  activated_at timestamptz,
  suspended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(trial_ends_at is null or trial_started_at is null or trial_ends_at > trial_started_at),
  check(current_period_end is null or current_period_start is null or current_period_end > current_period_start)
);
create index if not exists school_subscriptions_status_idx on public.school_subscriptions(status,trial_ends_at,current_period_end);

create table if not exists public.subscription_invoices (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  subscription_id uuid not null references public.school_subscriptions(id) on delete cascade,
  invoice_number text not null unique,
  description text not null default 'JengaEdu monthly school subscription',
  currency char(3) not null default 'KES' check(currency='KES'),
  amount_due numeric(12,2) not null check(amount_due > 0),
  amount_paid numeric(12,2) not null default 0 check(amount_paid >= 0),
  period_start timestamptz not null,
  period_end timestamptz not null,
  status text not null default 'unpaid' check(status in ('unpaid','pending','paid','void','failed')),
  due_at timestamptz not null default now(),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  check(period_end > period_start),
  check(amount_paid <= amount_due)
);
create index if not exists subscription_invoices_school_idx on public.subscription_invoices(school_id,created_at desc);

create table if not exists public.subscription_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  invoice_id uuid not null references public.subscription_invoices(id) on delete restrict,
  provider text not null default 'safaricom_daraja' check(provider='safaricom_daraja'),
  phone_number text not null,
  amount numeric(12,2) not null check(amount > 0),
  status text not null default 'initiated' check(status in ('initiated','pending','succeeded','failed','cancelled','unknown')),
  merchant_request_id text,
  checkout_request_id text unique,
  mpesa_receipt_number text unique,
  result_code text,
  result_description text,
  provider_response jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists subscription_payment_attempts_school_idx on public.subscription_payment_attempts(school_id,created_at desc);
create unique index if not exists subscription_one_open_attempt_per_invoice_idx
 on public.subscription_payment_attempts(invoice_id) where status in ('initiated','pending');

create table if not exists public.subscription_payment_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'safaricom_daraja',
  event_key text not null unique,
  payment_attempt_id uuid references public.subscription_payment_attempts(id) on delete set null,
  event_type text not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_result text,
  safe_payload jsonb not null default '{}'::jsonb
);

-- Every school has a subscription row. Pending applications do not start their trial.
create or replace function public.ensure_school_subscription()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_plan public.subscription_plans%rowtype; v_start timestamptz;
begin
  select * into v_plan from public.subscription_plans where id='school-monthly' and is_active;
  if not found then raise exception 'JengaEdu monthly plan is not configured'; end if;
  if tg_op='INSERT' then
    if new.status='active' then
      v_start := now();
      insert into public.school_subscriptions(school_id,plan_id,status,trial_started_at,trial_ends_at)
      values(new.id,v_plan.id,'trialing',v_start,v_start + make_interval(days=>v_plan.trial_days))
      on conflict(school_id) do nothing;
    else
      insert into public.school_subscriptions(school_id,plan_id,status)
      values(new.id,v_plan.id,'pending_approval') on conflict(school_id) do nothing;
    end if;
  elsif old.status is distinct from new.status and new.status='active' then
    v_start := now();
    insert into public.school_subscriptions(school_id,plan_id,status,trial_started_at,trial_ends_at)
    values(new.id,v_plan.id,'trialing',v_start,v_start + make_interval(days=>v_plan.trial_days))
    on conflict(school_id) do update set
      status=case when public.school_subscriptions.status='pending_approval' then 'trialing' else public.school_subscriptions.status end,
      trial_started_at=coalesce(public.school_subscriptions.trial_started_at,excluded.trial_started_at),
      trial_ends_at=coalesce(public.school_subscriptions.trial_ends_at,excluded.trial_ends_at),
      updated_at=now();
  elsif new.status in ('suspended','rejected') then
    update public.school_subscriptions set status='suspended',suspended_at=coalesce(suspended_at,now()),updated_at=now()
    where school_id=new.id and status not in ('cancelled','suspended');
  end if;
  return new;
end $$;
drop trigger if exists schools_subscription_lifecycle on public.schools;
create trigger schools_subscription_lifecycle after insert or update of status on public.schools
for each row execute function public.ensure_school_subscription();

-- Existing active schools receive a 60-day introductory trial from migration deployment.
insert into public.school_subscriptions(school_id,plan_id,status,trial_started_at,trial_ends_at)
select s.id,'school-monthly','trialing',now(),now()+interval '60 days'
from public.schools s where s.status='active'
on conflict(school_id) do nothing;
insert into public.school_subscriptions(school_id,plan_id,status)
select s.id,'school-monthly','pending_approval'
from public.schools s where s.status<>'active'
on conflict(school_id) do nothing;

-- Create the next monthly invoice for a school administrator/bursar.
create or replace function public.create_subscription_invoice(p_school_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_sub public.school_subscriptions%rowtype; v_plan public.subscription_plans%rowtype;
 v_start timestamptz; v_end timestamptz; v_invoice uuid; v_number text;
begin
 if auth.uid() is null or not exists(
   select 1 from public.school_memberships m where m.school_id=p_school_id and m.user_id=auth.uid() and m.role in ('school_admin','bursar')
 ) then raise exception 'School administrator or bursar access required'; end if;
 select * into v_sub from public.school_subscriptions where school_id=p_school_id for update;
 if not found or v_sub.status in ('pending_approval','cancelled') then raise exception 'Subscription is not available for payment'; end if;
 select * into v_plan from public.subscription_plans where id=v_sub.plan_id and is_active;
 if not found then raise exception 'Subscription plan unavailable'; end if;
 -- Reuse an existing unpaid/pending invoice rather than creating duplicate charges.
 select id into v_invoice from public.subscription_invoices where school_id=p_school_id and status in ('unpaid','pending') order by created_at desc limit 1;
 if v_invoice is not null then return v_invoice; end if;
 v_start := greatest(coalesce(v_sub.current_period_end,'-infinity'::timestamptz),coalesce(v_sub.trial_ends_at,'-infinity'::timestamptz),now());
 v_end := v_start + interval '1 month';
 v_number := 'JEG-'||to_char(now(),'YYYYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.subscription_invoices(school_id,subscription_id,invoice_number,amount_due,period_start,period_end,status)
 values(p_school_id,v_sub.id,v_number,v_plan.monthly_amount,v_start,v_end,'unpaid') returning id into v_invoice;
 return v_invoice;
end $$;
revoke all on function public.create_subscription_invoice(uuid) from public,anon;
grant execute on function public.create_subscription_invoice(uuid) to authenticated;

-- This function is only for trusted server-side payment callbacks/reconciliation.
create or replace function public.confirm_subscription_payment(
 p_checkout_request_id text, p_result_code text, p_result_description text,
 p_mpesa_receipt text, p_paid_amount numeric, p_paid_phone text, p_callback jsonb default '{}'::jsonb
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare v_attempt public.subscription_payment_attempts%rowtype; v_invoice public.subscription_invoices%rowtype;
 v_sub public.school_subscriptions%rowtype; v_event text;
begin
 if coalesce(auth.role(),'') <> 'service_role' then raise exception 'Service role required'; end if;
 if p_checkout_request_id is null or length(trim(p_checkout_request_id))=0 then raise exception 'Checkout request ID required'; end if;
 v_event := 'stk:'||p_checkout_request_id;
 select * into v_attempt from public.subscription_payment_attempts where checkout_request_id=p_checkout_request_id for update;
 if not found then return false; end if;
 insert into public.subscription_payment_events(event_key,event_type,payment_attempt_id,safe_payload)
 values(v_event,'stk_callback',v_attempt.id,jsonb_build_object('result_code',p_result_code,'receipt',p_mpesa_receipt))
 on conflict(event_key) do nothing;
 if not found then return true; end if;
 if p_result_code <> '0' then
   update public.subscription_payment_attempts set status='failed',result_code=p_result_code,result_description=p_result_description,
     provider_response=coalesce(p_callback,'{}'::jsonb),updated_at=now(),completed_at=now() where id=v_attempt.id;
   update public.subscription_invoices set status='failed' where id=v_attempt.invoice_id and status<>'paid';
   update public.subscription_payment_events set payment_attempt_id=v_attempt.id,processing_result='payment_failed',processed_at=now() where event_key=v_event;
   return true;
 end if;
 if p_mpesa_receipt is null or p_paid_amount is null or p_paid_amount<>v_attempt.amount
    or p_paid_amount<> (select amount_due from public.subscription_invoices where id=v_attempt.invoice_id)
    or (p_paid_phone is not null and regexp_replace(p_paid_phone,'[^0-9]','','g')<>regexp_replace(v_attempt.phone_number,'[^0-9]','','g')) then
   update public.subscription_payment_attempts set status='unknown',result_code=p_result_code,result_description='Callback details require reconciliation',
    provider_response=coalesce(p_callback,'{}'::jsonb),updated_at=now() where id=v_attempt.id;
   update public.subscription_payment_events set payment_attempt_id=v_attempt.id,processing_result='amount_or_phone_mismatch',processed_at=now() where event_key=v_event;
   return false;
 end if;
 update public.subscription_payment_attempts set status='succeeded',result_code=p_result_code,result_description=p_result_description,
  mpesa_receipt_number=p_mpesa_receipt,provider_response=coalesce(p_callback,'{}'::jsonb),updated_at=now(),completed_at=now() where id=v_attempt.id;
 select * into v_invoice from public.subscription_invoices where id=v_attempt.invoice_id for update;
 update public.subscription_invoices set status='paid',amount_paid=v_invoice.amount_due,paid_at=now() where id=v_invoice.id;
 select * into v_sub from public.school_subscriptions where id=v_invoice.subscription_id for update;
 update public.school_subscriptions set status='active',
   current_period_start=v_invoice.period_start,current_period_end=v_invoice.period_end,
   grace_ends_at=null,activated_at=coalesce(activated_at,now()),suspended_at=null,updated_at=now()
 where id=v_sub.id;
 update public.subscription_payment_events set payment_attempt_id=v_attempt.id,processing_result='payment_confirmed',processed_at=now() where event_key=v_event;
 return true;
end $$;
revoke all on function public.confirm_subscription_payment(text,text,text,text,numeric,text,jsonb) from public,anon,authenticated;
grant execute on function public.confirm_subscription_payment(text,text,text,text,numeric,text,jsonb) to service_role;

-- Daily lifecycle job: 7-day grace after expiry, then suspend app access (not school records).
create or replace function public.expire_school_subscriptions()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare v_count integer;
begin
 update public.school_subscriptions set status='past_due',grace_ends_at=coalesce(grace_ends_at,trial_ends_at+interval '7 days'),updated_at=now()
 where status='trialing' and trial_ends_at<=now();
 update public.school_subscriptions set status='past_due',grace_ends_at=coalesce(grace_ends_at,current_period_end+interval '7 days'),updated_at=now()
 where status='active' and current_period_end<=now();
 update public.school_subscriptions set status='suspended',suspended_at=coalesce(suspended_at,now()),updated_at=now()
 where status='past_due' and grace_ends_at<=now();
 get diagnostics v_count = row_count;
 return v_count;
end $$;
revoke all on function public.expire_school_subscriptions() from public,anon,authenticated;
grant execute on function public.expire_school_subscriptions() to service_role;

-- Subscription visibility: school admins/bursars can see their own subscription and invoices.
do $$ declare t text; begin
 foreach t in array array['school_subscriptions','subscription_invoices','subscription_payment_attempts'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists "School members view own %I" on public.%I',t,t);
 end loop;
end $$;
create policy "School members view own school_subscriptions" on public.school_subscriptions for select to authenticated
 using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id=school_subscriptions.school_id and m.user_id=auth.uid()));
create policy "School members view own subscription_invoices" on public.subscription_invoices for select to authenticated
 using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id=subscription_invoices.school_id and m.user_id=auth.uid() and m.role in ('school_admin','bursar')));
create policy "School members view own subscription_payment_attempts" on public.subscription_payment_attempts for select to authenticated
 using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id=subscription_payment_attempts.school_id and m.user_id=auth.uid() and m.role in ('school_admin','bursar')));
grant select on public.school_subscriptions,public.subscription_invoices,public.subscription_payment_attempts to authenticated;
alter table public.subscription_payment_events enable row level security;
revoke all on public.subscription_payment_events from public,anon,authenticated;
grant all on public.subscription_payment_events to service_role;
grant select on public.subscription_plans to anon,authenticated;

-- A school must have an active/trialing subscription (or be within the 7-day grace period)
-- to use normal school operations. Billing pages remain accessible to members while overdue.
create or replace function public.is_active_school_member(target_school uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(
  select 1 from public.school_memberships m join public.schools s on s.id=m.school_id
  join public.school_subscriptions sub on sub.school_id=s.id
  where m.school_id=target_school and m.user_id=auth.uid() and s.status='active'
    and (
      (sub.status='trialing' and sub.trial_ends_at + interval '7 days' > now())
      or (sub.status='active' and sub.current_period_end + interval '7 days' > now())
      or (sub.status='past_due' and sub.grace_ends_at>now())
    )
 );
$$;
revoke all on function public.is_active_school_member(uuid) from public,anon;
grant execute on function public.is_active_school_member(uuid) to authenticated;

-- Apply the subscription gate to the existing shared school-state JSONB record.
-- Platform owner access remains available for support and recovery.
drop policy if exists "active members read own school state" on public.school_state_shared;
create policy "active members read own school state" on public.school_state_shared
 for select to authenticated using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id::text=school_state_shared.id and m.user_id=auth.uid() and public.is_active_school_member(m.school_id)));
drop policy if exists "active admins create own school state" on public.school_state_shared;
create policy "active admins create own school state" on public.school_state_shared
 for insert to authenticated with check(public.is_platform_admin() or (
  exists(select 1 from public.school_memberships m where m.school_id::text=school_state_shared.id and m.user_id=auth.uid() and m.role='school_admin' and public.is_active_school_member(m.school_id))
 ));
drop policy if exists "active members update own school state" on public.school_state_shared;
create policy "active members update own school state" on public.school_state_shared
 for update to authenticated using(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id::text=school_state_shared.id and m.user_id=auth.uid() and public.is_active_school_member(m.school_id)))
 with check(public.is_platform_admin() or exists(select 1 from public.school_memberships m where m.school_id::text=school_state_shared.id and m.user_id=auth.uid() and public.is_active_school_member(m.school_id)));

commit;

-- Enable pg_cron in Supabase Dashboard, then schedule:
-- select cron.schedule('jengaedu-expire-subscriptions','15 0 * * *', $$select public.expire_school_subscriptions();$$);
-- Keep Daraja credentials in Supabase Edge Function secrets, never in browser code.
