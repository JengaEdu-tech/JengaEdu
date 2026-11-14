-- JengaEdu: expiry controls for cross-school public library resources.
-- Existing uploads are preserved; expiry is optional and nullable.
begin;
alter table public.learning_resources add column if not exists expires_at date;
create index if not exists learning_resources_public_expiry_idx
 on public.learning_resources(expires_at) where is_published=true;
-- Public visibility must stop after expiry. School owners retain their own rows
-- so they can renew, make private, or permanently delete the resource.
drop policy if exists "Public can view approved published learning resources" on public.learning_resources;
drop policy if exists "Anyone can view published resources" on public.learning_resources;
commit;
