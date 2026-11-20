-- JengaEdu termly subscription pricing upgrade
-- KSh 3,000 per school for a three-month academic term.
-- Apply after 202611150001_subscription_billing.sql. Additive: preserves school data,
-- existing invoices, payment attempts and M-Pesa receipts.

begin;

update public.subscription_plans
set name='JengaEdu School Termly',
    monthly_amount=3000,
    trial_days=60,
    is_active=true
where id='school-monthly';

-- The legacy plan ID and column name are retained to avoid breaking existing
-- foreign keys and deployed integrations. monthly_amount now stores the term price.
update public.subscription_invoices
set description='JengaEdu school subscription — academic term'
where description='JengaEdu monthly school subscription';

create or replace function public.create_subscription_invoice(p_school_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_sub public.school_subscriptions%rowtype;
 v_plan public.subscription_plans%rowtype;
 v_start timestamptz;
 v_end timestamptz;
 v_invoice uuid;
 v_number text;
begin
 if auth.uid() is null or not exists(
   select 1 from public.school_memberships m
   where m.school_id=p_school_id and m.user_id=auth.uid()
     and m.role in ('school_admin','bursar')
 ) then raise exception 'School administrator or bursar access required'; end if;

 select * into v_sub from public.school_subscriptions
 where school_id=p_school_id for update;
 if not found or v_sub.status in ('pending_approval','cancelled') then
   raise exception 'Subscription is not available for payment';
 end if;

 select * into v_plan from public.subscription_plans
 where id=v_sub.plan_id and is_active;
 if not found then raise exception 'Subscription plan unavailable'; end if;

 -- Reuse an existing unpaid/pending invoice rather than creating duplicate charges.
 select id into v_invoice from public.subscription_invoices
 where school_id=p_school_id and status in ('unpaid','pending')
 order by created_at desc limit 1;
 if v_invoice is not null then return v_invoice; end if;

 v_start := greatest(
   coalesce(v_sub.current_period_end,'-infinity'::timestamptz),
   coalesce(v_sub.trial_ends_at,'-infinity'::timestamptz),
   now()
 );
 v_end := v_start + interval '3 months';
 v_number := 'JEG-'||to_char(now(),'YYYYMMDD')||'-'||
   upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));

 insert into public.subscription_invoices(
   school_id,subscription_id,invoice_number,description,amount_due,
   period_start,period_end,status
 ) values(
   p_school_id,v_sub.id,v_number,
   'JengaEdu school subscription — academic term',
   v_plan.monthly_amount,v_start,v_end,'unpaid'
 ) returning id into v_invoice;
 return v_invoice;
end $$;

revoke all on function public.create_subscription_invoice(uuid) from public,anon;
grant execute on function public.create_subscription_invoice(uuid) to authenticated;

commit;
