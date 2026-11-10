# Multi-school registration and approval implementation

Implemented:
- Real Supabase Auth-backed school registration form.
- New schools are always created as `pending`.
- The registering account becomes that school's `school_admin`, but cannot enter the workspace while pending.
- Workspace login checks membership and school status before loading any school data.
- Only `platform_admins` can approve, reject, suspend, or re-approve a school through the owner dashboard/RPC.
- `school_state_shared` is isolated by school UUID and requires the school to be `active`.

## Deploy
1. Run `Supabase/multi-school-foundation.sql` if not already installed.
2. Run `Supabase/multi-school-approval-migration.sql`.
3. Insert the platform owner's Supabase Auth UUID into `platform_admins` using the one-time setup statement in the migration.
4. Deploy the updated files, including `owner.html`.
5. Register a test school, approve it from `owner.html`, then verify login. Suspend it and verify login is denied.

The owner account should not be given to schools. Keep it as the only row in `platform_admins` unless platform ownership is intentionally transferred.
