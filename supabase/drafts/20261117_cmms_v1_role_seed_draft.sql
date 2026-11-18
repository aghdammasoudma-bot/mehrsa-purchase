-- DRAFT ONLY — run only after base schema + hardening + authorization review in staging.
-- Uses current usernames, not hard-coded Auth UUIDs.
-- Each row is global in v1 (location_id NULL); no legacy user_profiles roles are changed.

insert into public.cmms_user_roles(user_id, role, location_id, is_active)
select up.user_id, mapping.cmms_role, null, true
from public.user_profiles up
join (
  values
    ('masoud','technical_supervisor'),
    ('biabani','responsible_manager'),
    ('reza','technical_expert'),
    ('hamid','technician')
) as mapping(username, cmms_role)
  on mapping.username = up.username
where up.is_active = true
  and not exists (
    select 1
    from public.cmms_user_roles existing
    where existing.user_id = up.user_id
      and existing.role = mapping.cmms_role
      and existing.location_id is null
  );

-- Expected mapping verification. Compare the returned rows before activating UI actions.
select up.username, r.role, r.is_active, r.location_id
from public.cmms_user_roles r
join public.user_profiles up on up.user_id = r.user_id
where up.username in ('masoud','biabani','reza','hamid')
order by up.username, r.role;

-- Explicitly no CMMS role is assigned to mohammadi or karami in v1.
