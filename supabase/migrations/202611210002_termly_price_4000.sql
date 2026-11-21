-- JengaEdu commercial price update: KSh 4,000 per school per academic term.
-- Apply AFTER 202611200003_termly_billing.sql and after backing up the database.
-- Existing invoices and paid referral rewards are intentionally left unchanged.
begin;
update public.subscription_plans
set name='JengaEdu School Termly', monthly_amount=4000, trial_days=60, is_active=true
where id='school-monthly';

-- Future referral rewards remain 50% of the first paid term (KSh 2,000).
-- Keep historical reward amounts intact while allowing the new amount going forward.
alter table public.referral_rewards alter column reward_amount set default 2000;
alter table public.referral_rewards drop constraint if exists referral_rewards_reward_amount_check;
alter table public.referral_rewards add constraint referral_rewards_reward_amount_check check (reward_amount > 0);

create or replace function public.queue_first_term_referral_reward()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.school_referrals%rowtype; p public.referral_partners%rowtype;
begin
 if new.status='paid' and old.status is distinct from 'paid' then
  if exists(select 1 from public.subscription_invoices i where i.school_id=new.school_id and i.status='paid' and i.id<>new.id) then return new; end if;
  select * into r from public.school_referrals where school_id=new.school_id and status='registered' for update;
  if found then
   select * into p from public.referral_partners where id=r.partner_id;
   if found then
    insert into public.referral_rewards(school_id,referral_id,invoice_id,partner_id,reward_amount,payout_phone)
    values(new.school_id,r.id,new.id,p.id,2000,p.mpesa_phone) on conflict do nothing;
    update public.school_referrals set status='qualified' where id=r.id;
   end if;
  end if;
 end if;
 return new;
end $$;
commit;
