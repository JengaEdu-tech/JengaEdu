# JengaEdu Phase 3 — Module UI Refresh

## Scope
A presentation-layer refresh for the main school administration modules.

## Updated modules
- Learner register
- Teacher register
- Exams and assessments
- Marks entry
- Individual learner reports
- Fees management
- Capitation and BOM funds
- Subject management
- Timetable generator

## Design changes
- Consistent module headings, descriptions and section labels.
- Cleaner cards, forms, buttons, data tables, status labels and empty states.
- Responsive spacing and controls for small screens.
- Better horizontal scrolling for wide data tables on phones.

## Functionality protection
This update changes module presentation markup and adds CSS. Existing database schemas, Supabase configuration, data calculations, record operations, permissions, printing and exports are retained.

## Files changed
- `app.js`
- `workspace.html`
- `phase3-modules.css` (new)

## Deployment
Upload the updated `app.js` and `workspace.html` to the repository root, add `phase3-modules.css`, and preserve all existing folders. Keep a backup before replacing files.

## Recommended checks
Open each updated module on desktop and Android. Test learner search/edit/archive/import, teacher records, exam creation, marks loading/saving/CSV, reports and A4 output, fee payments/receipts/CSV, capitation transactions/BOM documents, subject setup and timetable generation/printing.
