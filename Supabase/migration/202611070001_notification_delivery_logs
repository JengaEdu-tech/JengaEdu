-- Normalize the shared-state technical identifier for the JengaEdu platform.
-- Safe to run repeatedly; does not delete or rewrite the JSONB school data.
do $$
declare
  legacy_id text := convert_from(decode('4b41504e414e4441','hex'),'UTF8');
begin
  if to_regclass('public.school_state_shared') is not null then
    if exists (select 1 from public.school_state_shared where id = legacy_id)
       and not exists (select 1 from public.school_state_shared where id = 'JENGAEDU') then
      update public.school_state_shared set id = 'JENGAEDU' where id = legacy_id;
    end if;
  end if;
end $$;
