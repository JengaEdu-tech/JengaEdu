# Senior Secondary (CBC Grades 10–12) Supabase migration

1. Open Supabase Dashboard → SQL Editor.
2. Confirm the base `supabase-schema.sql` has already been run and `public.school_state_shared` exists.
3. Open and run `senior-secondary-admissions-alumni-migration.sql`.
4. Deploy the updated `workspace.html`, `app.js`, and other project files to GitHub Pages.
5. Hard-refresh the site (or open a private/incognito tab).

The migration adds a database-side guard: an existing Grade 9 learner cannot be changed to Grade 10 in a shared-state update. New Grade 10 admissions are allowed. A Grade 12 learner marked `Alumni` must have a matching entry in the `alumni` array.

The app continues to store school records in `school_state_shared` using its existing compare-and-swap save function. This migration does not delete or rewrite existing learner records. Back up the shared state before deploying any application upgrade.
