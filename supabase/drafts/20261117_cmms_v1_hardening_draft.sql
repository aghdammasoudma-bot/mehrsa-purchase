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

-- A failure report may have only one active originating work order at a time.
create unique index if not exists cmms_one_active_work_order_per_failure_uq
  on public.cmms_work_orders(failure_report_id)
  where failure_report_id is not null and status not in ('closed','cancelled');

-- 3) Query support.
create index if not exists cmms_approvals_order_stage_time_idx
  on public.cmms_work_order_approvals(work_order_id, stage, decided_at desc);
create index if not exists cmms_failure_reports_reporter_time_idx
  on public.cmms_failure_reports(reported_by, created_at desc);
create index if not exists cmms_meter_readings_asset_time_idx on public.cmms_asset_meter_readings(asset_id,meter_code,reading_at desc);
create index if not exists cmms_pm_plans_due_idx
  on public.cmms_pm_plans(is_active, next_due_at);

-- 4) Hierarchical location cycle protection.
-- UNION (not UNION ALL) prevents infinite recursion if legacy bad data exists.
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
    union
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

-- 5) PM completion must have executor, timestamp and a structured checklist result.
alter table public.cmms_pm_tasks
  drop constraint if exists cmms_pm_completion_integrity;
alter table public.cmms_pm_tasks
  add constraint cmms_pm_completion_integrity check (
    (status <> 'completed')
    or (
      completed_by is not null
      and completed_at is not null
      and checklist_result is not null
      and (
        (jsonb_typeof(checklist_result) = 'array' and jsonb_array_length(checklist_result) > 0)
        or (jsonb_typeof(checklist_result) = 'object' and checklist_result <> '{}'::jsonb)
      )
    )
  );

-- 5b) A closed work order must have an explicit return-to-service decision,
-- successful test and both distinct, timestamped approvals.
alter table public.cmms_work_orders
  drop constraint if exists cmms_work_order_closeout_integrity;
alter table public.cmms_work_orders
  add constraint cmms_work_order_closeout_integrity check (
    (status = 'closed') = (closed_at is not null)
    and (
      status <> 'closed'
      or (
        test_result = 'passed'
        and return_to_service_status in ('returned','not_required')
        and (return_to_service_status <> 'returned' or returned_to_service_at is not null)
        and supervisor_approved_by is not null
        and supervisor_approved_at is not null
        and manager_approved_by is not null
        and manager_approved_at is not null
        and supervisor_approved_by <> manager_approved_by
      )
    )
  );

alter table public.cmms_work_orders
  drop constraint if exists cmms_work_order_approval_timestamp_integrity;
alter table public.cmms_work_orders
  add constraint cmms_work_order_approval_timestamp_integrity check (
    (supervisor_approved_by is null) = (supervisor_approved_at is null)
    and (manager_approved_by is null) = (manager_approved_at is null)
    and (manager_approved_by is null or supervisor_approved_by is not null)
  );

-- 6) Enforce approval identity, stage, role and work-order readiness in the database.
-- Trigger-only SECURITY DEFINER functions are revoked from all API roles below.
create or replace function public.cmms_guard_work_order_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_prior_supervisor uuid;
  v_prior_decision text;
  v_required_role text;
