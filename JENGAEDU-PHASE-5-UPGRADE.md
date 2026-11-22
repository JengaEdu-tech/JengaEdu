# JengaEdu Phase 5 — Multi-user portals and school operations

Phase 5 builds on the Phase 4 GitHub package. It restores the routes that Phase 4 had mapped to unavailable placeholders and adds the first secure backend layer for parent/learner accounts.

## Included in this package

- Parent / Guardian Contacts: edit parent name and phone; record SMS and WhatsApp consent separately.
- Bulk Messaging: restored SMS / WhatsApp campaign screen using the existing `send-school-messages` Edge Function. The gateway rechecks active staff membership, learner ID, phone number and channel consent.
- AI Question Papers: new Supabase Edge Function `generate-ai-question-paper`; it creates a structured teacher-reviewable draft using the strands and learning outcomes entered by the teacher.
- School Operations: task tracker backed by `school_operations_tasks`.
- Parent / Learner Portal: standalone `portal.html`, verified-email invitation acceptance, and server-filtered linked learner profiles.
- School administrator and headteacher invitation controls for parent/learner portal links.
- Normalized tables and RLS policies for portal links, portal invitations, operational tasks, AI paper drafts, message campaigns and delivery logs.
- Existing staff invitations, membership roles, suspension and platform-owner tools are retained.

## Important security boundary

The legacy `school_state_shared` table stores many unrelated school records in one JSONB document. Its existing Phase 4/5 membership policy grants active members school-level access to that document. Hiding a button in JavaScript cannot make individual JSON fields private. Phase 5 therefore applies role-specific RLS to the new normalized tables, and the portal RPC returns only a limited learner profile. It does **not** claim that every legacy field (for example, fees, marks, payroll or learner details) has been migrated to normalized tables or protected by field-level policies.

Before using the portals with real parent/learner data, complete the data-governance review and verify every legacy module's read/write permissions. A future hardening release should move marks, attendance, fee balances, report cards and learner profile data into separate school-scoped tables with purpose-specific policies and audit logging.

## Deployment

1. Back up the Supabase database and current GitHub repository.
2. Upload the contents of `JengaEdu-main` to the existing GitHub repository, preserving directories.
3. In Supabase SQL Editor, run in order:
   - Existing migrations through `202611210001_v5_multischool_timetable.sql` (skip migrations already applied).
   - `supabase/migrations/202611220001_phase5_portals_operations.sql`.
4. Deploy Edge Functions:
   ```bash
   supabase functions deploy send-school-messages
   supabase functions deploy generate-ai-question-paper
   ```
5. Configure Edge Function secrets:
   ```bash
   supabase secrets set OPENAI_API_KEY=YOUR_PRIVATE_OPENAI_API_KEY
   supabase secrets set OPENAI_MODEL=gpt-4.1-mini
   ```
   The existing SMS / WhatsApp secrets remain as described in `BULK-MESSAGING-SETUP.md`. Never put a service-role key or provider key in `app.js`, `portal.html`, GitHub, or browser local storage.
6. Confirm Supabase Auth email verification and password recovery settings. Portal invitations are email-bound tokens; this release creates a secure invitation link in Parent Contacts but does not send the invitation email automatically. Share it privately with the invited address. The recipient must have a verified Supabase Auth account using the same email.
7. Ensure `portal.html` is published at the repository root and the GitHub Pages base path is correct.
8. Test using separate test accounts: school admin, teacher, bursar, parent and learner. Do not test with real learner records first.

## Portal invitation workflow

1. Sign in as a School Administrator or Headteacher.
2. Open Parent Contacts, select the learner, enter the parent's/learner's verified email and portal role, then create an invitation link.
3. Share the link privately with the intended recipient.
4. The recipient opens `portal.html`, signs in with the same verified email, and the invitation is accepted.
5. The portal only returns learner profiles explicitly linked to that authenticated user and school. A user cannot select another learner by changing a URL parameter.

## AI question-paper workflow

1. Open AI Question Papers.
2. Enter the title, class, subject, term/year, strands/sub-strands and actual learning outcomes.
3. Generate an AI draft. The Edge Function verifies the signed-in user's school role before calling the AI provider.
4. Review questions, marks, expected answers and curriculum alignment. AI-generated material is not KICD-approved and must not be issued without teacher review.
5. If generation fails, verify `OPENAI_API_KEY`, Edge Function deployment, Supabase Auth and the user's role.

## School operations

The School Operations page supports creating tasks, categories, due dates and status updates. It is not a replacement for the school's statutory registers, payroll or accounting system.

## Bulk messaging

The Bulk Messaging page requires separate consent for SMS and WhatsApp. It sends to up to 200 eligible recipients per request. For WhatsApp, configure an approved Meta template and its template name. Provider acceptance is not final delivery confirmation. Refer to `BULK-MESSAGING-SETUP.md`.

## Platform owner

The existing `owner.html` and platform-admin database controls are retained. Platform-owner access must be assigned through the existing protected `platform_admins` process; never expose an owner secret or service-role key in the browser.

## Verification checklist

- [ ] Phase 5 SQL migration completes without errors.
- [ ] Parent invitation insert is rejected for a teacher account.
- [ ] Parent invitation can only be accepted by the matching verified email.
- [ ] Parent A cannot retrieve Parent B's linked learner profile.
- [ ] Suspended staff lose school membership access.
- [ ] Teacher can create AI paper drafts; parent cannot.
- [ ] AI provider key is absent from browser source and GitHub.
- [ ] SMS without SMS consent is rejected.
- [ ] WhatsApp without WhatsApp consent is rejected.
- [ ] More than 200 recipients are rejected.
- [ ] Delivery logs are visible only to authorized staff in the same school.
- [ ] Parent portal works on Android and desktop.
