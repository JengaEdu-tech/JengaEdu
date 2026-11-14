-- JengaEdu Teaching, Learning & TPAD data foundation
-- Apply in Supabase SQL Editor. School-scoped records; created_by is the authenticated user.
create extension if not exists pgcrypto;

create table if not exists public.tl_lesson_attendance (
 id uuid primary key default gen_random_uuid(), school_id uuid not null, class_name text not null,
 subject text not null, lesson_date date not null, lesson_no integer, teacher_id uuid not null default auth.uid(),
 learner_id text not null, learner_name text not null,
 status text not null check(status in ('present','absent','late','excused')),
 remarks text default '', created_by uuid not null default auth.uid(), created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), unique(school_id,class_name,subject,lesson_date,lesson_no,learner_id)
);
create table if not exists public.tl_curriculum_items (
 id uuid primary key default gen_random_uuid(), school_id uuid, curriculum_source text not null default 'official-suggestion',
 grade text not null, subject text not null, strand text not null, substrand text not null,
 topic text default '', learning_outcome text default '', learning_experience text default '',
 source_reference text default '', verified boolean not null default false, created_by uuid default auth.uid(),
 created_at timestamptz not null default now(),
 check(curriculum_source in ('official-suggestion','teacher-entered'))
);
create table if not exists public.tl_records_of_work (
 id uuid primary key default gen_random_uuid(), school_id uuid not null, teacher_id uuid not null default auth.uid(),
 class_name text not null, subject text not null, grade text not null, lesson_date date not null,
 curriculum_item_id uuid references public.tl_curriculum_items(id) on delete set null,
 strand text not null default '', substrand text not null default '', topic text not null default '',
 learning_outcomes text default '', learning_experiences text default '',
 entry_source text not null default 'curriculum-suggested' check(entry_source in ('curriculum-suggested','teacher-entered')),
 lessons_planned integer default 1, lessons_taught integer default 1, remarks text default '',
 created_by uuid not null default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.tl_lesson_plans (
 id uuid primary key default gen_random_uuid(), school_id uuid not null, teacher_id uuid not null default auth.uid(),
 class_name text not null, grade text not null, subject text not null, lesson_date date not null,
 strand text default '', substrand text default '', topic text default '',
 learning_outcomes text default '', learning_experiences text default '', resources text default '',
 assessment_method text default '', reflection text default '', created_by uuid not null default auth.uid(),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.tl_teacher_reflections (
 id uuid primary key default gen_random_uuid(), school_id uuid not null, teacher_id uuid not null default auth.uid(),
 lesson_plan_id uuid references public.tl_lesson_plans(id) on delete set null,
 reflection_date date not null default current_date, what_went_well text default '',
 challenges text default '', next_steps text default '', evidence_url text default '',
 created_by uuid not null default auth.uid(), created_at timestamptz not null default now()
);

-- RLS: authenticated staff can access rows within schools to which they are assigned.
-- Replace the membership predicate below with your existing JengaEdu school-membership function/table.
-- Initial safe policy is creator-only; avoids exposing one school's records to another school.
do $$ declare t text; begin
 foreach t in array array['tl_lesson_attendance','tl_curriculum_items','tl_records_of_work','tl_lesson_plans','tl_teacher_reflections'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists %I on public.%I',t||'_creator_access',t);
  execute format('create policy %I on public.%I for all to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid())',t||'_creator_access',t);
 end loop;
end $$;
grant select,insert,update,delete on public.tl_lesson_attendance,public.tl_curriculum_items,public.tl_records_of_work,public.tl_lesson_plans,public.tl_teacher_reflections to authenticated;
create index if not exists tl_attendance_summary_idx on public.tl_lesson_attendance(school_id,class_name,subject,lesson_date);
create index if not exists tl_work_summary_idx on public.tl_records_of_work(school_id,class_name,subject,lesson_date);
