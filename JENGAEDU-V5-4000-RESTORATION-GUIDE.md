# JengaEdu V5 — KSh 4,000 Termly Pricing & Dashboard Module Restoration

## Source changes
- Updated public pricing, school registration copy, subscription screen and M-Pesa button copy to KSh 4,000 per school per academic term.
- Restored working dashboard pages for School Controls, School Operations, AI Question Papers, Library & Inventory, Parent Contacts and Bulk Messaging.
- The restored pages use the existing school-scoped workspace JSONB and the existing `send-school-messages` Edge Function. They do not grant new database permissions.
- Parent contacts are derived from learner records; question papers and catalogue items are saved in the existing workspace arrays.
- Referral display and future reward calculation are updated to KSh 2,000 (50% of KSh 4,000). Existing reward records are preserved.

## GitHub files to replace/add
Replace the root files `app.js`, `index.html`, `register.html`, `referrals.html`, and `README.md` with these versions. Add `supabase/migrations/202611200003_termly_billing.sql`, `supabase/migrations/202611210002_termly_price_4000.sql`, and this guide.

## Supabase migration order
Back up the database. Ensure the base subscription migration `202611150001_subscription_billing.sql` has been applied. Then apply `202611200003_termly_billing.sql`, `202611200004_referral_rewards.sql` (if referral rewards are enabled), and finally `202611210002_termly_price_4000.sql` in that order. If any of these were already applied through SQL Editor, do not re-run blindly; compare their effects and migration history first. It updates the active term plan amount for future invoices. Existing invoices are intentionally not repriced.

## Important checks
- The plan update assumes the plan ID `school-monthly` exists, as created by the existing billing migration.
- The referral section assumes `referral_rewards` and `queue_first_term_referral_reward()` exist. If referral rewards have not been installed, run the existing referral migration before this migration.
- Bulk SMS requires the `send-school-messages` Edge Function and SMS provider secrets to be deployed. Sending is still subject to provider-side consent and configuration.
- The restored Question Papers page provides create/edit/delete storage for paper drafts; it is not an AI content-generation engine. The Library page restores catalogue management, not barcode circulation automation.
- This source package has not been deployed to GitHub Pages or Supabase and has not been tested against the live database or live M-Pesa/SMS providers.
