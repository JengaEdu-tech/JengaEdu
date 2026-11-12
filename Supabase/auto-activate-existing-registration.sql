-- JengaEdu: allow newly registered schools to use the workspace immediately.
-- Run this once in Supabase SQL Editor.

-- Activate any existing schools that were waiting for owner approval.
update public.schools
set status = 'active'
where status = 'pending';

-- Future school registrations are controlled by the updated
-- Supabase/school-registration-trigger.sql file. Re-run that file after this migration.
