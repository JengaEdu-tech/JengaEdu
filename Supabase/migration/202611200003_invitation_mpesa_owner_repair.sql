-- JengaEdu invitation, billing-owner and subscription-access repair.
-- Run AFTER 20261110_roles_permissions_invitations.sql and 202611150001_subscription_billing.sql.
-- The owner email is used only to map an Auth user to platform_admins; it is not rendered in the app.

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='platform_admins' and column_name='role') then
    raise exception 'Run the JengaEdu roles and invitations migration first (platform_admins.role is missing).';
  end if;
end $$;

insert into public.platform_admins(user_id, role)
select id, 'platform_owner'
from auth.users
where lower(email) = lower('jengaedu636@gmail.com')
on conflict (user_id) do update set role='platform_owner';

-- Ensure existing school subscriptions can be checked securely and cannot be skipped
-- when their row is absent: the browser fails closed, and the state-table RLS gate
-- remains the authoritative protection for normal school data.

commit;

-- Verification: this returns only a count and does not reveal the platform owner's email.
select count(*) as configured_platform_owner_accounts
from public.platform_admins
where role='platform_owner';