begin
  if auth.uid() is null or new.approver_id is distinct from auth.uid() then
    raise exception 'Approval identity must match the authenticated user';
  end if;

  select wo.* into v_wo
  from public.cmms_work_orders wo
  where wo.id = new.work_order_id
  for update;

  if not found then
    raise exception 'Work order not found';
  end if;

  if new.approver_id = v_wo.opened_by then
    raise exception 'Work-order creator cannot approve their own work order';
  end if;

  if exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id = new.work_order_id
      and wa.user_id = new.approver_id
  ) then
    raise exception 'A person assigned to this work order cannot approve it';
  end if;

  if v_wo.test_result is distinct from 'passed'
     or v_wo.return_to_service_status not in ('returned','not_required')
     or (v_wo.return_to_service_status = 'returned' and v_wo.returned_to_service_at is null) then
    raise exception 'Successful test and explicit return-to-service decision are required';
  end if;

  if new.stage = 'technical_supervisor' then
    v_required_role := 'technical_supervisor';
    if v_wo.status <> 'pending_supervisor_approval' then
      raise exception 'Work order is not waiting for technical supervisor approval';
    end if;
  elsif new.stage = 'responsible_manager' then
    v_required_role := 'responsible_manager';
    if v_wo.status <> 'pending_manager_approval' then
      raise exception 'Work order is not waiting for responsible manager approval';
    end if;

    select ap.approver_id, ap.decision
      into v_prior_supervisor, v_prior_decision
    from public.cmms_work_order_approvals ap
    where ap.work_order_id = new.work_order_id
      and ap.stage = 'technical_supervisor'
    order by ap.decided_at desc, ap.id desc
    limit 1;

    if v_prior_decision is distinct from 'approved' then
      raise exception 'Latest technical supervisor decision must be approved first';
    end if;
    if v_prior_supervisor = new.approver_id then
      raise exception 'The two approval stages require different people';
    end if;
  else
    raise exception 'Unknown approval stage';
  end if;

  if not exists (
    select 1
    from public.cmms_user_roles ur
    where ur.user_id = new.approver_id
      and ur.role = v_required_role
      and ur.is_active
      and ur.location_id is null
  ) then
    raise exception 'User does not hold the required CMMS approval role';
  end if;

  if new.decision = 'rejected'
     and nullif(btrim(coalesce(new.note,'')), '') is null then
    raise exception 'A rejection reason is mandatory';
  end if;

  return new;
end;
$$;

drop trigger if exists cmms_work_order_approval_guard on public.cmms_work_order_approvals;
create trigger cmms_work_order_approval_guard
before insert on public.cmms_work_order_approvals
for each row execute function public.cmms_guard_work_order_approval();

-- 6b) Approval history is authoritative; denormalized columns are synchronized
-- only by this trigger. Rejection returns the order to rework and clears current approvals.
create or replace function public.cmms_apply_work_order_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.stage = 'technical_supervisor' and new.decision = 'approved' then
    update public.cmms_work_orders
    set supervisor_approved_by = new.approver_id,
        supervisor_approved_at = new.decided_at,
        manager_approved_by = null,
        manager_approved_at = null,
        status = 'pending_manager_approval',
        updated_at = now()
    where id = new.work_order_id;
  elsif new.stage = 'responsible_manager' and new.decision = 'approved' then
    update public.cmms_work_orders
    set manager_approved_by = new.approver_id,
        manager_approved_at = new.decided_at,
        status = 'closed',
        closed_at = now(),
        updated_at = now()
    where id = new.work_order_id;
  else
    update public.cmms_work_orders
    set supervisor_approved_by = null,
        supervisor_approved_at = null,
        manager_approved_by = null,
        manager_approved_at = null,
        status = 'rework',
        closed_at = null,
        updated_at = now()
    where id = new.work_order_id;
  end if;
  return new;
end;
$$;

drop trigger if exists cmms_apply_work_order_approval on public.cmms_work_order_approvals;
create trigger cmms_apply_work_order_approval
after insert on public.cmms_work_order_approvals
for each row execute function public.cmms_apply_work_order_approval();

