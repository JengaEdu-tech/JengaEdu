-- JengaEdu referral rewards: KSh 1,500 after the first confirmed term payment only.
begin;
create table if not exists public.referral_partners(
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null unique references auth.users(id) on delete cascade,
 referral_code text not null unique,
 mpesa_phone text not null,
 created_at timestamptz not null default now()
);
create table if not exists public.school_referrals(
 id uuid primary key default gen_random_uuid(),
 referred_user_id uuid not null unique references auth.users(id) on delete cascade,
 school_id uuid unique references public.schools(id) on delete cascade,
 partner_id uuid not null references public.referral_partners(id) on delete restrict,
 referral_code text not null,
 status text not null default 'registered' check(status in('registered','qualified','rejected')),
 created_at timestamptz not null default now()
);
create table if not exists public.referral_rewards(
 id uuid primary key default gen_random_uuid(),
 school_id uuid not null unique references public.schools(id) on delete cascade,
 referral_id uuid not null unique references public.school_referrals(id) on delete restrict,
 invoice_id uuid not null unique references public.subscription_invoices(id) on delete restrict,
 partner_id uuid not null references public.referral_partners(id) on delete restrict,
 reward_amount numeric(12,2) not null default 1500 check(reward_amount=1500),
 currency char(3) not null default 'KES' check(currency='KES'),
 status text not null default 'pending' check(status in('pending','processing','paid','failed','held')),
 payout_phone text not null,
 mpesa_transaction_id text,
 payout_response jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 paid_at timestamptz
);
create index if not exists referral_rewards_status_idx on public.referral_rewards(status,created_at);
alter table public.referral_partners enable row level security;
alter table public.school_referrals enable row level security;
alter table public.referral_rewards enable row level security;
drop policy if exists partner_own_profile_read on public.referral_partners;
create policy partner_own_profile_read on public.referral_partners for select to authenticated using(user_id=auth.uid());
drop policy if exists partner_own_referrals_read on public.school_referrals;
create policy partner_own_referrals_read on public.school_referrals for select to authenticated using(partner_id in(select id from public.referral_partners where user_id=auth.uid()));
drop policy if exists partner_own_rewards_read on public.referral_rewards;
create policy partner_own_rewards_read on public.referral_rewards for select to authenticated using(partner_id in(select id from public.referral_partners where user_id=auth.uid()));
grant select on public.referral_partners,public.school_referrals,public.referral_rewards to authenticated;

create or replace function public.create_my_referral_profile(p_mpesa_phone text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare p text; c text; old_code text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 p:=regexp_replace(coalesce(p_mpesa_phone,''),'[^0-9]','','g');
 if p like '0%' and length(p)=10 then p:='254'||substr(p,2); end if;
 if p like '7%' and length(p)=9 then p:='254'||p; end if;
 if p like '1%' and length(p)=9 then p:='254'||p; end if;
 if p !~ '^254[17][0-9]{8}$' then raise exception 'Enter a valid Kenyan M-Pesa number'; end if;
 select referral_code into old_code from public.referral_partners where user_id=auth.uid();
 if old_code is not null then update public.referral_partners set mpesa_phone='+'||p where user_id=auth.uid(); return old_code; end if;
 c:='JENGA-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.referral_partners(user_id,referral_code,mpesa_phone) values(auth.uid(),c,'+'||p);
 return c;
end $$;
revoke all on function public.create_my_referral_profile(text) from public,anon;
grant execute on function public.create_my_referral_profile(text) to authenticated;

-- Capture the optional signup referral code when the school-admin membership is created.
create or replace function public.capture_jenga_referral_on_school_membership()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare c text; partner uuid;
begin
 select upper(trim(coalesce(raw_user_meta_data->>'referral_code',''))) into c from auth.users where id=new.user_id;
 if coalesce(c,'')='' then return new; end if;
 select id into partner from public.referral_partners where referral_code=c;
 if partner is not null then
  insert into public.school_referrals(referred_user_id,school_id,partner_id,referral_code)
  values(new.user_id,new.school_id,partner,c) on conflict do nothing;
 end if;
 return new;
end $$;
drop trigger if exists capture_jenga_referral_on_school_membership on public.school_memberships;
create trigger capture_jenga_referral_on_school_membership after insert on public.school_memberships
for each row execute function public.capture_jenga_referral_on_school_membership();

-- One reward per referred school, only when its first invoice is paid.
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
    values(new.school_id,r.id,new.id,p.id,1500,p.mpesa_phone) on conflict do nothing;
    update public.school_referrals set status='qualified' where id=r.id;
   end if;
  end if;
 end if;
 return new;
end $$;
drop trigger if exists queue_first_term_referral_reward on public.subscription_invoices;
create trigger queue_first_term_referral_reward after update of status on public.subscription_invoices
for each row execute function public.queue_first_term_referral_reward();
commit;
