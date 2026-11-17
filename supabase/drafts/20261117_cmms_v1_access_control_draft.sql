-- DRAFT ONLY — CMMS V1 access-control and least-privilege grants.
-- NOT APPLIED. Requires verified external backup, staging database and full RLS tests.
-- V1 decision: Biabani is the final responsible-manager approver for ALL equipment.
-- Global technical scope for the four approved CMMS users; no planner/procurement access.
-- Public tables are NOT automatically exposed by Supabase after 2026-10-30:
-- explicitly grant only the required privileges after reviewing Data API settings.

begin;

create schema if not exists cmms_private;
revoke all on schema cmms_private from public, anon;
grant usage on schema cmms_private to authenticated;

-- Authorization helpers are outside the exposed public API schema.
create or replace function cmms_private.user_has_role(p_user_id uuid, p_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cmms_user_roles ur
    where ur.user_id = p_user_id
      and ur.role = p_role
      and ur.is_active
      and ur.location_id is null
  );
$$;

create or replace function cmms_private.has_role(p_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select cmms_private.user_has_role(auth.uid(), p_role);
$$;

create or replace function cmms_private.has_any_role(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cmms_user_roles ur
    where ur.user_id = auth.uid()
      and ur.role = any(p_roles)
      and ur.is_active
      and ur.location_id is null
  );
$$;

revoke all on function cmms_private.user_has_role(uuid,text) from public, anon;
revoke all on function cmms_private.has_role(text) from public, anon;
revoke all on function cmms_private.has_any_role(text[]) from public, anon;
grant execute on function cmms_private.user_has_role(uuid,text) to authenticated;
grant execute on function cmms_private.has_role(text) to authenticated;
grant execute on function cmms_private.has_any_role(text[]) to authenticated;

-- Seed only the exact four users confirmed for CMMS V1.
-- This leaves legacy user_profiles roles unchanged.
do $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.user_profiles
  where is_active
    and username in ('masoud','biabani','reza','hamid');

  if v_count <> 4 then
    raise exception 'Expected exactly four active CMMS users; found %', v_count;
  end if;
end;
$$;

insert into public.cmms_user_roles(user_id, role, location_id, is_active)
select
  up.user_id,
  case up.username
    when 'masoud' then 'technical_supervisor'
    when 'biabani' then 'responsible_manager'
    when 'reza' then 'technical_expert'
    when 'hamid' then 'technician'
  end,
  null,
  true
from public.user_profiles up
where up.is_active
  and up.username in ('masoud','biabani','reza','hamid')
on conflict do nothing;

-- Explicit grants: no access for anon; no direct role-table access.
grant select on
  public.cmms_locations,
  public.cmms_asset_categories,
  public.cmms_assets,
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

grant insert, update on
  public.cmms_locations,
  public.cmms_asset_categories,
  public.cmms_assets,
  public.cmms_pm_plans
to authenticated;

grant insert on public.cmms_failure_reports to authenticated;
grant update (status, reviewed_by, reviewed_at, review_note)
on public.cmms_failure_reports to authenticated;

grant insert on
  public.cmms_work_orders,
  public.cmms_work_order_assignments,
  public.cmms_work_order_actions,
  public.cmms_work_order_approvals,
  public.cmms_work_order_purchase_links
to authenticated;

grant usage, select on sequence
  public.cmms_failure_reports_report_no_seq,
  public.cmms_work_orders_wo_no_seq
to authenticated;

-- No direct UPDATE/DELETE grants on work-order state, approvals, assignments,
-- action history, PM tasks, asset history, or audit logs. Controlled RPCs are
-- a separate implementation step; current direct privileges remain deny-by-default.

-- Read access: all four CMMS roles can see the technical-department CMMS data.
create policy cmms_locations_read on public.cmms_locations
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_categories_read on public.cmms_asset_categories
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_assets_read on public.cmms_assets
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_failures_read on public.cmms_failure_reports
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_work_orders_read on public.cmms_work_orders
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_assignments_read on public.cmms_work_order_assignments
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_actions_read on public.cmms_work_order_actions
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_approvals_read on public.cmms_work_order_approvals
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_pm_plans_read on public.cmms_pm_plans
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_pm_tasks_read on public.cmms_pm_tasks
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_asset_history_read on public.cmms_asset_status_history
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

create policy cmms_audit_read on public.cmms_audit_logs
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager'])));

create policy cmms_purchase_links_read on public.cmms_work_order_purchase_links
for select to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','responsible_manager','technical_expert','technician'])));

-- Master data writes: technical supervisor and technical expert only.
create policy cmms_locations_write on public.cmms_locations
for all to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])))
with check ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])));

create policy cmms_categories_write on public.cmms_asset_categories
for all to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])))
with check ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])));

create policy cmms_assets_write on public.cmms_assets
for all to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])))
with check ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])));

create policy cmms_failures_insert on public.cmms_failure_reports
for insert to authenticated
with check (
  reported_by = (select auth.uid())
  and (select cmms_private.has_any_role(array['technical_supervisor','technical_expert','technician']))
);

create policy cmms_failures_review on public.cmms_failure_reports
for update to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])))
with check (
  (select cmms_private.has_any_role(array['technical_supervisor','technical_expert']))
  and (reviewed_by is null or reviewed_by = (select auth.uid()))
  and (reviewed_at is null or reviewed_at <= now())
);

create policy cmms_work_orders_insert on public.cmms_work_orders
for insert to authenticated
with check (
  opened_by = (select auth.uid())
  and status = 'triage'
  and (select cmms_private.has_any_role(array['technical_supervisor','technical_expert']))
);

create policy cmms_assignments_insert on public.cmms_work_order_assignments
for insert to authenticated
with check (
  assigned_by = (select auth.uid())
  and (select cmms_private.has_any_role(array['technical_supervisor','technical_expert']))
  and (
    (select cmms_private.user_has_role(user_id,'technician'))
    or (select cmms_private.user_has_role(user_id,'technical_expert'))
  )
);

create policy cmms_actions_insert on public.cmms_work_order_actions
for insert to authenticated
with check (
  actor_id = (select auth.uid())
  and (
    (select cmms_private.has_any_role(array['technical_supervisor','technical_expert']))
    or exists (
      select 1 from public.cmms_work_order_assignments wa
      where wa.work_order_id = cmms_work_order_actions.work_order_id
        and wa.user_id = (select auth.uid())
        and wa.unassigned_at is null
    )
  )
);

create policy cmms_approvals_insert on public.cmms_work_order_approvals
for insert to authenticated
with check (approver_id = (select auth.uid()));

create policy cmms_pm_plans_write on public.cmms_pm_plans
for all to authenticated
using ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])))
with check ((select cmms_private.has_any_role(array['technical_supervisor','technical_expert'])));

create policy cmms_purchase_links_insert on public.cmms_work_order_purchase_links
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select cmms_private.has_any_role(array['technical_supervisor','technical_expert']))
);

commit;

-- Explicitly absent by design:
-- * no anon grants or policies;
-- * no direct SELECT/INSERT/UPDATE on cmms_user_roles;
-- * no direct UPDATE/DELETE on approvals, work-order state, PM tasks or audit history;
-- * no delete permissions on assets, locations, plans or purchase links;
-- * no grants to planner/procurement.
-- The application must not enable write controls for any workflow operation that
-- lacks its own tested server-side transition function and audit event.
