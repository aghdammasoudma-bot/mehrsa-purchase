-- DRAFT ONLY — do not apply to production.
-- CMMS v1 authorization layer. Depends on the base schema draft.
-- Design: authenticated users get read-only table access through RLS.
-- State-changing operations must be implemented as narrow, audited RPCs.
-- Do not expose schema "cmms_private" through the Supabase Data API.

create schema if not exists cmms_private;
revoke all on schema cmms_private from public, anon;
grant usage on schema cmms_private to authenticated;

create or replace function cmms_private.cmms_has_any_role(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth, cmms_private
as $$
  select auth.uid() is not null and exists (
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
set search_path = pg_catalog, public, auth, cmms_private
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

-- Role assignments are private: users can read their own; global supervisors/managers
-- can audit the role roster. No direct client-side role changes.
alter table public.cmms_user_roles enable row level security;
create policy cmms_roles_read_self_or_governance
on public.cmms_user_roles for select to authenticated
using (
  user_id = (select auth.uid())
  or cmms_private.cmms_has_any_role(array['technical_supervisor','responsible_manager'])
);

-- Locations and category dictionary.
create policy cmms_locations_read_scope
on public.cmms_locations for select to authenticated
using (cmms_private.cmms_has_role_at_location(
  array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
  id
));
create policy cmms_categories_read_cmms
on public.cmms_asset_categories for select to authenticated
using (cmms_private.cmms_has_any_role(
  array['reporter','technician','technical_expert','technical_supervisor','responsible_manager']
));

-- Assets.
create policy cmms_assets_read_scope
on public.cmms_assets for select to authenticated
using (cmms_private.cmms_has_role_at_location(
  array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
  location_id
));

-- Failure reports: read within permitted asset location.
create policy cmms_failures_read_scope
on public.cmms_failure_reports for select to authenticated
using (exists (
  select 1 from public.cmms_assets a
  where a.id = asset_id
    and cmms_private.cmms_has_role_at_location(
      array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

-- Work orders.
create policy cmms_work_orders_read_scope
on public.cmms_work_orders for select to authenticated
using (exists (
  select 1 from public.cmms_assets a
  where a.id = asset_id
    and cmms_private.cmms_has_role_at_location(
      array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

-- Child records inherit access from the parent work order's asset location.
create policy cmms_assignments_read_scope
on public.cmms_work_order_assignments for select to authenticated
using (exists (
  select 1 from public.cmms_work_orders w
  join public.cmms_assets a on a.id = w.asset_id
  where w.id = work_order_id
    and cmms_private.cmms_has_role_at_location(
      array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

create policy cmms_actions_read_scope
on public.cmms_work_order_actions for select to authenticated
using (exists (
  select 1 from public.cmms_work_orders w
  join public.cmms_assets a on a.id = w.asset_id
  where w.id = work_order_id
    and cmms_private.cmms_has_role_at_location(
      array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

create policy cmms_approvals_read_scope
on public.cmms_work_order_approvals for select to authenticated
using (exists (
  select 1 from public.cmms_work_orders w
  join public.cmms_assets a on a.id = w.asset_id
  where w.id = work_order_id
    and cmms_private.cmms_has_role_at_location(
      array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

-- PM records.
create policy cmms_pm_plans_read_scope
on public.cmms_pm_plans for select to authenticated
using (exists (
  select 1 from public.cmms_assets a
  where a.id = asset_id
    and cmms_private.cmms_has_role_at_location(
      array['technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

create policy cmms_pm_tasks_read_scope
on public.cmms_pm_tasks for select to authenticated
using (exists (
  select 1 from public.cmms_assets a
  where a.id = asset_id
    and cmms_private.cmms_has_role_at_location(
      array['technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

create policy cmms_asset_history_read_scope
on public.cmms_asset_status_history for select to authenticated
using (exists (
  select 1 from public.cmms_assets a
  where a.id = asset_id
    and cmms_private.cmms_has_role_at_location(
      array['technician','technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

-- Audit is restricted to the two governance roles.
create policy cmms_audit_read_governance
on public.cmms_audit_logs for select to authenticated
using (cmms_private.cmms_has_any_role(array['technical_supervisor','responsible_manager']));

create policy cmms_purchase_links_read_scope
on public.cmms_work_order_purchase_links for select to authenticated
using (exists (
  select 1 from public.cmms_work_orders w
  join public.cmms_assets a on a.id = w.asset_id
  where w.id = work_order_id
    and cmms_private.cmms_has_role_at_location(
      array['technical_expert','technical_supervisor','responsible_manager'],
      a.location_id
    )
));

-- Explicit least-privilege grants. No direct INSERT/UPDATE/DELETE from clients.
revoke all on table
  public.cmms_locations,
  public.cmms_asset_categories,
  public.cmms_assets,
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

-- Add narrowly-scoped RPCs before granting any client write privileges.
-- RPCs must validate auth.uid(), role, location, state transition, assignment,
-- approval stage, and audit details; SECURITY DEFINER functions must set a fixed
-- search_path, be owned by a trusted role, and have EXECUTE revoked from PUBLIC/anon.
