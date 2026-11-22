# JengaEdu Premium Interface Refresh

This refresh updates the public school-facing experience while preserving the existing application logic and Supabase integration.

## Updated
- `index.html`: retained the existing public marketing homepage and its navigation, feature sections, pricing and calls to action.
- `register.html`: redesigned the school registration page with a responsive two-panel onboarding layout. Existing Supabase sign-up logic and field IDs are preserved.
- `workspace.html`: redesigned the sign-in experience and added a responsive mobile navigation bar and off-canvas sidebar.
- `style.css`: added a presentation-only premium design layer and mobile layout overrides.

## Preserved
- `app.js` and its existing school management modules.
- Supabase project URL and public client configuration.
- Existing registration fields, IDs and sign-up metadata.
- Existing dashboard page IDs, navigation actions, module routes and print/report styles.
- Existing Finance, TPAD, Community, Public Library, AI lesson tools and SQL migrations.

## Deployment
Upload the contents of this ZIP to the repository root and replace the corresponding files. Keep the existing folder structure. No Supabase SQL migration is required for this visual refresh.

After deployment, test school registration, login, password recovery, GitHub sign-in (if enabled in Supabase), school switching, dashboard navigation, printing and mobile sidebar behaviour.