-- 6c) Prevent direct status changes from skipping approval gates.
create or replace function public.cmms_guard_work_order_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_supervisor public.cmms_work_order_approvals%rowtype;
  v_manager public.cmms_work_order_approvals%rowtype;
  v_latest_rejection public.cmms_work_order_approvals%rowtype;
  v_is_governance boolean;
  v_is_assigned boolean;
  v_transition_allowed boolean := false;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  select exists (
    select 1 from public.cmms_user_roles ur
    where ur.user_id=auth.uid()
      and ur.is_active
      and ur.location_id is null
      and ur.role in ('technical_supervisor','technical_expert')
  ) into v_is_governance;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=new.id
      and wa.user_id=auth.uid()
      and wa.unassigned_at is null
  ) into v_is_assigned;

  -- Approval-trigger transitions are allowed only when the latest decision is current.
  if new.status in ('pending_manager_approval','closed') then
    select ap.* into v_supervisor
    from public.cmms_work_order_approvals ap
    where ap.work_order_id=new.id and ap.stage='technical_supervisor'
    order by ap.decided_at desc, ap.id desc limit 1;

    if v_supervisor.decision is distinct from 'approved'
       or new.supervisor_approved_by is distinct from v_supervisor.approver_id then
      raise exception 'Current technical supervisor approval is required';
    end if;
    if new.status='pending_manager_approval' then
      if old.status <> 'pending_supervisor_approval'
         or v_supervisor.approver_id is distinct from auth.uid() then
        raise exception 'Only the current technical supervisor decision may advance the order';
      end if;
      return new;
    end if;
  end if;

  if new.status='closed' then
    select ap.* into v_manager
    from public.cmms_work_order_approvals ap
    where ap.work_order_id=new.id and ap.stage='responsible_manager'
    order by ap.decided_at desc, ap.id desc limit 1;

    if old.status <> 'pending_manager_approval'
       or v_manager.approver_id is distinct from auth.uid()
       or v_manager.decision is distinct from 'approved'
       or new.manager_approved_by is distinct from v_manager.approver_id
       or new.manager_approved_by = new.supervisor_approved_by
       or new.test_result is distinct from 'passed'
       or new.return_to_service_status not in ('returned','not_required')
       or (new.return_to_service_status='returned' and new.returned_to_service_at is null)
       or new.closed_at is null then
      raise exception 'Current, distinct responsible-manager approval and successful closeout are required';
    end if;
    return new;
  end if;

  -- Rework can only be initiated by the approver who just rejected the current stage.
  if new.status='rework' and old.status in ('pending_supervisor_approval','pending_manager_approval') then
    select ap.* into v_latest_rejection
    from public.cmms_work_order_approvals ap
    where ap.work_order_id=new.id
      and ap.stage=case when old.status='pending_supervisor_approval'
                        then 'technical_supervisor' else 'responsible_manager' end
    order by ap.decided_at desc, ap.id desc limit 1;

    if v_latest_rejection.decision is distinct from 'rejected'
       or v_latest_rejection.approver_id is distinct from auth.uid() then
      raise exception 'Only the current-stage approver may return a work order for rework';
    end if;
    return new;
  end if;

  -- Ordinary lifecycle transitions.
  if old.status='triage' and new.status='approved_for_execution' then
    v_transition_allowed := v_is_governance;
  elsif old.status='approved_for_execution' and new.status='assigned' then
    v_transition_allowed := v_is_governance;
  elsif old.status='assigned' and new.status='in_progress' then
    v_transition_allowed := v_is_assigned or v_is_governance;
  elsif old.status='in_progress' and new.status in ('waiting_parts','testing') then
    v_transition_allowed := v_is_assigned or v_is_governance;
  elsif old.status='waiting_parts' and new.status='in_progress' then
    v_transition_allowed := v_is_assigned or v_is_governance;
  elsif old.status='testing' and new.status='in_progress' then
    v_transition_allowed := v_is_assigned or v_is_governance;
  elsif old.status='rework' and new.status in ('assigned','in_progress','testing') then
    v_transition_allowed := v_is_assigned or v_is_governance;
  elsif old.status in ('testing','rework') and new.status='pending_supervisor_approval' then
    v_transition_allowed := v_is_assigned or v_is_governance;
  end if;

  if not v_transition_allowed then
    raise exception 'Invalid or unauthorized work-order transition: % -> %',old.status,new.status;
  end if;

  if new.status='pending_supervisor_approval' then
    if new.test_result is distinct from 'passed'
       or new.return_to_service_status not in ('returned','not_required')
       or (new.return_to_service_status='returned' and new.returned_to_service_at is null) then
      raise exception 'Cannot request approval before successful test and explicit return-to-service decision';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists cmms_work_order_status_guard on public.cmms_work_orders;
create trigger cmms_work_order_status_guard
before update of status on public.cmms_work_orders
for each row execute function public.cmms_guard_work_order_status();

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

drop trigger if exists cmms_meter_readings_no_mutation on public.cmms_asset_meter_readings;
create trigger cmms_meter_readings_no_mutation
before update or delete on public.cmms_asset_meter_readings
for each row execute function public.cmms_reject_history_mutation();

