JengaEdu subscriptions, M-Pesa payments and school activation

Commercial policy


Price: KES 1,000 per school per month.

Trial: 60 calendar days, starting only when the platform owner approves the school (schools.status changes to active).

Billing unit: school, not user, teacher, learner or device.

Grace period: 7 days after trial or paid period expiry.

Payment channel in this implementation: Safaricom M-Pesa Daraja STK Push.

Renewal is user-initiated. The platform does not silently debit a phone or claim automatic M-Pesa recurring billing.

When the grace period ends without a confirmed payment, subscription access is suspended. School records are retained; they are not deleted.


Lifecycle


Administrator registers and verifies the account email.

Registration creates a school with status='pending' and a school-admin membership.

Platform owner reviews the application in the owner workflow and approves it (schools.status='active').

The database trigger creates the subscription and starts the 60-day trial at approval time.

During trial, school operations are available. The administrator/bursar can open Subscription & Payments and pay early if desired.

Trial-expiry reminders should be sent 14, 7, 3 and 1 day before expiry once an email/SMS delivery provider is configured. Reminder delivery is not activated by this code package. At trial expiry, subscription becomes past_due; the school has a 7-day grace period. A confirmed M-Pesa payment activates a paid month.

At grace expiry, subscription becomes suspended. School operations are blocked by is_active_school_member; billing records and school data remain available to the school membership for payment/reconciliation and to the platform owner.

A successful payment callback, verified against Daraja STK Push Query, marks the invoice paid and activates the subscription for the invoiced period.


Database deployment

Prerequisites: multi-school-foundation.sql, multi-school-approval-migration.sql, and the school's current multi-school RLS policies must already be installed.



Take a Supabase database backup.

Apply Supabase/migration/202611150001_subscription_billing.sql in the Supabase SQL Editor.

Review schools_subscription_lifecycle and confirm that the trial is created only when a school is approved.

The migration gives existing active schools a 60-day introductory trial from migration deployment. Confirm this is acceptable before running on production; if not, adjust that backfill before deployment.

Deploy Edge Functions:


supabase functions deploy create-mpesa-stk
supabase functions deploy mpesa-callback --no-verify-jwt


Configure the secrets below. Do not put any secret in app.js, HTML, GitHub Pages, or the Supabase publishable key configuration.


Required Supabase Edge Function secrets

Set these with supabase secrets set or the Supabase Dashboard:



SUPABASE_URL

SUPABASE_ANON_KEY

SUPABASE_SERVICE_ROLE_KEY (server-side only)

MPESA_ENV = sandbox during testing, then production

MPESA_SHORTCODE

MPESA_CONSUMER_KEY

MPESA_CONSUMER_SECRET

MPESA_PASSKEY

MPESA_CALLBACK_URL = the deployed public URL ending /functions/v1/mpesa-callback

MPESA_TRANSACTION_TYPE = CustomerPayBillOnline for PayBill, or the transaction type supported by the approved Till setup


The platform owner must obtain a Safaricom Daraja app, production approval, shortcode/Till and passkey. The source code does not contain live M-Pesa credentials. Test in Daraja sandbox before switching to production.


Scheduled subscription expiry

Enable pg_cron in Supabase Database → Extensions. Then schedule the expiry function once daily (UTC):


select cron.schedule(
  'jengaedu-expire-subscriptions',
  '15 0 * * *',
  $$select public.expire_school_subscriptions();$$
);

Monitor Cron job run history in Supabase. Supabase documents scheduling database functions and Edge Functions with Cron: https://supabase.com/docs/guides/cron and https://supabase.com/docs/guides/functions/schedule-functions.


Payment security and reconciliation


The browser calls only the authenticated create-mpesa-stk Edge Function.

The Edge Function checks the signed-in user's membership and role (school_admin or bursar); the server reads the invoice and fixes the amount from the invoice, never from browser input.

Daraja credentials and the Supabase service-role key are server-side secrets only.

The callback endpoint is public because Safaricom must reach it. A callback alone is not trusted: successful callbacks are re-queried through Daraja STK Push Query before the service-role-only database function activates the subscription.

The database checks the expected CheckoutRequestID, exact amount, phone number and unique M-Pesa receipt. Repeated callback IDs are idempotent.

If callback verification is unavailable, payment remains unconfirmed and must be reconciled against Daraja transaction status/M-Pesa statement. Do not manually mark an invoice paid merely because a customer shows an SMS screenshot.

The current integration supports one invoice paid in full per STK Push. Partial payments, refunds, reversals, split payments, multiple currencies and automated recurring debits are not included.


User interface

The school workspace now has Subscription & Payments in its navigation. School administrators and bursars can initiate the KES 1,000 STK Push and see subscription status and invoice history. Other school members can view subscription status but cannot initiate payment.


Go-live checklist


 Verify the platform owner is correctly present in platform_admins.

 Test registration: new school is pending, no trial clock starts.

 Approve a test school: trial starts at approval timestamp and ends 60 days later.

 Verify the school administrator and bursar can see billing; teacher cannot initiate payment.

 Test sandbox STK success, user cancellation, timeout, duplicate callback, wrong amount and wrong phone.

 Confirm a successful verified payment changes invoice to paid and subscription to active.

 Confirm trial expiry gives 7-day grace; after grace, school operations are blocked without deleting data.

 Confirm a suspended school can still access the billing page to pay.

 Confirm public learning resources follow the separately defined public-library policy.

 Test two different schools to ensure invoices, attempts and subscriptions cannot cross tenant boundaries.

 Enable and monitor the daily Cron job.

 Obtain Safaricom production credentials and perform a controlled live payment before public launch.


Important deployment note

This is an implementation package, not proof of a live payment integration. M-Pesa cannot process real payments until the platform owner configures and verifies the Safaricom production shortcode, credentials, callback URL and account. Apply migrations only after reviewing the existing live schema and taking a backup.

