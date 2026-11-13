# Supabase Setup — JengaEdu

## 1. Connected project
The app is configured to use this Supabase project:
- Project reference: `jtroizfsybwhjqyhvdyd`
- Project URL: `https://jtroizfsybwhjqyhvdyd.supabase.co`
- Browser key: Supabase publishable key (safe to expose when Row Level Security is enabled)

The publishable key is already configured in `app.js`. Never put a `service_role` or secret key in browser code or GitHub.

## 2. Create the database
1. Open the Supabase project above.
2. Open **SQL Editor → New query**.
3. Open `supabase-schema.sql` from this project, copy its entire contents, paste into the SQL Editor, and click **Run**.
4. This creates `public.school_state_shared`, enables RLS, creates the initial `JENGAEDU` shared-state record, and installs the atomic concurrent-save function used by the app. The record ID is an internal compatibility identifier; it does not force the school name shown in School Settings.

## 3. Create the first administrator account
1. In Supabase, open **Authentication → Users → Add user**.
2. Create the administrator's email and password. Use an email you control.
3. Copy the new user's **UID**.

## 4. Enable staff-role security (recommended before adding staff)
Run these SQL files in this order in the SQL Editor:
1. `Supabase/migration/202611070001_notification_delivery_logs`
2. `Supabase/migration/202611070003_staff_roles_certificates_email.sql`

Then replace `PASTE-ADMIN-USER-UUID-HERE` in the following SQL with the administrator UID copied in step 3, and run it:

```sql
insert into public.school_staff_roles (user_id, role, active)
values ('PASTE-ADMIN-USER-UUID-HERE', 'admin', true)
on conflict (user_id) do update
set role = excluded.role, active = true;
```

Create each additional staff member under **Authentication → Users**, then assign exactly one appropriate role (`headteacher`, `teacher`, or `bursar`) using the same SQL pattern. Do not give staff admin access unless authorised.

## 5. Deploy the website
Upload the updated project files to the root of your GitHub repository (especially `index.html`, `app.js`, and `style.css`). Commit the changes and wait for GitHub Pages to finish deploying. Open the deployed website and sign in using the administrator email/password created in Supabase.

## 6. Test before entering real school data
- Confirm the administrator can sign in.
- Confirm the school dashboard loads and a test change saves.
- Refresh the page and confirm the test change remains.
- Sign in from a second device using a separate authorised staff account and confirm it sees the same shared data.
- Remove test records before entering real learner information.

## Security notes
- The publishable key is designed for browser use; it is not a password. RLS and the staff-role policies protect the data.
- Never publish a Supabase `service_role` key. Keep provider/API secrets in Supabase Edge Function secrets only.
- This app currently stores most school records in one shared JSONB row. Role-based access limits who can access the row, but does not yet provide field-level separation between teacher, bursar, and administrator data.
- Do not upload real learner records or parent contacts to a public GitHub repository.
