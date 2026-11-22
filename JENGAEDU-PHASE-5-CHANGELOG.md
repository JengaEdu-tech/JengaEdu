# JengaEdu Phase 5 changelog

## Multi-user and school operations upgrade

- Replaced Phase 4 unavailable-page routes for Parent Contacts, Bulk Messaging, AI Question Papers and School Operations with working module screens.
- Restored parent contact editing and independent SMS / WhatsApp consent controls.
- Restored the bulk messaging interface and connected it to the existing Supabase `send-school-messages` gateway.
- Added secure portal invitation records bound to a verified email, with seven-day expiry and one-time acceptance.
- Added a standalone Parent / Learner Portal (`portal.html`) that uses Supabase Auth and a server-side learner-link RPC.
- Added `school_portal_links`, `school_portal_invitations`, `school_operations_tasks`, `school_message_campaigns` and `school_ai_question_papers`.
- Added RLS policies and role helper functions for the new normalized tables.
- Added an AI question-paper Edge Function with server-side OpenAI key storage and teacher-role verification.
- Added a school operations task tracker.
- Tightened notification delivery-log reads to authorized staff in the same school.
- Preserved the Phase 4 staff invitation and membership management workflows.

## Explicit limitations

- Parent/learner invitation email dispatch is not automated in this release; administrators privately share the generated invitation link.
- The parent portal currently shows the linked learner identity/profile summary only. Marks, attendance, fee balances, report cards and messaging history are not yet exposed as parent portal views.
- AI question papers are generated as drafts based on teacher-supplied strands and learning outcomes. Teachers must verify curriculum alignment and correctness before use.
- Legacy school data remains in one JSONB record; role-level field security is not yet possible for all legacy modules. See the Phase 5 upgrade guide before production rollout.
