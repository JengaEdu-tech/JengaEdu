-- JengaEdu registration: create an active school immediately at Auth signup.
-- Run after multi-school-foundation.sql and multi-school-approval-migration.sql.
-- Safe for normal GitHub users: it only acts when signup metadata contains jenga_school_application=true.

create or replace function public.create_pending_school_for_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_school uuid;
  v_name text;
  v_slug text;
begin
  if coalesce(new.raw_user_meta_data->>'jenga_school_application','false') <> 'true' then
    return new;
  end if;

  v_name := trim(coalesce(new.raw_user_meta_data->>'school_name',''));
  if length(v_name) < 2 then
    raise exception 'School name is required';
  end if;

  -- Do not create duplicates if the trigger is ever retried.
  if exists (select 1 from public.school_memberships where user_id = new.id) then
    return new;
  end if;

  v_slug := lower(regexp_replace(v_name,'[^a-zA-Z0-9]+','-','g'))
            || '-' || substr(replace(gen_random_uuid()::text,'-',''),1,8);

  insert into public.schools(name, slug, school_type, county, country, status)
  values (
    v_name,
    v_slug,
    coalesce(nullif(trim(new.raw_user_meta_data->>'school_type'),''),'Comprehensive'),
    nullif(trim(new.raw_user_meta_data->>'school_county'),''),
    coalesce(nullif(trim(new.raw_user_meta_data->>'school_country'),''),'Kenya'),
    'active'
  ) returning id into v_school;

  insert into public.school_memberships(school_id, user_id, role)
  values (v_school, new.id, 'school_admin');

  return new;
end;
$$;

drop trigger if exists jenga_create_pending_school_on_signup on auth.users;
create trigger jenga_create_pending_school_on_signup
  after insert on auth.users
  for each row execute function public.create_pending_school_for_signup();
