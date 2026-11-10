# Changelog — Staff Management and Invitations (10 November 2026)

- Added a School Admin-only Staff Management navigation item and screen.
- Added role selection and invitation email dispatch through the `invite-staff` Supabase Edge Function.
- Added automatic invitation-token acceptance after the recipient verifies/signs in with the invited email.
- Added invitation history, pending invitation cancellation and seven-day expiry display.
- Added current membership listing, role changes, suspension/reactivation and membership removal.
- Added membership `status` to the SQL migration and updated school-state RLS policies so suspended memberships lose access.
- Added deployment and Supabase Auth email configuration instructions.
- Preserved the existing Supabase URL, publishable key, GitHub OAuth configuration and existing school modules.
