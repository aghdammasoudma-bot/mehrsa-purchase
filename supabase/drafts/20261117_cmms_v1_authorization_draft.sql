-- DRAFT ONLY — do not apply to production.
-- CMMS v1 read authorization layer. Depends on base schema + hardening draft.
-- All client access is read-only until audited workflow RPCs are separately implemented.
-- Keep cmms_private out of the Supabase Data API exposed schemas.
-- V1 global roles: masoud=technical_supervisor, biabani=responsible_manager,
-- reza=technical_expert, hamid=technician. Biabani approves all assets/locations.

begin;

create schema if not exists cmms_private;
revoke all on schema cmms_private from public, anon;
grant usage on schema cmms_private to authenticated;

create or replace function cmms_private.cmms_has_any_role(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and exists (select 1 from public.user_profiles up where up.user_id=auth.uid() and up.is_active)
    and exists (
    select 1
    from public.cmms_user_roles r
    where r.user_id = auth.uid()
      and r.is_active
      and r.location_id is null
      and r.role = any(p_roles)
  );
$$;

create or replace function cmms_private.cmms_has_role_at_location(p_roles text[], p_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with recursive ancestors(id) as (
    select p_location_id
    where p_location_id is not null
    union
    select l.parent_id
    from public.cmms_locations l
    join ancestors a on l.id = a.id
    where l.parent_id is not null
  )
  select auth.uid() is not null and exists (
    select 1
    from public.cmms_user_roles r
    where r.user_id = auth.uid()
      and r.is_active
      and r.role = any(p_roles)
      and (
        r.location_id is null
        or r.location_id in (select id from ancestors)
      )
  );
$$;

revoke all on function cmms_private.cmms_has_any_role(text[]) from public, anon;
revoke all on function cmms_private.cmms_has_role_at_location(text[], uuid) from public, anon;
grant execute on function cmms_private.cmms_has_any_role(text[]) to authenticated;
grant execute on function cmms_private.cmms_has_role_at_location(text[], uuid) to authenticated;

-- Role roster: users can see their own role rows; governance roles can audit all.
alter table public.cmms_user_roles enable row level security;
create policy cmms_roles_read_self_or_governance
on public.cmms_user_roles for select to authenticated
using (
  user_id = (select auth.uid())
  or (select cmms_private.cmms_has_any_role(array['technical_supervisor','responsible_manager']))
);

-- Locations and category dictionary.
create policy cmms_locations_read_scope
on public.cmms_locations for select to authenticated
using (
  (select cmms_private.cmms_has_role_at_location(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
    cmms_locations.id
  ))
);

create policy cmms_categories_read_cmms
on public.cmms_asset_categories for select to authenticated
using (
  (select cmms_private.cmms_has_any_role(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager']
  ))
);

-- Asset register.
create policy cmms_assets_read_scope
on public.cmms_assets for select to authenticated
using (
  (select cmms_private.cmms_has_role_at_location(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
    cmms_assets.location_id
  ))
);

-- Meter readings inherit access from the asset location.
create policy cmms_meter_readings_read_scope
on public.cmms_asset_meter_readings for select to authenticated
using (
  exists (
    select 1 from public.cmms_assets a
    where a.id = cmms_asset_meter_readings.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- Meter readings inherit access from their asset location.
create policy cmms_meter_readings_read_scope
on public.cmms_asset_meter_readings for select to authenticated
using (
  exists (
    select 1
    from public.cmms_assets a
    where a.id = cmms_asset_meter_readings.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- Failure reports inherit access from their asset location.
create policy cmms_failures_read_scope
on public.cmms_failure_reports for select to authenticated
using (
  exists (
    select 1
    from public.cmms_assets a
    where a.id = cmms_failure_reports.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- Work orders inherit access from their asset location.
create policy cmms_work_orders_read_scope
on public.cmms_work_orders for select to authenticated
using (
  exists (
    select 1
    from public.cmms_assets a
    where a.id = cmms_work_orders.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- Child records inherit access from the parent work order's asset location.
create policy cmms_assignments_read_scope
on public.cmms_work_order_assignments for select to authenticated
using (
  exists (
    select 1
    from public.cmms_work_orders w
    join public.cmms_assets a on a.id = w.asset_id
    where w.id = cmms_work_order_assignments.work_order_id
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

create policy cmms_actions_read_scope
on public.cmms_work_order_actions for select to authenticated
using (
  exists (
    select 1
    from public.cmms_work_orders w
    join public.cmms_assets a on a.id = w.asset_id
    where w.id = cmms_work_order_actions.work_order_id
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

create policy cmms_approvals_read_scope
on public.cmms_work_order_approvals for select to authenticated
using (
  exists (
    select 1
    from public.cmms_work_orders w
    join public.cmms_assets a on a.id = w.asset_id
    where w.id = cmms_work_order_approvals.work_order_id
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- Preventive maintenance.
create policy cmms_pm_plans_read_scope
on public.cmms_pm_plans for select to authenticated
using (
  exists (
    select 1
    from public.cmms_assets a
    where a.id = cmms_pm_plans.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

create policy cmms_pm_tasks_read_scope
on public.cmms_pm_tasks for select to authenticated
using (
  exists (
    select 1
    from public.cmms_assets a
    where a.id = cmms_pm_tasks.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

create policy cmms_asset_history_read_scope
on public.cmms_asset_status_history for select to authenticated
using (
  exists (
    select 1
    from public.cmms_assets a
    where a.id = cmms_asset_status_history.asset_id
      and (select cmms_private.cmms_has_role_at_location(
        array['technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- Audit records are visible only to the technical supervisor and responsible manager.
create policy cmms_audit_read_governance
on public.cmms_audit_logs for select to authenticated
using (
  (select cmms_private.cmms_has_any_role(array['technical_supervisor','responsible_manager']))
);

create policy cmms_purchase_links_read_scope
on public.cmms_work_order_purchase_links for select to authenticated
using (
  exists (
    select 1
    from public.cmms_work_orders w
    join public.cmms_assets a on a.id = w.asset_id
    where w.id = cmms_work_order_purchase_links.work_order_id
      and (select cmms_private.cmms_has_role_at_location(
        array['technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
  )
);

-- No anonymous access. No direct client writes. RLS remains the row-level gate.
revoke all on table
  public.cmms_locations,
  public.cmms_asset_categories,
  public.cmms_assets,
  public.cmms_asset_meter_readings,
  public.cmms_user_roles,
  public.cmms_failure_reports,
  public.cmms_work_orders,
  public.cmms_work_order_assignments,
  public.cmms_work_order_actions,
  public.cmms_work_order_approvals,
  public.cmms_pm_plans,
  public.cmms_pm_tasks,
  public.cmms_asset_status_history,
  public.cmms_audit_logs,
  public.cmms_work_order_purchase_links
from public, anon, authenticated;

grant select on table
  public.cmms_locations,
  public.cmms_asset_categories,
  public.cmms_assets,
  public.cmms_asset_meter_readings,
  public.cmms_user_roles,
  public.cmms_failure_reports,
  public.cmms_work_orders,
  public.cmms_work_order_assignments,
  public.cmms_work_order_actions,
  public.cmms_work_order_approvals,
  public.cmms_pm_plans,
  public.cmms_pm_tasks,
  public.cmms_asset_status_history,
  public.cmms_audit_logs,
  public.cmms_work_order_purchase_links
to authenticated;

commit;

-- Write operations remain intentionally unavailable until each workflow has a
-- separate, audited RPC and role-specific tests. Never solve this by granting
-- broad table-level UPDATE/DELETE to authenticated users.
