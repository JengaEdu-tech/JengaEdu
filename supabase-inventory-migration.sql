-- JengaEdu inventory migration: platform-owner aware, repeatable and school-isolated.
-- Prerequisite: run Supabase/multi-school-foundation.sql first.
-- The supplied Auth UID is a PLATFORM OWNER. It is NOT inserted into school_memberships.
-- Existing inventory rows are preserved; this script only creates tables/policies and owner grant.

insert into public.platform_admins(user_id)
values ('a24e261f-28ef-4584-b4a1-152bf725a774'::uuid)
on conflict (user_id) do nothing;

create table if not exists public.inventory_suppliers (id uuid primary key default gen_random_uuid(), school_id text not null, name text not null, phone text, email text, created_at timestamptz default now(), unique(school_id,name));
create table if not exists public.book_categories (id uuid primary key default gen_random_uuid(), school_id text not null, name text not null, unique(school_id,name));
create table if not exists public.book_catalogue (id uuid primary key default gen_random_uuid(), school_id text not null, title text not null, category_id uuid references public.book_categories(id), subject text, grade text, author text, publisher text, isbn text, edition text, publication_year integer, storage_location text, created_at timestamptz default now());
create table if not exists public.book_purchases (id uuid primary key default gen_random_uuid(), school_id text not null, book_id uuid not null references public.book_catalogue(id), quantity integer not null check(quantity>0), unit_price numeric(12,2) not null check(unit_price>=0), total_cost numeric(14,2) generated always as (quantity*unit_price) stored, supplier_id uuid references public.inventory_suppliers(id), purchased_on date not null, funding_source text, created_at timestamptz default now());
create table if not exists public.class_book_inventory (id uuid primary key default gen_random_uuid(), school_id text not null, academic_year text not null, class_name text not null, stream text not null default '', subject text, book_id uuid not null references public.book_catalogue(id), quantity integer not null check(quantity>=0), unique(school_id,academic_year,class_name,stream,book_id));
create table if not exists public.book_issues (id uuid primary key default gen_random_uuid(), school_id text not null, learner_admission text not null, book_id uuid not null references public.book_catalogue(id), issued_on date not null default current_date, expected_return_on date, returned_on date, condition text, status text not null default 'issued' check(status in ('issued','returned','lost','damaged')), staff_id uuid, created_at timestamptz default now());
create table if not exists public.inventory_transactions (id uuid primary key default gen_random_uuid(), school_id text not null, item_type text not null, item_id text not null, transaction_type text not null, quantity numeric not null, reference_id text, metadata jsonb not null default '{}'::jsonb, created_at timestamptz default now());
create table if not exists public.stationery_categories (id uuid primary key default gen_random_uuid(), school_id text not null, name text not null, unique(school_id,name));
create table if not exists public.stationery_items (id uuid primary key default gen_random_uuid(), school_id text not null, name text not null, category_id uuid references public.stationery_categories(id), description text, unit text not null default 'units', storage_location text, minimum_stock numeric not null default 0, unique(school_id,name));
create table if not exists public.stationery_purchases (id uuid primary key default gen_random_uuid(), school_id text not null, item_id uuid not null references public.stationery_items(id), quantity numeric not null check(quantity>0), unit_price numeric(12,2) not null check(unit_price>=0), supplier_id uuid references public.inventory_suppliers(id), purchased_on date not null, created_at timestamptz default now());
create table if not exists public.stationery_issuance (id uuid primary key default gen_random_uuid(), school_id text not null, item_id uuid not null references public.stationery_items(id), quantity numeric not null check(quantity>0), recipient text not null, purpose text, authorising_officer text, issued_on date not null default current_date, created_at timestamptz default now());
create table if not exists public.stock_adjustments (id uuid primary key default gen_random_uuid(), school_id text not null, item_type text not null, item_id text not null, quantity_change numeric not null, reason text not null, approved_by text, created_at timestamptz default now());
create table if not exists public.reorder_levels (id uuid primary key default gen_random_uuid(), school_id text not null, item_type text not null, item_id text not null, minimum_quantity numeric not null check(minimum_quantity>=0), unique(school_id,item_type,item_id));

do $$
declare t text;
  tables text[] := array['inventory_suppliers','book_categories','book_catalogue','book_purchases','class_book_inventory','book_issues','inventory_transactions','stationery_categories','stationery_items','stationery_purchases','stationery_issuance','stock_adjustments','reorder_levels'];
begin
 foreach t in array tables loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists %I on public.%I',t||'_school_scope',t);
  execute format('create policy %I on public.%I for all to authenticated using (public.is_platform_admin() OR exists (select 1 from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and m.school_id::text=%I.school_id and s.status=''active'')) with check (public.is_platform_admin() OR exists (select 1 from public.school_memberships m join public.schools s on s.id=m.school_id where m.user_id=auth.uid() and m.school_id::text=%I.school_id and s.status=''active''))',t||'_school_scope',t,t,t);
 end loop;
end $$;
