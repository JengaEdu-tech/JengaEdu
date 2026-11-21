# JengaEdu V5 — Multi-School Hardening + Elite Timetable Solver

## Scope delivered in this source upgrade

### Multi-school management
- Fetches all active memberships instead of silently locking the user to the first membership.
- Remembers the last selected school workspace and adds a workspace switch control in `workspace.html`.
- Reloads the selected school's cloud state, subscription access and role after switching.
- Adds active/suspended/pending membership status and an expanded school-role vocabulary.
- Adds school-scoped role/status RPCs, prevents an administrator from suspending themselves, and protects the last active school administrator.
- Replaces permissive `school_state_shared` policies with UUID-school membership + subscription + staff-role checks.
- Replaces the patch-save RPC authorization that previously relied on a global first-membership role and disables the legacy global `current_school_role()` lookup as an authorization source.
- Adds `school_id` scoping to certificate issues and notification delivery logs; replaces the old single-school certificate RPC.
- Tightens school calendar and opportunities writes to appropriate school leadership/teaching roles, and restricts subscription invoices/payment attempts to active billing staff.
- Makes timetable relational tables read-only to authenticated clients; timetable/resource writes must go through the authorized school-scoped RPCs.
- Updates the staff invitation and messaging Edge Functions for the expanded role set and school-specific records.

**Important limitation:** `school_state_shared.data` remains a coarse JSONB workspace for compatibility. V5 enforces school-level and staff-role access to that row, but it does not provide field-level permissions inside JSONB. For example, teacher-versus-bursar separation inside that shared blob is not fully solved. The new timetable tables are relational and use tighter role-specific RLS. Further critical modules (learners, marks, payments, attendance) should be normalized before claiming fine-grained access control across the entire product.

### Timetable V5
- Keeps the existing V4 editor, conflict centre, lock/unlock, undo/redo, version history and colourful A4/PDF/CSV output.
- Replaces the default generator action with an authenticated `solve-timetable` Edge Function call.
- Adds a stateless FastAPI service using Google OR-Tools CP-SAT.
- Models class/group, teacher, learner and room collisions as hard constraints.
- Supports consecutive multi-period lesson blocks, teacher availability allow-lists, room capacity, maximum weekly teacher periods and maximum consecutive periods.
- Uses a soft objective to spread the same class/subject across different days.
- Returns explicitly unplaced lesson units with reasons instead of silently inventing placements.
- Solves Senior School teaching groups together with whole-class lessons; group learner membership is required so parallel elective groups can be checked correctly.
- Adds a resources editor for rooms, teacher availability and teacher workload limits.
- Adds normalized tables for timetable lessons, requirements, rooms, teacher availability and workload limits. The existing JSONB timetable remains as a compatibility copy.
- Syncs timetable edits and resources to the relational tables through school-authorized RPCs.
- Keeps the previous heuristic generator available as an explicitly labelled legacy fallback. It is not the CP-SAT solver.

The CP-SAT solver is an optimization engine, not a generative AI model. It is called through a server-side service so no solver API key or Supabase service-role key is exposed in the browser.

## Files added or changed

- `app.js` — membership/workspace switching, CP-SAT request payload, solver invocation, timetable resource editor and relational sync.
- `workspace.html` — school workspace switch button.
- `supabase/migrations/202611210001_v5_multischool_timetable.sql` — school-scoped security and normalized timetable schema/RPCs.
- `supabase/functions/solve-timetable/index.ts` — authenticated and subscription-aware solver gateway.
- `supabase/functions/invite-staff/index.ts` — supports the expanded role set.
- `supabase/functions/send-school-messages/index.ts` — requires a specific school ID and writes school-scoped delivery logs.
- `supabase/functions/send-parent-document/index.ts` — writes school-scoped delivery logs.
- `services/timetable-solver/` — FastAPI + OR-Tools CP-SAT service, Dockerfile, requirements and tests.
- `tests/v5-multischool-timetable.test.cjs` — source-level regression checks.

## Deployment prerequisites — read before running SQL

1. Take a verified Supabase backup and export the current `school_state_shared` records.
2. Confirm the existing multi-school foundation, school approval, staff invitation, staff-role/certificate, calendar/opportunities, subscription billing and multi-school persistence-repair migrations have already been applied. In particular, this migration expects `schools`, `school_memberships`, `school_subscriptions`, `school_invitations`, `school_state_shared`, `certificate_issues`, `notification_delivery_logs`, `school_events`, `school_opportunities`, `subscription_invoices`, `subscription_payment_attempts`, and `is_platform_admin()` to exist.
3. Confirm every active school has a `school_state_shared` row whose `id` is exactly that school's UUID text. V5 deliberately does **not** guess which school owns a legacy non-UUID row such as `JENGAEDU`. Back up and map any such legacy row to the correct school before applying the stricter RLS policy. Do not discard the old row.
4. Check existing membership role values before the migration. It normalizes common `admin` / `administrator` / `head` / `deputy` / `finance` labels and then applies the V5 role constraint. Investigate any other custom role value first.
5. Apply `supabase/migrations/202611210001_v5_multischool_timetable.sql` in the Supabase SQL Editor. It is transactional and additive to the legacy JSONB workspace, but it changes security policies and function authorization; test on a staging project first.
6. Redeploy `invite-staff`, `send-school-messages`, and `send-parent-document` after deploying their changed source. Deploy the new `solve-timetable` function:

   ```bash
   supabase functions deploy solve-timetable
   supabase functions deploy invite-staff
   supabase functions deploy send-school-messages
   supabase functions deploy send-parent-document
   ```

