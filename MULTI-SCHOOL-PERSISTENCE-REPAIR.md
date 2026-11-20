# JengaEdu multi-school persistence repair

This repair addresses the mismatch between school UUIDs used by the browser and the legacy SQL patch function that accepted only `JENGAEDU`.

## Files changed
- `app.js`: the shared-state ID is no longer defaulted to the legacy `JENGAEDU` row. Cloud load, save, and refresh require a verified active school membership and the matching school UUID.
- `Supabase/migration/202611200001_multischool_persistence_repair.sql`: updates the patch RPC to authorize the authenticated user's school UUID, maps `school_admin` to the app's `admin` role, and removes older broad RLS policies that could override school isolation.

## Before deployment
1. Back up the Supabase database (especially `school_state_shared`).
2. Confirm the existing multi-school foundation, approval/roles, and concurrent-save migrations have been applied.
3. Run `Supabase/migration/202611200001_multischool_persistence_repair.sql` in Supabase SQL Editor.
4. Deploy the complete repository contents to GitHub Pages.

## Test
1. Sign in with an approved school administrator account.
2. Add one test learner and wait for the save confirmation.
3. Refresh the page, then sign out and sign back in.
4. Confirm the learner remains.
5. Repeat with a second school account and verify it cannot see the first school's learners.

Do not delete or reset existing tables. The migration is transactional and does not delete school data. The repair has not been run against the live Supabase project; verify the SQL result and the two-school isolation test after deployment.
