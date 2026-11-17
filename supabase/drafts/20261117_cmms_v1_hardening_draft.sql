-- DRAFT ONLY — additive CMMS v1 hardening layer.
-- NOT APPLIED. Requires review, external restorable backup, and staging tests.
-- PostgreSQL 17 target. No changes to purchase workflow or legacy tables.

-- 1) Correct NULL-scope uniqueness for role assignments.
alter table public.cmms_user_roles drop constraint if exists cmms_user_roles_user_id_role_location_id_key;
create unique index if not exists cmms_user_roles_global_role_uq
  on public.cmms_user_roles(user_id, role) where location_id is null;
create unique index if not exists cmms_user_roles_scoped_role_uq
  on public.cmms_user_roles(user_id, role, location_id) where location_id is not null;

-- 2) Only one active assignment for a user on a work order; retain history.
create unique index if not exists cmms_one_active_assignment_uq
  on public.cmms_work_order_assignments(work_order_id, user_id)
  where unassigned_at is null;

-- 3) Query support.
create index if not exists cmms_approvals_order_stage_time_idx
  on public.cmms_work_order_approvals(work_order_id, stage, decided_at desc);
create index if not exists cmms_failure_reports_reporter_time_idx
  on public.cmms_failure_reports(reported_by, created_at desc);
create index if not exists cmms_pm_plans_due_idx
  on public.cmms_pm_plans(is_active, next_due_at);

-- 4) Hierarchical location cycle protection.
create or replace function public.cmms_guard_location_hierarchy()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  cycle_found boolean;
begin
  if new.parent_id is null then
    return new;
  end if;
  if new.parent_id = new.id then
    raise exception 'A location cannot be its own parent';
  end if;

  with recursive descendants(id) as (
    select l.id from public.cmms_locations l where l.id = new.id
    union all
    select child.id
    from public.cmms_locations child
    join descendants d on child.parent_id = d.id
  )
  select exists(select 1 from descendants where id = new.parent_id)
    into cycle_found;

  if cycle_found then
    raise exception 'Location hierarchy cycle detected';
  end if;
  return new;
end;
$$;

drop trigger if exists cmms_locations_hierarchy_guard on public.cmms_locations;
create trigger cmms_locations_hierarchy_guard
before insert or update of parent_id on public.cmms_locations
for each row execute function public.cmms_guard_location_hierarchy();

-- 5) PM completion must have executor, timestamp and checklist result.
alter table public.cmms_pm_tasks
  drop constraint if exists cmms_pm_completion_integrity;
alter table public.cmms_pm_tasks
  add constraint cmms_pm_completion_integrity check (
    (status <> 'completed')
    or (
      completed_by is not null
      and completed_at is not null
      and checklist_result is not null
      and jsonb_typeof(checklist_result) in ('object','array')
    )
  );

-- 6) Approval identity and stage-order guard. Decisions remain append-only history.
create or replace function public.cmms_guard_work_order_approval()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  wo public.cmms_work_orders%rowtype;
  prior_supervisor uuid;
  latest_supervisor_decision text;
  latest_manager_decision text;
begin
  select * into wo
  from public.cmms_work_orders
  where id = new.work_order_id
  for update;

  if not found then
    raise exception 'Work order not found';
  end if;

  if new.approver_id = wo.opened_by then
    raise exception 'Work-order creator cannot approve their own work order';
  end if;

  if exists (
    select 1 from public.cmms_work_order_assignments a
    where a.work_order_id = new.work_order_id
      and a.user_id = new.approver_id
  ) then
    raise exception 'Assigned worker cannot approve the same work order';
  end if;

  if new.stage = 'responsible_manager' then
    select a.approver_id, a.decision into prior_supervisor, latest_supervisor_decision
    from public.cmms_work_order_approvals a
    where a.work_order_id = new.work_order_id
      and a.stage = 'technical_supervisor'
    order by a.decided_at desc, a.id desc
    limit 1;

    if prior_supervisor is null or latest_supervisor_decision <> 'approved' then
      raise exception 'Latest technical supervisor decision must be approved first';
    end if;
    if prior_supervisor = new.approver_id then
      raise exception 'The two approval stages require different people';
    end if;
  elsif new.stage = 'technical_supervisor' then
    select a.approver_id, a.decision into prior_supervisor, latest_manager_decision
    from public.cmms_work_order_approvals a
    where a.work_order_id = new.work_order_id
      and a.stage = 'responsible_manager'
    order by a.decided_at desc, a.id desc
    limit 1;
    if latest_manager_decision = 'approved' and prior_supervisor = new.approver_id then
      raise exception 'The two approval stages require different people';
    end if;
  end if;

  if new.decision = 'rejected' and nullif(btrim(coalesce(new.note,'')), '') is null then
    raise exception 'A rejection reason is mandatory';
  end if;
  return new;
end;
$$;

drop trigger if exists cmms_work_order_approval_guard on public.cmms_work_order_approvals;
create trigger cmms_work_order_approval_guard
before insert on public.cmms_work_order_approvals
for each row execute function public.cmms_guard_work_order_approval();

-- 7) Append-only protections for audit and approval history.
create or replace function public.cmms_reject_history_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'CMMS history records are append-only';
end;
$$;

drop trigger if exists cmms_audit_no_mutation on public.cmms_audit_logs;
create trigger cmms_audit_no_mutation
before update or delete on public.cmms_audit_logs
for each row execute function public.cmms_reject_history_mutation();

drop trigger if exists cmms_approval_no_mutation on public.cmms_work_order_approvals;
create trigger cmms_approval_no_mutation
before update or delete on public.cmms_work_order_approvals
for each row execute function public.cmms_reject_history_mutation();

-- 8) Asset status history is generated in the same transaction as a status change.
create or replace function public.cmms_record_asset_status_change()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.operational_status is distinct from old.operational_status then
    insert into public.cmms_asset_status_history
      (asset_id, old_status, new_status, changed_by, reason)
    values
      (new.id, old.operational_status, new.operational_status, auth.uid(),
       'Automatic status-change history');
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists cmms_assets_status_history on public.cmms_assets;
create trigger cmms_assets_status_history
before update on public.cmms_assets
for each row execute function public.cmms_record_asset_status_change();

-- 9) No grants or RLS policies are added here. Authorization must be implemented
-- via reviewed role/location predicates and narrowly-scoped server-side RPCs.
-- Do not expose these tables through the Data API until grants + RLS tests pass.
