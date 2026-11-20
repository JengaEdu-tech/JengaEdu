-- JengaEdu secure school registration and platform-owner approval workflow.
-- Run AFTER Supabase/multi-school-foundation.sql.
-- Back up the database first. This migration is repeatable.
-- Platform owner is registered in platform_admins only, never school_memberships.

BEGIN;

-- 1. Supported school application states.
ALTER TABLE public.schools
    DROP CONSTRAINT IF EXISTS schools_status_check;

ALTER TABLE public.schools
    ADD CONSTRAINT schools_status_check
    CHECK (status IN ('pending', 'active', 'suspended', 'rejected'));

-- 2. Register the platform owner. This does not create a school membership.
INSERT INTO public.platform_admins (user_id)
VALUES ('a24e261f-28ef-4584-b4a1-152bf725a774'::uuid)
ON CONFLICT (user_id) DO NOTHING;

-- 3. Authenticated users may apply for one school and become its initial admin.
CREATE OR REPLACE FUNCTION public.register_school_application(
    p_name text,
    p_school_type text,
    p_county text,
    p_country text DEFAULT 'Kenya'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_school uuid;
    v_slug text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF public.is_platform_admin() THEN
        RAISE EXCEPTION 'Platform owner accounts cannot register as school administrators';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.school_memberships
        WHERE user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'This account is already linked to a school';
    END IF;

    IF length(trim(coalesce(p_name, ''))) < 2 THEN
        RAISE EXCEPTION 'School name is required';
    END IF;

    v_slug :=
        lower(regexp_replace(trim(p_name), '[^a-zA-Z0-9]+', '-', 'g'))
        || '-'
        || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

    INSERT INTO public.schools (
        name, slug, school_type, county, country, status
    )
    VALUES (
        trim(p_name),
        v_slug,
        coalesce(nullif(trim(p_school_type), ''), 'Comprehensive'),
        nullif(trim(p_county), ''),
        coalesce(nullif(trim(p_country), ''), 'Kenya'),
        'pending'
    )
    RETURNING id INTO v_school;

    INSERT INTO public.school_memberships (school_id, user_id, role)
    VALUES (v_school, auth.uid(), 'school_admin');

    RETURN v_school;
END;
$function$;

REVOKE ALL ON FUNCTION public.register_school_application(text, text, text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_school_application(text, text, text, text)
    TO authenticated;

-- 4. Only platform administrators may approve, suspend, or reject a school.
CREATE OR REPLACE FUNCTION public.set_school_status(
    p_school_id uuid,
    p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
    IF auth.uid() IS NULL OR NOT public.is_platform_admin() THEN
        RAISE EXCEPTION 'Platform owner access required';
    END IF;

    IF p_status NOT IN ('active', 'suspended', 'rejected') THEN
        RAISE EXCEPTION 'Invalid school status';
    END IF;

    UPDATE public.schools
       SET status = p_status
     WHERE id = p_school_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'School not found';
    END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_school_status(uuid, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_school_status(uuid, text)
    TO authenticated;

-- 5. School state: platform owner can read every school's state;
--    ordinary members can read only their own active school's state.
DROP POLICY IF EXISTS "school_state_shared_select_auth"
    ON public.school_state_shared;
DROP POLICY IF EXISTS "active members read own school state"
    ON public.school_state_shared;

CREATE POLICY "active members read own school state"
ON public.school_state_shared
FOR SELECT
TO authenticated
USING (
    public.is_platform_admin()
    OR EXISTS (
        SELECT 1
        FROM public.school_memberships AS m
        JOIN public.schools AS s
          ON s.id = m.school_id
        WHERE m.user_id = auth.uid()
          AND m.school_id::text = school_state_shared.id
          AND s.status = 'active'
    )
);

-- 6. Only an active school's school_admin may create its state.
--    Platform owner is also allowed to create state for any registered school.
DROP POLICY IF EXISTS "school_state_shared_insert_auth"
    ON public.school_state_shared;
DROP POLICY IF EXISTS "active admins create own school state"
    ON public.school_state_shared;

CREATE POLICY "active admins create own school state"
ON public.school_state_shared
FOR INSERT
TO authenticated
WITH CHECK (
    public.is_platform_admin()
    OR EXISTS (
        SELECT 1
        FROM public.school_memberships AS m
        JOIN public.schools AS s
          ON s.id = m.school_id
        WHERE m.user_id = auth.uid()
          AND m.role = 'school_admin'
          AND m.school_id::text = school_state_shared.id
          AND s.status = 'active'
    )
);

-- 7. Active school members may update only their own school's state.
--    Platform owner may update any school's state.
DROP POLICY IF EXISTS "school_state_shared_update_auth"
    ON public.school_state_shared;
DROP POLICY IF EXISTS "active members update own school state"
    ON public.school_state_shared;

CREATE POLICY "active members update own school state"
ON public.school_state_shared
FOR UPDATE
TO authenticated
USING (
    public.is_platform_admin()
    OR EXISTS (
        SELECT 1
        FROM public.school_memberships AS m
        JOIN public.schools AS s
          ON s.id = m.school_id
        WHERE m.user_id = auth.uid()
          AND m.school_id::text = school_state_shared.id
          AND s.status = 'active'
    )
)
WITH CHECK (
    public.is_platform_admin()
    OR EXISTS (
        SELECT 1
        FROM public.school_memberships AS m
        JOIN public.schools AS s
          ON s.id = m.school_id
        WHERE m.user_id = auth.uid()
          AND m.school_id::text = school_state_shared.id
          AND s.status = 'active'
    )
);

-- 8. School directory: members see their own school; platform owner sees all.
DROP POLICY IF EXISTS "members view their schools" ON public.schools;

CREATE POLICY "members view their schools"
ON public.schools
FOR SELECT
TO authenticated
USING (
    public.is_platform_admin()
    OR public.is_school_member(id)
);

COMMIT;

-- Verification (run separately after the migration):
-- SELECT user_id FROM public.platform_admins
-- WHERE user_id = 'a24e261f-28ef-4584-b4a1-152bf725a774'::uuid;
--
-- The owner should appear in platform_admins and should NOT appear in
-- school_memberships unless separately and intentionally assigned by an owner.
