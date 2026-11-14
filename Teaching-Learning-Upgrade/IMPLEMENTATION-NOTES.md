# JengaEdu Teaching, Learning & TPAD Upgrade

## Included
- `teaching-learning-upgrade.sql`: database tables for per-lesson learner attendance, curriculum suggestions/custom entries, records of work, lesson plans and teacher reflections.
- `FEATURE-SPEC.md`: acceptance criteria and the intended shared-data workflow.

## Important deployment note
This is a database foundation and implementation specification, not a claim that the current `workspace.html` menus or TPAD screens have already been wired to these tables. The current JengaEdu project stores some school records in its shared `school_state` JSON structure; the new tables require an application integration pass.

## Apply
1. Back up Supabase first.
2. Run `teaching-learning-upgrade.sql` in Supabase SQL Editor.
3. Keep the creator-only RLS policy until your school-membership table/function is wired and tested. It is intentionally conservative; it does not yet permit all staff in one school to see each other's records.
4. Integrate forms into `workspace.html`/`app.js` and map authenticated user to the active `school_id`.
5. Test with two staff accounts in the same school and a third account from another school.

Do not import curriculum as “official” unless source/reference and verification are supplied. Teacher-created items are explicitly marked `teacher-entered`.
