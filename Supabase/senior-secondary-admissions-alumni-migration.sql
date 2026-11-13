-- JengaEdu CBC Senior Secondary separation
-- Run once in Supabase SQL Editor AFTER the base supabase-schema.sql.
-- Senior Secondary admission is direct into Grade 10. Grade 9 is never
-- promoted into Grade 10. Grade 10 -> 11 -> 12 remains the normal progression.
-- Grade 12 graduates are retained in learners with status Alumni and copied
-- into the alumni register by the application.

begin;

create table if not exists public.jengaedu_schema_migrations (
  migration_key text primary key,
  applied_at timestamptz not null default now()
);
alter table public.jengaedu_schema_migrations enable row level security;
revoke all on public.jengaedu_schema_migrations from anon, authenticated;

create or replace function public.jengaedu_guard_senior_secondary_separation()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  old_learners jsonb;
  new_learners jsonb;
  invalid_transition boolean;
begin
  old_learners := coalesce(old.data->'learners', '[]'::jsonb);
  new_learners := coalesce(new.data->'learners', '[]'::jsonb);

  -- Existing Grade 9 learners cannot be moved to Grade 10 by a bulk promotion
  -- or by editing their class. New Grade 10 admissions remain permitted.
  select exists (
    select 1
    from jsonb_array_elements(old_learners) o(learner)
    join jsonb_array_elements(new_learners) n(learner)
      on coalesce(o.learner->>'id', o.learner->>'adm') =
         coalesce(n.learner->>'id', n.learner->>'adm')
    where o.learner->>'class' = 'Grade 9'
      and n.learner->>'class' = 'Grade 10'
  ) into invalid_transition;

  if invalid_transition then
    raise exception using errcode = '23514',
      message = 'Grade 9 cannot be promoted to Grade 10. Admit learners directly into Senior Secondary Grade 10.';
  end if;

  -- A Grade 12 learner marked Alumni must have a corresponding alumni entry.
  select exists (
    select 1
    from jsonb_array_elements(new_learners) n(learner)
    where n.learner->>'class' = 'Grade 12'
      and n.learner->>'status' = 'Alumni'
      and not exists (
        select 1
        from jsonb_array_elements(coalesce(new.data->'alumni', '[]'::jsonb)) a(entry)
        where coalesce(a.entry->>'learnerId', a.entry->>'adm') =
              coalesce(n.learner->>'id', n.learner->>'adm')
      )
  ) into invalid_transition;

  if invalid_transition then
    raise exception using errcode = '23514',
      message = 'A Grade 12 graduate marked Alumni must also have an Alumni Register record.';
  end if;

  return new;
end;
$$;

drop trigger if exists jengaedu_guard_senior_secondary_separation
  on public.school_state_shared;
create trigger jengaedu_guard_senior_secondary_separation
before update of data on public.school_state_shared
for each row execute function public.jengaedu_guard_senior_secondary_separation();

insert into public.jengaedu_schema_migrations(migration_key, applied_at)
values ('senior-secondary-admissions-alumni-v1', now())
on conflict (migration_key) do nothing;

commit;
