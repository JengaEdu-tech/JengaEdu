# JengaEdu Multi-School Transition

## Included
- `index.html`: responsive JengaEdu public homepage and SaaS-style design.
- `workspace.html`: preserved original school management application and login.
- `register.html`: onboarding placeholder (not yet connected to authentication).
- `Supabase/multi-school-foundation.sql`: school directory, membership and platform-admin foundation.

## Important status
This is a visual transition and database foundation—not yet a production SaaS. Existing data is preserved in the old workspace; it has not been tenant-migrated. Registration is deliberately marked as a placeholder until secure signup and full table-level tenant isolation are implemented.

## Safe implementation sequence
1. Deploy and preview homepage; use `workspace.html` to access the existing app.
2. Back up Supabase before any migration.
3. Create a school record for the current installation and backfill existing records with its school UUID.
4. Scope every school-owned table/state by `school_id`; apply and test RLS for every operation.
5. Implement registration with a Supabase Edge Function (service role server-side only), email verification, and school-admin membership creation.
6. Add platform-owner dashboard, school activation/suspension, and school workspace selection.
7. Test with two separate schools and prove cross-school data access is denied before public signup.
