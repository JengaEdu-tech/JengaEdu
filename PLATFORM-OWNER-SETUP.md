# Platform owner correction

The Auth UID `a24e261f-28ef-4584-b4a1-152bf725a774` is registered in `public.platform_admins` as the platform owner. It is deliberately NOT added to `school_memberships` and is not assigned to JengaEdu or any other school.

Run order:
1. Back up the Supabase project.
2. Run `Supabase/multi-school-foundation.sql` if it has not already been applied.
3. Run `Supabase/multi-school-approval-migration.sql` only if its prerequisites and application workflow are in use.
4. Run `supabase-inventory-migration.sql`.

The inventory policies allow platform admins to administer all inventory tenants. Non-platform users must have a membership in the matching school and that school must have status `active`. The script drops/recreates only its own named inventory policy on each inventory table; it does not delete inventory data.

Important: This script assumes `schools`, `school_memberships`, `platform_admins`, `is_platform_admin()` exist from the foundation migration. It has not been run against your live Supabase project. Verify the Auth UID exists before running; the insert will fail if it does not.

5. Run `Supabase/migration/202611100001_platform_identifier_cleanup.sql` to rename the existing shared-state technical ID without changing its JSONB data.