## Deploy the OR-Tools solver service

The solver is a separate backend service. Deploy `services/timetable-solver` to a private HTTPS container host (Cloud Run, Fly.io, Render private service, or equivalent). It must not be exposed without the shared secret.

Local run:

```bash
cd services/timetable-solver
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export TIMETABLE_SOLVER_API_KEY='generate-a-long-random-secret'
uvicorn app:app --host 0.0.0.0 --port 8080
```

Set `TIMETABLE_SOLVER_API_KEY` in the solver host's secret manager. Then set the same key and the solver's base HTTPS URL as Supabase Edge Function secrets:

```bash
supabase secrets set TIMETABLE_SOLVER_URL='https://YOUR-PRIVATE-SOLVER-HOST'
supabase secrets set TIMETABLE_SOLVER_API_KEY='THE-SAME-LONG-RANDOM-SECRET'
```

Do not put either secret in `app.js`, HTML, GitHub Pages, or any browser-visible configuration. The Edge Function validates the user's Supabase JWT, selected school membership, school status, school subscription and timetable-administrator role before forwarding the request.

Health check:

```bash
curl https://YOUR-PRIVATE-SOLVER-HOST/health
```

Expected response includes `"solver_available": true` after the OR-Tools dependency is installed.

## GitHub / frontend deployment

Deploy the repository root using the existing GitHub Pages workflow. The school workspace entry point remains `workspace.html`; the public homepage remains `index.html`. Preserve the existing Supabase URL and publishable key. Never add a service-role key to the frontend.

## First-run configuration

1. Sign in as a school administrator or headteacher.
2. If the account belongs to multiple schools, use **Switch school workspace** to select the intended school.
3. Open Timetables → **Rooms & availability**.
4. Add rooms one per line: `Room name,capacity,type`.
5. Add teacher availability JSON keyed by teacher ID. A list value is an allow-list such as `{"T001":["Monday|08:00–08:40","Tuesday|09:00–09:40"]}`. If a teacher ID is omitted, the solver treats them as available for all configured periods.
6. Add optional workload limits such as `{"T001":{"max_weekly_periods":28,"max_consecutive_periods":4}}`. A zero or omitted limit means unrestricted.
7. Ensure each teaching assignment has an eligible teacher. For Senior School teaching groups, add the group's learner membership before generation.
8. Select one class or a section and choose **Optimize selected class** or **Optimize whole section**.
9. Review unplaced lessons and the conflict centre. Verify the result before printing or publishing.

`durationPeriods` on a subject/group requirement controls forced consecutive blocks. The existing `doubleLesson` flag remains a legacy scheduling preference and is not automatically interpreted as a forced two-period block.

## Validation performed in this build environment

- `node --check app.js` — passed.
- `node --test tests/timetable-v4.test.cjs tests/v5-multischool-timetable.test.cjs` — 13 tests passed.
- `python -m py_compile services/timetable-solver/app.py` — passed.
- `python -m pytest -q services/timetable-solver/tests` — 4 passed, 1 skipped (the CP-SAT runtime test requires OR-Tools).
- OR-Tools itself was not installed in this build environment because package download/network access was unavailable. The CP-SAT runtime tests are therefore skipped here and must run in the deployed solver environment after `pip install -r requirements.txt`.
- A lightweight SQL lexical/parenthesis balance check passed; this is not a PostgreSQL execution or SQL-parser test.
- No Supabase migration was executed against a live project.
- No Edge Function was deployed.
- No real school account, two-school isolation test, browser QA or production timetable was verified.

## Required staging acceptance tests

### Multi-school isolation
- Create two active schools with different users and separate UUID-keyed `school_state_shared` rows.
- Give one user active memberships in both schools; switch between them and confirm the selected school's name, data and role change together.
- Confirm School A staff cannot read or update School B's JSONB row, timetable tables, certificate issues or notification logs.
- Confirm a parent/learner role cannot read `school_state_shared` or whole-school timetable tables.
- Suspend a membership and confirm access is denied without removing the historical records.
- Expire/suspend the subscription and confirm normal school workspace and solver operations are blocked while billing access remains available through the existing billing flow.
- Confirm the school retains at least one active administrator.

### Timetable solver
- Two classes sharing a teacher never overlap.
- Two lessons using one room never overlap.
- Whole-class lessons do not overlap their learners' elective group lessons.
- Parallel elective groups with disjoint learner sets can run simultaneously.
- A two-period requirement occupies two consecutive periods on the same day.
- Teacher unavailable periods are not used.
- Room capacity is enforced when a room is required.
- Weekly and consecutive teacher workload limits are respected.
- Locked lessons and other classes' lessons remain fixed during regeneration.
- Infeasible requirements are reported as unplaced or as a clear infeasibility error; no invalid schedule is published.
- Confirm normalized relational rows and the legacy JSONB timetable copy agree after generation and manual edits.

Do not claim production-ready multi-school isolation or a production-tested timetable solver until these staging tests pass.