drop trigger if exists cmms_action_no_mutation on public.cmms_work_order_actions;
create trigger cmms_action_no_mutation
before update or delete on public.cmms_work_order_actions
for each row execute function public.cmms_reject_history_mutation();

drop trigger if exists cmms_asset_history_no_mutation on public.cmms_asset_status_history;
create trigger cmms_asset_history_no_mutation
before update or delete on public.cmms_asset_status_history
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


-- Trigger functions are not RPC endpoints. Remove default/API execution privileges.
revoke all on function public.cmms_guard_work_order_approval() from public, anon, authenticated;
revoke all on function public.cmms_guard_location_hierarchy() from public, anon, authenticated;
revoke all on function public.cmms_record_asset_status_change() from public, anon, authenticated;
revoke all on function public.cmms_reject_history_mutation() from public, anon, authenticated;
revoke all on function public.cmms_apply_work_order_approval() from public, anon, authenticated;
revoke all on function public.cmms_guard_work_order_status() from public, anon, authenticated;

-- 8b) Immutable audit trail for operational CMMS entities.
create or replace function public.cmms_write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_entity jsonb;
  v_entity_id uuid;
begin
  if tg_op = 'DELETE' then
    v_before := to_jsonb(old);
    v_entity := v_before;
  else
    v_after := to_jsonb(new);
    v_entity := v_after;
    if tg_op = 'UPDATE' then
      v_before := to_jsonb(old);
    end if;
  end if;

  v_entity_id := (v_entity ->> 'id')::uuid;

  insert into public.cmms_audit_logs
    (actor_id, entity_type, entity_id, action, before_data, after_data)
  values
    (auth.uid(), tg_table_name, v_entity_id, lower(tg_op), v_before, v_after);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Record role roster, category dictionary, approval and meter-reading changes.
drop trigger if exists cmms_audit_user_roles on public.cmms_user_roles;
create trigger cmms_audit_user_roles after insert or update or delete on public.cmms_user_roles
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_asset_categories on public.cmms_asset_categories;
create trigger cmms_audit_asset_categories after insert or update or delete on public.cmms_asset_categories
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_approvals on public.cmms_work_order_approvals;
create trigger cmms_audit_approvals after insert on public.cmms_work_order_approvals
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_meter_readings on public.cmms_asset_meter_readings;
create trigger cmms_audit_meter_readings after insert on public.cmms_asset_meter_readings
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_locations on public.cmms_locations;
create trigger cmms_audit_locations after insert or update or delete on public.cmms_locations
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_assets on public.cmms_assets;
create trigger cmms_audit_assets after insert or update or delete on public.cmms_assets
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_failure_reports on public.cmms_failure_reports;
create trigger cmms_audit_failure_reports after insert or update or delete on public.cmms_failure_reports
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_work_orders on public.cmms_work_orders;
create trigger cmms_audit_work_orders after insert or update or delete on public.cmms_work_orders
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_assignments on public.cmms_work_order_assignments;
create trigger cmms_audit_assignments after insert or update or delete on public.cmms_work_order_assignments
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_actions on public.cmms_work_order_actions;
create trigger cmms_audit_actions after insert or update or delete on public.cmms_work_order_actions
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_pm_plans on public.cmms_pm_plans;
create trigger cmms_audit_pm_plans after insert or update or delete on public.cmms_pm_plans
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_pm_tasks on public.cmms_pm_tasks;
create trigger cmms_audit_pm_tasks after insert or update or delete on public.cmms_pm_tasks
for each row execute function public.cmms_write_audit_log();

drop trigger if exists cmms_audit_purchase_links on public.cmms_work_order_purchase_links;
create trigger cmms_audit_purchase_links after insert or update or delete on public.cmms_work_order_purchase_links
for each row execute function public.cmms_write_audit_log();

revoke all on function public.cmms_write_audit_log() from public, anon, authenticated;

-- 9) RLS policies and SELECT-only grants are defined separately in
-- 20261117_cmms_v1_authorization_draft.sql. No client write grants are intended.
-- The audited state-changing RPCs are a separate required implementation gate.
