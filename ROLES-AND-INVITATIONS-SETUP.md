# JengaEdu Roles and Invitations — Deployment Guide

This update adds a School Admin staff-management screen, invitation email delivery through a Supabase Edge Function, invitation acceptance, invitation history, role changes, staff suspension/reactivation and membership removal.

## 1. Roles included

- **Platform Owner:** retains owner-only authority over school approval and status changes.
- **Platform Manager:** platform support role; does not receive owner-only approval authority.
- **School Admin:** manages staff invitations and school memberships.
- **Teacher, Staff, Bursar, Accountant and Librarian:** school membership roles available for assignment.

The staff-management screen is visible to School Admins and platform administrators. This is not yet a complete feature-by-feature permission system for every school module; sensitive database operations must continue to be protected with appropriate RLS policies or secure RPCs.

## 2. Update the GitHub project

Replace the existing repository files with the contents of this updated project. Keep your existing Supabase URL, publishable/anon key and GitHub OAuth configuration unchanged.

## 3. Run the SQL migration

Run `Supabase/migration/20261110_roles_permissions_invitations.sql` in Supabase SQL Editor after the existing multi-school foundation and school-approval migrations. Back up the database first.

## 4. Deploy the invitation Edge Function

From the project root, using the Supabase CLI linked to the correct Supabase project, run:

```bash
supabase functions deploy invite-staff
```

The function uses Supabase's managed `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` environment variables. Never place the service-role key in `app.js`, HTML, GitHub Pages, or any browser code. It validates the invitation redirect against the current JengaEdu GitHub Pages workspace URL. If you later move to a custom domain or different repository path, set the Edge Function secret `JENGAEDU_WORKSPACE_URL` to the exact deployed `workspace.html` URL.

## 5. Configure Supabase Auth email delivery

1. In Supabase, open **Authentication → URL Configuration**.
2. Set the Site URL to your deployed JengaEdu website.
3. Add the exact deployed `workspace.html` URL to the Redirect URLs allowlist (for example, `https://YOUR-ACCOUNT.github.io/YOUR-REPOSITORY/workspace.html`).
4. Ensure email invitations are enabled under Authentication email settings.
5. Configure a reliable custom SMTP provider for production email delivery. Supabase's default email service may have low limits and is not intended for sustained production use.

The invitation function creates a time-limited database invitation, then asks Supabase Auth to send the invitation email. The email link returns to `workspace.html` with a one-time invitation token. The recipient must use the same email address to which the invitation was sent. Invitations expire after seven days.

## 6. Test before using with all staff

1. Sign in as a School Admin.
2. Open **Staff Management** in the sidebar.
3. Invite a test email address and choose a role.
4. Confirm the email arrives and opens the JengaEdu workspace.
5. Complete sign-in/verification using the invited email address.
6. Confirm that the membership appears under Current School Members with the assigned role.
7. Test changing a test member's role, suspending/reactivating access and cancelling a pending invitation.
8. Confirm a normal Teacher account cannot open Staff Management.

## Important notes

- The invitation sender is a server-side Edge Function located in `supabase/functions/invite-staff/index.ts`; the service-role key never reaches the browser. The matching source is also kept under the project’s existing `Supabase/functions/` folder alongside the earlier backend files.
- Inviting an email that already has a Supabase Auth account may be rejected by Supabase's invite endpoint. Use a new email address for the first test, or implement a separate existing-user notification flow if that is needed.
- Current members are displayed by shortened Auth user ID because the browser cannot safely read the private `auth.users` table. The invitation history displays email addresses.
- Suspending a membership immediately blocks school-state access; reactivating restores it. Removing a membership revokes that person's access to this school. The member's Supabase Auth account itself is not deleted.
- This update adds role assignment and staff membership management. It does not automatically hide or secure every application module by role; enforce feature-level permissions at the database/API layer before production use.
