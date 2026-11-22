# JengaEdu Free Preview — Subscription Payments Paused

- Enabled `JENGAEDU_FREE_ACCESS_MODE` in `app.js`.
- School access no longer depends on trial, subscription, invoice, or payment status during the preview.
- The Billing page displays a clear free-preview notice instead of requesting M-Pesa payment.
- Public pricing and school registration text now state that use is free during testing.
- Existing subscription tables, migrations, and payment functions are retained for a future launch.
- School membership checks and Supabase Row Level Security remain important and are not bypassed by this change.

## When ready to introduce payments
Change `JENGAEDU_FREE_ACCESS_MODE` from `true` to `false` in `app.js`, then verify the subscription migrations, payment Edge Functions, M-Pesa callback verification, and school access flow before announcing billing.
