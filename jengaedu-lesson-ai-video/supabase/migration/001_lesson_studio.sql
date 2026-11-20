-- JengaEdu AI Lesson Studio: run in the Supabase SQL editor.
create extension if not exists pgcrypto;

create table if not exists public.lesson_studio_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  school_id uuid not null,
  role text not null check (role in ('teacher','administrator')),
  created_at timestamptz not null default now()
);

create table if not exists public.lesson_curriculum_records (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null,
  education_level text not null,
  grade text not null,
  learning_area text not null,
  strand text not null,
  sub_strand text,
  learning_outcomes jsonb not null default '[]'::jsonb,
  learning_experiences jsonb not null default '[]'::jsonb,
  assessment_guidance jsonb not null default '[]'::jsonb,
  source_title text not null,
  source_version text,
  source_page text,
  verified_by uuid references auth.users(id),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.lesson_video_projects (
  id uuid primary key default gen_random_uuid(),
  school_id uuid,
  teacher_id uuid not null references auth.users(id) on delete cascade,
  details jsonb not null,
  content jsonb not null,
  status text not null default 'draft' check (status in ('draft','queued','rendering','ready','failed')),
  video_url text,
  provider_job_id text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists lesson_projects_teacher_idx on public.lesson_video_projects(teacher_id, created_at desc);
create index if not exists lesson_curriculum_school_idx on public.lesson_curriculum_records(school_id, education_level, grade, learning_area);

alter table public.lesson_studio_members enable row level security;
alter table public.lesson_curriculum_records enable row level security;
alter table public.lesson_video_projects enable row level security;

create or replace function public.lesson_studio_school_id()
returns uuid language sql stable security definer set search_path=public
as $$ select school_id from public.lesson_studio_members where user_id=auth.uid() $$;

create or replace function public.lesson_studio_role()
returns text language sql stable security definer set search_path=public
as $$ select role from public.lesson_studio_members where user_id=auth.uid() $$;

create policy "members read own membership" on public.lesson_studio_members
for select to authenticated using (user_id=auth.uid());

create policy "school members read verified curriculum" on public.lesson_curriculum_records
for select to authenticated using (school_id=public.lesson_studio_school_id());

create policy "administrators manage curriculum" on public.lesson_curriculum_records
for all to authenticated using (school_id=public.lesson_studio_school_id() and public.lesson_studio_role()='administrator')
with check (school_id=public.lesson_studio_school_id() and public.lesson_studio_role()='administrator');

create policy "teachers and admins read school projects" on public.lesson_video_projects
for select to authenticated using (school_id=public.lesson_studio_school_id());

create policy "teachers create own projects" on public.lesson_video_projects
for insert to authenticated with check (
  teacher_id=auth.uid() and school_id=public.lesson_studio_school_id()
  and public.lesson_studio_role() in ('teacher','administrator')
);

create policy "owners and admins update projects" on public.lesson_video_projects
for update to authenticated using (
  school_id=public.lesson_studio_school_id() and
  (teacher_id=auth.uid() or public.lesson_studio_role()='administrator')
) with check (
  school_id=public.lesson_studio_school_id() and
  (teacher_id=auth.uid() or public.lesson_studio_role()='administrator')
);

-- Storage bucket for rendered lesson videos. Create via Dashboard or storage API:
-- bucket name: lesson-videos, private=true. Add school-scoped policies before production.
