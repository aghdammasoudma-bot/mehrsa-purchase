-- CMMS V1 release-candidate schema migration.
-- Requires the existing Mehrsa purchase-module baseline tables:
-- public.user_profiles(user_id, username, role, is_active)
-- public.pr_requests(id, created_by)
-- These are pre-existing Production dependencies and are NOT recreated here.
-- Intended first for isolated Staging. Do not apply to Production until:
-- external backup/restore verified, cmms_private confirmed unexposed in Data API,
-- real Auth/API/Storage tests pass, and explicit go-live approval is recorded.
-- Scheduler cron job is deliberately excluded; install separately after schedule tests.

-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_draft.sql
-- =====================================================================
-- DRAFT ONLY — DO NOT APPLY TO PRODUCTION.
-- CMMS v1 additive schema. RLS is enabled and no policies are granted yet.
-- Apply only after external backup + restore test and role mapping approval.

create table if not exists public.cmms_locations (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.cmms_locations(id) on delete restrict,
  code text not null unique,
  name text not null,
  discipline text check (discipline is null or discipline in ('production','electrical','mechanical','utilities','general')),
  manager_user_id uuid references auth.users(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_asset_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_assets (
  id uuid primary key default gen_random_uuid(),
  asset_code text not null unique,
  name text not null,
  category_id uuid references public.cmms_asset_categories(id) on delete restrict,
  location_id uuid references public.cmms_locations(id) on delete restrict,
  manufacturer text,
  model text,
  serial_number text,
  technical_specs jsonb not null default '{}'::jsonb,
  attachment_paths text[] not null default '{}'::text[],
  equipment_owner text,
  criticality text not null default 'medium' check (criticality in ('low','medium','high','critical')),
  operational_status text not null default 'operational' check (operational_status in ('operational','degraded','stopped','under_maintenance','retired')),
  commissioned_at date,
  warranty_until date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.cmms_asset_meter_readings (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  meter_code text not null,
  meter_unit text not null,
  meter_value numeric(14,3) not null check (meter_value >= 0),
  reading_at timestamptz not null default now(),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  source text not null default 'manual' check (source in ('manual','work_order','import')),
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('reporter','technician','technical_expert','technical_supervisor','responsible_manager')),
  location_id uuid references public.cmms_locations(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(user_id, role, location_id)
);

create table if not exists public.cmms_failure_reports (
  id uuid primary key default gen_random_uuid(),
  report_no bigint generated always as identity unique,
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  reported_by uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  priority text not null default 'normal' check (priority in ('low','normal','high','critical')),
  description text not null,
  symptoms text,
  production_impact text,
  safety_impact text,
  environmental_impact text,
  attachment_paths text[] not null default '{}'::text[],
  status text not null default 'submitted' check (status in ('submitted','under_review','rejected','converted','cancelled')),
  downtime_started_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_work_orders (
  id uuid primary key default gen_random_uuid(),
  wo_no bigint generated always as identity unique,
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  failure_report_id uuid references public.cmms_failure_reports(id) on delete set null,
  title text not null,
  description text,
  work_type text not null default 'corrective' check (work_type in ('corrective','preventive','inspection','improvement')),
  scope text,
  root_cause text,
  planned_start_at timestamptz,
  due_at timestamptz,
  estimated_duration_minutes integer check (estimated_duration_minutes is null or estimated_duration_minutes >= 0),
  permit_required boolean not null default false,
  permit_reference text,
  isolation_required boolean not null default false,
  priority text not null default 'normal' check (priority in ('low','normal','high','critical')),
  status text not null default 'triage' check (status in ('triage','approved_for_execution','assigned','in_progress','waiting_parts','testing','pending_supervisor_approval','pending_manager_approval','rework','closed','cancelled')),
  opened_by uuid not null references auth.users(id) on delete restrict,
  downtime_started_at timestamptz,
  returned_to_service_at timestamptz,
  test_result text check (test_result is null or test_result in ('passed','failed','partial')),
  return_to_service_status text check (return_to_service_status is null or return_to_service_status in ('returned','not_returned','not_required')),
  supervisor_approved_by uuid references auth.users(id) on delete set null,
  supervisor_approved_at timestamptz,
  manager_approved_by uuid references auth.users(id) on delete set null,
  manager_approved_at timestamptz,
  closed_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (manager_approved_by is null or supervisor_approved_by is not null),
  check (closed_at is null or (test_result is not null and supervisor_approved_by is not null and manager_approved_by is not null))
);

create table if not exists public.cmms_work_order_assignments (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.cmms_work_orders(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  unassigned_at timestamptz,
  unassign_reason text,
  check ((unassigned_at is null) = (unassign_reason is null))
);

create table if not exists public.cmms_work_order_actions (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.cmms_work_orders(id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action_type text not null check (action_type in ('diagnosis','repair','part_used','time_log','test','note','status_change')),
  description text not null,
  quantity numeric(12,3),
  unit text,
  meter_reading numeric(14,3),
  attachment_paths text[] not null default '{}'::text[],
  duration_minutes integer check (duration_minutes is null or duration_minutes >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_work_order_approvals (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.cmms_work_orders(id) on delete restrict,
  stage text not null check (stage in ('technical_supervisor','responsible_manager')),
  approver_id uuid not null references auth.users(id) on delete restrict,
  decision text not null check (decision in ('approved','rejected')),
  note text,
  decided_at timestamptz not null default now()
);

create table if not exists public.cmms_pm_plans (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  title text not null,
  frequency_basis text not null default 'calendar' check (frequency_basis in ('calendar','meter')),
  frequency_unit text not null check (frequency_unit in ('day','week','month','year','hour','cycle')),
  frequency_value numeric(14,3) not null check (frequency_value > 0),
  meter_code text,
  meter_unit text,
  next_due_meter_value numeric(14,3),
  last_meter_value numeric(14,3),
  checklist jsonb not null default '[]'::jsonb,
  next_due_at timestamptz,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((frequency_basis = 'calendar' and frequency_unit in ('day','week','month','year') and next_due_at is not null and frequency_value = trunc(frequency_value) and meter_code is null and meter_unit is null and next_due_meter_value is null)
      or (frequency_basis = 'meter' and frequency_unit in ('hour','cycle') and next_due_at is null and meter_code is not null and meter_unit is not null and next_due_meter_value is not null))
);

create table if not exists public.cmms_pm_tasks (
  id uuid primary key default gen_random_uuid(),
  pm_plan_id uuid not null references public.cmms_pm_plans(id) on delete restrict,
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  due_at timestamptz,
  due_meter_value numeric(14,3),
  trigger_type text not null check (trigger_type in ('calendar','meter')),
  status text not null default 'due' check (status in ('due','assigned','in_progress','completed','overdue','cancelled')),
  assigned_to uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  checklist_result jsonb,
  created_at timestamptz not null default now(),
  unique(pm_plan_id, due_at),
  check (due_at is not null or due_meter_value is not null)
);

create table if not exists public.cmms_asset_status_history (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  old_status text,
  new_status text not null,
  changed_by uuid references auth.users(id) on delete set null,
  reason text,
  changed_at timestamptz not null default now()
);

create table if not exists public.cmms_audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id) on delete set null,
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_work_order_purchase_links (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.cmms_work_orders(id) on delete restrict,
  purchase_request_id text not null references public.pr_requests(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(work_order_id, purchase_request_id)
);

create index if not exists cmms_assets_location_idx on public.cmms_assets(location_id);
create index if not exists cmms_assets_category_idx on public.cmms_assets(category_id);
create index if not exists cmms_meter_readings_asset_time_idx on public.cmms_asset_meter_readings(asset_id,meter_code,reading_at desc);
create index if not exists cmms_failure_reports_asset_status_idx on public.cmms_failure_reports(asset_id,status);
create index if not exists cmms_work_orders_asset_status_idx on public.cmms_work_orders(asset_id,status);
create index if not exists cmms_work_orders_priority_idx on public.cmms_work_orders(priority,status);
create index if not exists cmms_assignments_user_idx on public.cmms_work_order_assignments(user_id,work_order_id);
create index if not exists cmms_pm_tasks_due_idx on public.cmms_pm_tasks(status,due_at);
create unique index if not exists cmms_pm_tasks_meter_due_uq on public.cmms_pm_tasks(pm_plan_id,due_meter_value) where due_meter_value is not null;
create index if not exists cmms_audit_entity_idx on public.cmms_audit_logs(entity_type,entity_id,created_at desc);

alter table public.cmms_locations enable row level security;
alter table public.cmms_asset_categories enable row level security;
alter table public.cmms_assets enable row level security;
alter table public.cmms_asset_meter_readings enable row level security;
alter table public.cmms_user_roles enable row level security;
alter table public.cmms_failure_reports enable row level security;
alter table public.cmms_work_orders enable row level security;
alter table public.cmms_work_order_assignments enable row level security;
alter table public.cmms_work_order_actions enable row level security;
alter table public.cmms_work_order_approvals enable row level security;
alter table public.cmms_pm_plans enable row level security;
alter table public.cmms_pm_tasks enable row level security;
alter table public.cmms_asset_status_history enable row level security;
alter table public.cmms_audit_logs enable row level security;
alter table public.cmms_work_order_purchase_links enable row level security;

-- Intentionally no policies/grants in this draft. The tables remain inaccessible
-- to anon/authenticated until the role matrix and per-location authorization
-- functions are reviewed and tested in a staging database.


-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_hardening_draft.sql
-- =====================================================================
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
        test_result is not distinct from 'passed'
        and return_to_service_status is not null
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
  drop constraint if exists cmms_work_order_cancel_integrity;
alter table public.cmms_work_orders
  add constraint cmms_work_order_cancel_integrity check (
    (status = 'cancelled') = (cancel_reason is not null)
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
     or v_wo.return_to_service_status is null
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
      and exists (select 1 from public.user_profiles up where up.user_id=ur.user_id and up.is_active)
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

    update public.cmms_work_order_assignments
    set unassigned_at = now(),
        unassign_reason = 'Work order closed after final approval'
    where work_order_id = new.work_order_id
      and unassigned_at is null;
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

-- PM task integrity guard.
create or replace function public.cmms_guard_pm_task()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.cmms_pm_plans%rowtype;
begin
  select p.* into v_plan
  from public.cmms_pm_plans p
  where p.id=new.pm_plan_id
  for key share;

  if not found then raise exception 'PM plan not found'; end if;
  if new.asset_id is distinct from v_plan.asset_id then
    raise exception 'PM task asset must match its plan asset';
  end if;

  if v_plan.frequency_basis='calendar' then
    if new.trigger_type <> 'calendar' or new.due_at is null or new.due_meter_value is not null then
      raise exception 'Calendar PM task requires a calendar due date only';
    end if;
  elsif v_plan.frequency_basis='meter' then
    if new.trigger_type <> 'meter' or new.due_meter_value is null or new.due_at is not null then
      raise exception 'Meter PM task requires a meter due value only';
    end if;
  end if;

  if new.status='completed' then
    if new.completed_by is null or new.completed_at is null
       or new.checklist_result is null
       or (
         jsonb_typeof(new.checklist_result)='array'
         and jsonb_array_length(new.checklist_result)=0
       )
       or (
         jsonb_typeof(new.checklist_result)='object'
         and new.checklist_result='{}'::jsonb
       )
       or jsonb_typeof(new.checklist_result) not in ('array','object') then
      raise exception 'Completed PM task requires executor, timestamp and non-empty checklist';
    end if;
  elsif new.completed_by is not null or new.completed_at is not null or new.checklist_result is not null then
    raise exception 'Incomplete PM task cannot carry completion fields';
  end if;

  if tg_op='UPDATE' and old.status='completed' and new.status<>'completed' then
    raise exception 'Completed PM tasks cannot be reopened; create a follow-up task';
  end if;

  if new.status in ('assigned','in_progress') and new.assigned_to is null then
    raise exception 'Assigned or in-progress PM task requires an assignee';
  end if;

  return new;
end;
$$;

drop trigger if exists cmms_pm_task_guard on public.cmms_pm_tasks;
create trigger cmms_pm_task_guard
before insert or update on public.cmms_pm_tasks
for each row execute function public.cmms_guard_pm_task();

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
      and exists (select 1 from public.user_profiles up where up.user_id=ur.user_id and up.is_active)
  ) into v_is_governance;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=new.id
      and wa.user_id=auth.uid()
      and wa.unassigned_at is null
      and exists (select 1 from public.user_profiles up where up.user_id=wa.user_id and up.is_active)
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
       or new.return_to_service_status is null
       or new.return_to_service_status not in ('returned','not_required')
       or (new.return_to_service_status='returned' and new.returned_to_service_at is null)
       or new.closed_at is null then
      raise exception 'Current, distinct responsible-manager approval and successful closeout are required';
    end if;
    return new;
  end if;

  -- Cancellation is a governed terminal transition and requires a written reason.
  if new.status='cancelled' then
    if old.status in ('closed','cancelled')
       or not v_is_governance
       or nullif(btrim(coalesce(new.cancel_reason,'')), '') is null then
      raise exception 'Only technical supervisor/expert may cancel an open work order with a reason';
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
       or new.return_to_service_status is null
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
       coalesce(nullif(current_setting('cmms.status_change_reason', true),''),'Status updated without supplied reason'));
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
revoke all on function public.cmms_guard_pm_task() from public, anon, authenticated;

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


-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_authorization_draft.sql
-- =====================================================================
-- DRAFT ONLY — do not apply to production.
-- CMMS v1 read authorization layer. Depends on base schema + hardening draft.
-- All client access is read-only until audited workflow RPCs are separately implemented.
-- Keep cmms_private out of the Supabase Data API exposed schemas.
-- V1 global roles: masoud=technical_supervisor, biabani=responsible_manager,
-- reza=technical_expert, hamid=technician. Biabani approves all assets/locations.

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
  select auth.uid() is not null
    and exists (select 1 from public.user_profiles up where up.user_id=auth.uid() and up.is_active)
    and exists (
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

create or replace function cmms_private.cmms_user_has_active_role(p_user_id uuid,p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null and exists (
    select 1
    from public.cmms_user_roles r
    join public.user_profiles up on up.user_id=r.user_id
    where r.user_id=p_user_id
      and r.is_active
      and r.location_id is null
      and r.role=any(p_roles)
      and up.is_active
  );
$$;

revoke all on function cmms_private.cmms_has_any_role(text[]) from public, anon;
revoke all on function cmms_private.cmms_has_role_at_location(text[], uuid) from public, anon;
revoke all on function cmms_private.cmms_user_has_active_role(uuid,text[]) from public, anon;
grant execute on function cmms_private.cmms_has_any_role(text[]) to authenticated;
grant execute on function cmms_private.cmms_has_role_at_location(text[], uuid) to authenticated;
-- Deliberately keep cmms_user_has_active_role owner-only: it is an internal
-- workflow authorization helper and exposes arbitrary-user role membership.
-- SECURITY DEFINER workflow routines can call it as their owner.

-- Role roster: users can see their own role rows; governance roles can audit all.
alter table public.cmms_user_roles enable row level security;
drop policy if exists cmms_roles_read_self_or_governance on public.cmms_user_roles;
create policy cmms_roles_read_self_or_governance
on public.cmms_user_roles for select to authenticated
using (
  user_id = (select auth.uid())
  or (select cmms_private.cmms_has_any_role(array['technical_supervisor','responsible_manager']))
);

-- Locations and category dictionary.
drop policy if exists cmms_locations_read_scope on public.cmms_locations;
create policy cmms_locations_read_scope
on public.cmms_locations for select to authenticated
using (
  (select cmms_private.cmms_has_role_at_location(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
    cmms_locations.id
  ))
);

drop policy if exists cmms_categories_read_cmms on public.cmms_asset_categories;
create policy cmms_categories_read_cmms
on public.cmms_asset_categories for select to authenticated
using (
  (select cmms_private.cmms_has_any_role(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager']
  ))
);

-- Asset register.
drop policy if exists cmms_assets_read_scope on public.cmms_assets;
create policy cmms_assets_read_scope
on public.cmms_assets for select to authenticated
using (
  (select cmms_private.cmms_has_role_at_location(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
    cmms_assets.location_id
  ))
);

-- Meter readings inherit access from the asset location.
drop policy if exists cmms_meter_readings_read_scope on public.cmms_asset_meter_readings;
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

-- Failure reports inherit access from their asset location.
drop policy if exists cmms_failures_read_scope on public.cmms_failure_reports;
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
drop policy if exists cmms_work_orders_read_scope on public.cmms_work_orders;
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
drop policy if exists cmms_assignments_read_scope on public.cmms_work_order_assignments;
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

drop policy if exists cmms_actions_read_scope on public.cmms_work_order_actions;
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

drop policy if exists cmms_approvals_read_scope on public.cmms_work_order_approvals;
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
drop policy if exists cmms_pm_plans_read_scope on public.cmms_pm_plans;
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

drop policy if exists cmms_pm_tasks_read_scope on public.cmms_pm_tasks;
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

drop policy if exists cmms_asset_history_read_scope on public.cmms_asset_status_history;
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
drop policy if exists cmms_audit_read_governance on public.cmms_audit_logs;
create policy cmms_audit_read_governance
on public.cmms_audit_logs for select to authenticated
using (
  (select cmms_private.cmms_has_any_role(array['technical_supervisor','responsible_manager']))
);

drop policy if exists cmms_purchase_links_read_scope on public.cmms_work_order_purchase_links;
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

-- Write operations remain intentionally unavailable until each workflow has a
-- separate, audited RPC and role-specific tests. Never solve this by granting
-- broad table-level UPDATE/DELETE to authenticated users.


-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_role_seed_draft.sql
-- =====================================================================
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


-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_workflow_rpc_draft.sql
-- =====================================================================
-- DRAFT ONLY — CMMS v1 controlled workflow RPCs.
-- NOT APPLIED. Depends on base schema, hardening triggers and authorization helpers.
-- Private SECURITY DEFINER implementations; public SECURITY INVOKER RPC entry points.
-- No broad client table UPDATE/DELETE grants are required.

-- The live write-locked database has the earlier 8-argument versions.
-- Remove those inaccessible legacy overloads before installing the 9-argument
-- downtime-aware RPC; keeping both with defaults would make PostgREST calls ambiguous.
drop function if exists public.cmms_report_failure(uuid,text,text,text,text,text,text,text[]);
drop function if exists cmms_private.cmms_report_failure(uuid,text,text,text,text,text,text,text[]);

create or replace function cmms_private.cmms_report_failure(
  p_asset_id uuid,
  p_priority text,
  p_description text,
  p_symptoms text default null,
  p_production_impact text default null,
  p_safety_impact text default null,
  p_environmental_impact text default null,
  p_attachment_paths text[] default '{}'::text[],
  p_downtime_started_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_report_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_description,'')), '') is null then
    raise exception 'Failure description is required';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a
  where a.id = p_asset_id and a.operational_status <> 'retired'
  for key share;

  if not found then raise exception 'Asset not found or retired'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['reporter','technician','technical_expert','technical_supervisor'],
    v_location_id
  ) then
    raise exception 'No CMMS permission for this asset location';
  end if;

  insert into public.cmms_failure_reports(
    asset_id, reported_by, priority, description, symptoms,
    production_impact, safety_impact, environmental_impact, attachment_paths, downtime_started_at
  )
  values (
    p_asset_id, auth.uid(), p_priority, btrim(p_description), p_symptoms,
    p_production_impact, p_safety_impact, p_environmental_impact,
    coalesce(p_attachment_paths,'{}'::text[]), p_downtime_started_at
  )
  returning id into v_report_id;

  return v_report_id;
end;
$$;

create or replace function cmms_private.cmms_triage_failure(
  p_failure_report_id uuid,
  p_decision text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report public.cmms_failure_reports%rowtype;
  v_location_id uuid;
  v_work_order_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_decision is null or p_decision not in ('convert','reject') then raise exception 'Invalid triage decision'; end if;
  if p_decision = 'reject' and nullif(btrim(coalesce(p_note,'')), '') is null then
    raise exception 'Rejection reason is required';
  end if;

  select fr.* into v_report
  from public.cmms_failure_reports fr
  where fr.id = p_failure_report_id
  for update;

  if not found or v_report.status not in ('submitted','under_review') then
    raise exception 'Failure report is not available for triage';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id = v_report.asset_id;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'], v_location_id
  ) then
    raise exception 'Only technical expert or supervisor can triage failures';
  end if;

  if p_decision = 'reject' then
    update public.cmms_failure_reports
    set status='rejected', reviewed_by=auth.uid(), reviewed_at=now(), review_note=btrim(p_note)
    where id=p_failure_report_id;
    return null;
  end if;

  insert into public.cmms_work_orders(
    asset_id, failure_report_id, title, description, work_type, priority, status, opened_by, downtime_started_at
  )
  values (
    v_report.asset_id, v_report.id, left(v_report.description,120), v_report.description,
    'corrective', v_report.priority, 'triage', auth.uid(), v_report.downtime_started_at
  )
  returning id into v_work_order_id;

  update public.cmms_failure_reports
  set status='converted', reviewed_by=auth.uid(), reviewed_at=now(), review_note=coalesce(p_note,'')
  where id=p_failure_report_id;

  return v_work_order_id;
end;
$$;

create or replace function cmms_private.cmms_create_work_order(
  p_asset_id uuid,
  p_title text,
  p_work_type text,
  p_priority text default 'normal',
  p_description text default null,
  p_scope text default null,
  p_planned_start_at timestamptz default null,
  p_due_at timestamptz default null,
  p_estimated_duration_minutes integer default null,
  p_permit_required boolean default false,
  p_permit_reference text default null,
  p_isolation_required boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_work_order_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_title,'')),'') is null then raise exception 'Work-order title is required'; end if;
  if p_work_type not in ('corrective','preventive','inspection','improvement') then
    raise exception 'Invalid work type';
  end if;
  if p_priority not in ('low','normal','high','critical') then raise exception 'Invalid priority'; end if;
  if p_estimated_duration_minutes is not null and p_estimated_duration_minutes < 0 then
    raise exception 'Estimated duration cannot be negative';
  end if;
  if p_planned_start_at is not null and p_due_at is not null and p_due_at < p_planned_start_at then
    raise exception 'Due date cannot precede planned start';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a
  where a.id=p_asset_id and a.operational_status <> 'retired';
  if not found then raise exception 'Asset not found or retired'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can create work orders'; end if;

  insert into public.cmms_work_orders(
    asset_id,title,description,work_type,scope,priority,status,opened_by,
    planned_start_at,due_at,estimated_duration_minutes,permit_required,
    permit_reference,isolation_required
  ) values (
    p_asset_id,btrim(p_title),nullif(btrim(coalesce(p_description,'')),''),
    p_work_type,nullif(btrim(coalesce(p_scope,'')),''),p_priority,'triage',auth.uid(),
    p_planned_start_at,p_due_at,p_estimated_duration_minutes,coalesce(p_permit_required,false),
    nullif(btrim(coalesce(p_permit_reference,'')),''),coalesce(p_isolation_required,false)
  ) returning id into v_work_order_id;

  return v_work_order_id;
end;
$$;

create or replace function cmms_private.cmms_release_work_order(p_work_order_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select w.* into v_wo
  from public.cmms_work_orders w
  where w.id=p_work_order_id
  for update;

  if not found or v_wo.status <> 'triage' then
    raise exception 'Work order is not awaiting technical release';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'], v_location_id
  ) then
    raise exception 'Only technical expert or supervisor can release a work order';
  end if;

  update public.cmms_work_orders
  set status='approved_for_execution', updated_at=now()
  where id=p_work_order_id;

  return 'approved_for_execution';
end;
$$;

create or replace function cmms_private.cmms_assign_work_order(
  p_work_order_id uuid,
  p_assignee_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_assignment_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select w.* into v_wo
  from public.cmms_work_orders w
  where w.id=p_work_order_id
  for update;

  if not found or v_wo.status not in ('approved_for_execution','assigned','rework') then
    raise exception 'Work order is not ready for assignment';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'], v_location_id
  ) then
    raise exception 'Only technical expert or supervisor can assign work';
  end if;

  if not cmms_private.cmms_user_has_active_role(
    p_assignee_id,array['technician','technical_expert']
  ) then
    raise exception 'Assignee has no active technician CMMS role';
  end if;

  insert into public.cmms_work_order_assignments(work_order_id,user_id,assigned_by)
  values(p_work_order_id,p_assignee_id,auth.uid())
  returning id into v_assignment_id;

  update public.cmms_work_orders
  set status='assigned',updated_at=now()
  where id=p_work_order_id and status in ('approved_for_execution','rework');

  return v_assignment_id;
end;
$$;

create or replace function cmms_private.cmms_record_work_order_action(
  p_work_order_id uuid,
  p_action_type text,
  p_description text,
  p_duration_minutes integer default null,
  p_quantity numeric default null,
  p_unit text default null,
  p_meter_reading numeric default null,
  p_attachment_paths text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_action_id uuid;
  v_is_assigned boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_description,'')), '') is null then
    raise exception 'Action description is required';
  end if;

  select w.* into v_wo
  from public.cmms_work_orders w where w.id=p_work_order_id
  for key share;

  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Work order is not active';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=p_work_order_id
      and wa.user_id=auth.uid()
      and wa.unassigned_at is null
  ) into v_is_assigned;

  if v_is_assigned then
    if not cmms_private.cmms_user_has_active_role(auth.uid(),array['technician','technical_expert']) then
      raise exception 'Assigned user no longer has an active CMMS execution role';
    end if;
  elsif not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned active workers or technical supervisors/experts can log actions';
  end if;

  insert into public.cmms_work_order_actions(
    work_order_id,actor_id,action_type,description,duration_minutes,
    quantity,unit,meter_reading,attachment_paths
  )
  values(
    p_work_order_id,auth.uid(),p_action_type,btrim(p_description),p_duration_minutes,
    p_quantity,p_unit,p_meter_reading,coalesce(p_attachment_paths,'{}'::text[])
  )
  returning id into v_action_id;

  return v_action_id;
end;
$$;

create or replace function cmms_private.cmms_set_work_order_progress(
  p_work_order_id uuid,
  p_next_status text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_is_assigned boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_next_status not in ('in_progress','waiting_parts','testing') then
    raise exception 'Invalid progress status';
  end if;

  select w.* into v_wo
  from public.cmms_work_orders w where w.id=p_work_order_id
  for update;

  if not found then raise exception 'Work order not found'; end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=p_work_order_id
      and wa.user_id=auth.uid()
      and wa.unassigned_at is null
  ) into v_is_assigned;

  if v_is_assigned then
    if not cmms_private.cmms_user_has_active_role(auth.uid(),array['technician','technical_expert']) then
      raise exception 'Assigned user no longer has an active CMMS execution role';
    end if;
  elsif not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned active workers or technical supervisors/experts can change execution status';
  end if;

  if not (
    (v_wo.status='assigned' and p_next_status='in_progress')
    or (v_wo.status='in_progress' and p_next_status in ('waiting_parts','testing'))
    or (v_wo.status='waiting_parts' and p_next_status='in_progress')
    or (v_wo.status='rework' and p_next_status='in_progress')
  ) then
    raise exception 'Invalid execution transition: % -> %',v_wo.status,p_next_status;
  end if;

  update public.cmms_work_orders
  set status=p_next_status,updated_at=now()
  where id=p_work_order_id;

  return p_next_status;
end;
$$;

create or replace function cmms_private.cmms_submit_work_order_test(
  p_work_order_id uuid,
  p_test_result text,
  p_return_to_service_status text,
  p_returned_to_service_at timestamptz,
  p_test_description text,
  p_attachment_paths text[] default '{}'::text[]
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_is_assigned boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_test_result is null or p_test_result not in ('passed','failed','partial') then raise exception 'Invalid test result'; end if;

  select w.* into v_wo
  from public.cmms_work_orders w where w.id=p_work_order_id
  for update;

  if not found or v_wo.status <> 'testing' then
    raise exception 'Work order is not ready for testing';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=p_work_order_id
      and wa.user_id=auth.uid()
      and wa.unassigned_at is null
  ) into v_is_assigned;

  if v_is_assigned then
    if not cmms_private.cmms_user_has_active_role(auth.uid(),array['technician','technical_expert']) then
      raise exception 'Assigned user no longer has an active CMMS execution role';
    end if;
  elsif not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned active workers or technical supervisors/experts can submit tests';
  end if;

  if p_test_result='passed' then
    if p_return_to_service_status is null or p_return_to_service_status not in ('returned','not_required') then
      raise exception 'Explicit return-to-service decision is required';
    end if;
    if p_return_to_service_status='returned' and p_returned_to_service_at is null then
      raise exception 'Return-to-service timestamp is required';
    end if;
  end if;

  insert into public.cmms_work_order_actions(
    work_order_id,actor_id,action_type,description,attachment_paths
  )
  values(
    p_work_order_id,auth.uid(),'test',
    coalesce(nullif(btrim(p_test_description),''),'Test result: '||p_test_result),
    coalesce(p_attachment_paths,'{}'::text[])
  );

  update public.cmms_work_orders
  set test_result=p_test_result,
      return_to_service_status=case when p_test_result='passed' then p_return_to_service_status else 'not_returned' end,
      returned_to_service_at=case when p_test_result='passed' and p_return_to_service_status='returned' then p_returned_to_service_at else null end,
      status=case when p_test_result='passed' then 'pending_supervisor_approval' else 'in_progress' end,
      updated_at=now()
  where id=p_work_order_id;

  return case when p_test_result='passed' then 'pending_supervisor_approval' else 'in_progress' end;
end;
$$;

create or replace function cmms_private.cmms_decide_work_order(
  p_work_order_id uuid,
  p_stage text,
  p_decision text,
  p_note text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_stage not in ('technical_supervisor','responsible_manager') then
    raise exception 'Invalid approval stage';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Invalid approval decision';
  end if;
  if p_decision='rejected' and nullif(btrim(coalesce(p_note,'')),'') is null then
    raise exception 'A rejection reason is mandatory';
  end if;

  select w.* into v_wo
  from public.cmms_work_orders w
  where w.id=p_work_order_id
  for update;

  if not found then raise exception 'Work order not found'; end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  if p_stage='technical_supervisor' then
    if v_wo.status <> 'pending_supervisor_approval' then
      raise exception 'Work order is not awaiting technical-supervisor approval';
    end if;
    if not cmms_private.cmms_has_role_at_location(
      array['technical_supervisor'],v_location_id
    ) then
      raise exception 'Only the technical supervisor may make this decision';
    end if;

    insert into public.cmms_work_order_approvals(
      work_order_id,stage,approver_id,decision,note
    ) values(p_work_order_id,p_stage,auth.uid(),p_decision,nullif(btrim(p_note),''));

    if p_decision='approved' then
      update public.cmms_work_orders
      set supervisor_approved_by=auth.uid(),
          supervisor_approved_at=now(),
          status='pending_manager_approval',
          updated_at=now()
      where id=p_work_order_id;
      return 'pending_manager_approval';
    else
      update public.cmms_work_orders
      set supervisor_approved_by=null,
          supervisor_approved_at=null,
          manager_approved_by=null,
          manager_approved_at=null,
          closed_at=null,
          status='rework',
          updated_at=now()
      where id=p_work_order_id;
      return 'rework';
    end if;
  end if;

  if v_wo.status <> 'pending_manager_approval' then
    raise exception 'Work order is not awaiting responsible-manager approval';
  end if;
  if v_wo.supervisor_approved_by is null
     or v_wo.supervisor_approved_by=auth.uid() then
    raise exception 'Responsible-manager approval must be by a different person after supervisor approval';
  end if;
  if not cmms_private.cmms_has_role_at_location(
    array['responsible_manager'],v_location_id
  ) then
    raise exception 'Only the responsible manager may make this decision';
  end if;

  insert into public.cmms_work_order_approvals(
    work_order_id,stage,approver_id,decision,note
  ) values(p_work_order_id,p_stage,auth.uid(),p_decision,nullif(btrim(p_note),''));

  if p_decision='approved' then
    update public.cmms_work_orders
    set manager_approved_by=auth.uid(),
        manager_approved_at=now(),
        closed_at=now(),
        status='closed',
        updated_at=now()
    where id=p_work_order_id;
    return 'closed';
  else
    update public.cmms_work_orders
    set supervisor_approved_by=null,
        supervisor_approved_at=null,
        manager_approved_by=null,
        manager_approved_at=null,
        closed_at=null,
        status='rework',
        updated_at=now()
    where id=p_work_order_id;
    return 'rework';
  end if;
end;
$$;

create or replace function cmms_private.cmms_create_pm_plan(
  p_asset_id uuid,
  p_title text,
  p_frequency_basis text,
  p_frequency_unit text,
  p_frequency_value numeric,
  p_meter_code text,
  p_meter_unit text,
  p_next_due_at timestamptz,
  p_next_due_meter_value numeric,
  p_checklist jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_plan_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_title,'')), '') is null then raise exception 'PM plan title is required'; end if;
  if p_frequency_value is null or p_frequency_value <= 0 then raise exception 'PM frequency must be positive'; end if;
  if p_checklist is null or not (
    (jsonb_typeof(p_checklist)='array' and p_checklist <> '[]'::jsonb)
    or (jsonb_typeof(p_checklist)='object' and p_checklist <> '{}'::jsonb)
  ) then raise exception 'A non-empty PM checklist is required'; end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=p_asset_id;
  if not found then raise exception 'Asset not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can create PM plans'; end if;

  if p_frequency_basis='calendar' then
    if p_frequency_unit not in ('day','week','month','year')
       or p_frequency_value <> trunc(p_frequency_value)
       or p_next_due_at is null
       or p_meter_code is not null or p_meter_unit is not null or p_next_due_meter_value is not null then
      raise exception 'Invalid calendar PM frequency configuration';
    end if;
  elsif p_frequency_basis='meter' then
    if p_frequency_unit not in ('hour','cycle')
       or nullif(btrim(coalesce(p_meter_code,'')),'') is null
       or nullif(btrim(coalesce(p_meter_unit,'')),'') is null
       or p_next_due_meter_value is null or p_next_due_at is not null then
      raise exception 'Invalid meter PM frequency configuration';
    end if;
  else
    raise exception 'V1 supports calendar or meter PM plans only';
  end if;

  insert into public.cmms_pm_plans(
    asset_id,title,frequency_basis,frequency_unit,frequency_value,
    meter_code,meter_unit,next_due_at,next_due_meter_value,checklist,created_by
  ) values (
    p_asset_id,btrim(p_title),p_frequency_basis,p_frequency_unit,p_frequency_value,
    nullif(btrim(coalesce(p_meter_code,'')),''),nullif(btrim(coalesce(p_meter_unit,'')),''),
    p_next_due_at,p_next_due_meter_value,p_checklist,auth.uid()
  ) returning id into v_plan_id;

  return v_plan_id;
end;
$$;

create or replace function cmms_private.cmms_update_asset(
  p_asset_id uuid,
  p_asset_code text,
  p_name text,
  p_location_id uuid,
  p_criticality text,
  p_category_id uuid,
  p_manufacturer text,
  p_model text,
  p_serial_number text,
  p_technical_specs jsonb,
  p_equipment_owner text,
  p_attachment_paths text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_location uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_asset_code,'')),'') is null
     or nullif(btrim(coalesce(p_name,'')),'') is null then
    raise exception 'Asset code and name are required';
  end if;

  select a.location_id into v_old_location
  from public.cmms_assets a where a.id=p_asset_id
  for update;
  if not found then raise exception 'Asset not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_old_location
  ) or not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],p_location_id
  ) then
    raise exception 'No permission to edit this asset or move it to the selected location';
  end if;

  if not exists(select 1 from public.cmms_locations where id=p_location_id and is_active) then
    raise exception 'Target asset location is missing or inactive';
  end if;
  if p_category_id is not null and not exists(
    select 1 from public.cmms_asset_categories where id=p_category_id
  ) then raise exception 'Asset category not found'; end if;

  update public.cmms_assets
  set asset_code=btrim(p_asset_code),
      name=btrim(p_name),
      location_id=p_location_id,
      criticality=p_criticality,
      category_id=p_category_id,
      manufacturer=nullif(btrim(coalesce(p_manufacturer,'')),''),
      model=nullif(btrim(coalesce(p_model,'')),''),
      serial_number=nullif(btrim(coalesce(p_serial_number,'')),''),
      technical_specs=coalesce(p_technical_specs,'{}'::jsonb),
      equipment_owner=nullif(btrim(coalesce(p_equipment_owner,'')),''),
      attachment_paths=coalesce(p_attachment_paths,attachment_paths),
      updated_at=now()
  where id=p_asset_id;

  return p_asset_id;
end;
$$;

create or replace function cmms_private.cmms_change_asset_status(
  p_asset_id uuid,
  p_new_status text,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_new_status not in ('operational','degraded','stopped','under_maintenance','retired') then
    raise exception 'Invalid asset operational status';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Asset status-change reason is mandatory';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=p_asset_id
  for update;
  if not found then raise exception 'Asset not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can change asset status'; end if;

  perform set_config('cmms.status_change_reason',btrim(p_reason),true);
  update public.cmms_assets
  set operational_status=p_new_status,updated_at=now()
  where id=p_asset_id;
  perform set_config('cmms.status_change_reason','',true);

  return p_asset_id;
end;
$$;

create or replace function cmms_private.cmms_update_pm_plan(
  p_pm_plan_id uuid,
  p_title text,
  p_frequency_basis text,
  p_frequency_unit text,
  p_frequency_value numeric,
  p_meter_code text,
  p_meter_unit text,
  p_next_due_at timestamptz,
  p_next_due_meter_value numeric,
  p_checklist jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_title,'')), '') is null then raise exception 'PM plan title is required'; end if;
  if p_frequency_value is null or p_frequency_value <= 0 then raise exception 'PM frequency must be positive'; end if;
  if p_checklist is null or not (
    (jsonb_typeof(p_checklist)='array' and p_checklist <> '[]'::jsonb)
    or (jsonb_typeof(p_checklist)='object' and p_checklist <> '{}'::jsonb)
  ) then raise exception 'A non-empty PM checklist is required'; end if;

  select a.location_id into v_location_id
  from public.cmms_pm_plans p join public.cmms_assets a on a.id=p.asset_id
  where p.id=p_pm_plan_id
  for update of p;
  if not found then raise exception 'PM plan not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can update PM plans'; end if;

  if p_frequency_basis='calendar' then
    if p_frequency_unit not in ('day','week','month','year')
       or p_frequency_value <> trunc(p_frequency_value)
       or p_next_due_at is null
       or p_meter_code is not null or p_meter_unit is not null or p_next_due_meter_value is not null then
      raise exception 'Invalid calendar PM frequency configuration';
    end if;
  elsif p_frequency_basis='meter' then
    if p_frequency_unit not in ('hour','cycle')
       or nullif(btrim(coalesce(p_meter_code,'')),'') is null
       or nullif(btrim(coalesce(p_meter_unit,'')),'') is null
       or p_next_due_meter_value is null or p_next_due_at is not null then
      raise exception 'Invalid meter PM frequency configuration';
    end if;
  else
    raise exception 'V1 supports calendar or meter PM plans only';
  end if;

  update public.cmms_pm_plans
  set title=btrim(p_title),
      frequency_basis=p_frequency_basis,
      frequency_unit=p_frequency_unit,
      frequency_value=p_frequency_value,
      meter_code=nullif(btrim(coalesce(p_meter_code,'')),''),
      meter_unit=nullif(btrim(coalesce(p_meter_unit,'')),''),
      next_due_at=p_next_due_at,
      next_due_meter_value=p_next_due_meter_value,
      checklist=p_checklist
  where id=p_pm_plan_id;

  return p_pm_plan_id;
end;
$$;

create or replace function cmms_private.cmms_set_pm_plan_active(
  p_pm_plan_id uuid,
  p_is_active boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select a.location_id into v_location_id
  from public.cmms_pm_plans p join public.cmms_assets a on a.id=p.asset_id
  where p.id=p_pm_plan_id
  for update of p;
  if not found then raise exception 'PM plan not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can change PM plan status'; end if;

  update public.cmms_pm_plans set is_active=p_is_active where id=p_pm_plan_id;
  return p_pm_plan_id;
end;
$$;

create or replace function cmms_private.cmms_start_pm_task(p_pm_task_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.cmms_pm_tasks%rowtype;
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select t.* into v_task
  from public.cmms_pm_tasks t where t.id=p_pm_task_id
  for update;
  if not found or v_task.status not in ('assigned','due','overdue') then
    raise exception 'PM task is not ready to start';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_task.asset_id;

  if v_task.assigned_to is distinct from auth.uid()
     or not cmms_private.cmms_user_has_active_role(auth.uid(),array['technician','technical_expert']) then
    raise exception 'Only the assigned active CMMS technician/expert can start this PM task';
  end if;

  update public.cmms_pm_tasks set status='in_progress' where id=p_pm_task_id;
  return p_pm_task_id;
end;
$$;

create or replace function cmms_private.cmms_complete_pm_task(
  p_pm_task_id uuid,
  p_checklist_result jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.cmms_pm_tasks%rowtype;
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_checklist_result is null
     or jsonb_typeof(p_checklist_result) not in ('object','array')
     or (jsonb_typeof(p_checklist_result)='array' and jsonb_array_length(p_checklist_result)=0)
     or (jsonb_typeof(p_checklist_result)='object' and p_checklist_result='{}'::jsonb) then
    raise exception 'Non-empty checklist result is required';
  end if;

  select t.* into v_task
  from public.cmms_pm_tasks t where t.id=p_pm_task_id
  for update;

  if not found or v_task.status not in ('due','assigned','in_progress','overdue') then
    raise exception 'PM task is not open';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_task.asset_id;

  if v_task.assigned_to=auth.uid() then
    if not cmms_private.cmms_user_has_active_role(
      auth.uid(),array['technician','technical_expert']
    ) then
      raise exception 'Assigned user no longer has an active CMMS execution role';
    end if;
  elsif not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only the assigned technician or technical supervisor/expert can complete this PM task';
  end if;

  update public.cmms_pm_tasks
  set status='completed',completed_by=auth.uid(),completed_at=now(),
      checklist_result=p_checklist_result
  where id=p_pm_task_id;

  return p_pm_task_id;
end;
$$;

create or replace function cmms_private.cmms_record_meter_reading(
  p_asset_id uuid,
  p_meter_code text,
  p_meter_unit text,
  p_meter_value numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_reading_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_meter_code,'')),'') is null
     or nullif(btrim(coalesce(p_meter_unit,'')),'') is null
     or p_meter_value is null or p_meter_value < 0 then
    raise exception 'Valid meter code, unit and non-negative reading are required';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=p_asset_id;
  if not found then raise exception 'Asset not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technician','technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'No permission to record meter readings for this asset';
  end if;

  insert into public.cmms_asset_meter_readings(
    asset_id,meter_code,meter_unit,meter_value,recorded_by,source
  ) values (
    p_asset_id,btrim(p_meter_code),btrim(p_meter_unit),p_meter_value,auth.uid(),'manual'
  ) returning id into v_reading_id;

  return v_reading_id;
end;
$$;

create or replace function cmms_private.cmms_assign_pm_task(
  p_pm_task_id uuid,
  p_assignee_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.cmms_pm_tasks%rowtype;
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select t.* into v_task
  from public.cmms_pm_tasks t where t.id=p_pm_task_id
  for update;

  if not found or v_task.status not in ('due','overdue','assigned') then
    raise exception 'PM task is not available for assignment';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_task.asset_id;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only technical expert or supervisor can assign PM tasks';
  end if;

  if not cmms_private.cmms_user_has_active_role(
    p_assignee_id,array['technician','technical_expert']
  ) then
    raise exception 'PM assignee has no active technician role';
  end if;

  update public.cmms_pm_tasks
  set assigned_to=p_assignee_id,status='assigned'
  where id=p_pm_task_id;

  return p_pm_task_id;
end;
$$;

-- Server-side PM generation. Calendar and meter plans are separate bases in v1.
-- Each missed interval is generated once; unique indexes make reruns idempotent.
create or replace function cmms_private.cmms_generate_due_pm_tasks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.cmms_pm_plans%rowtype;
  v_latest_meter numeric(14,3);
  v_next_due_at timestamptz;
  v_next_due_meter numeric(14,3);
  v_created integer := 0;
  v_rows integer;
  v_runs integer;
begin
  for v_plan in
    select p.* from public.cmms_pm_plans p
    where p.is_active
    order by p.created_at,p.id
    for update skip locked
  loop
    v_runs := 0;

    if v_plan.frequency_basis='calendar' then
      v_next_due_at := v_plan.next_due_at;

      while v_next_due_at <= now() and v_runs < 100 loop
        insert into public.cmms_pm_tasks(pm_plan_id,asset_id,due_at,trigger_type,status)
        values(v_plan.id,v_plan.asset_id,v_next_due_at,'calendar','due')
        on conflict do nothing;
        get diagnostics v_rows = row_count;
        v_created := v_created + v_rows;

        v_next_due_at := case v_plan.frequency_unit
          when 'day' then v_next_due_at + make_interval(days => v_plan.frequency_value::integer)
          when 'week' then v_next_due_at + make_interval(weeks => v_plan.frequency_value::integer)
          when 'month' then v_next_due_at + make_interval(months => v_plan.frequency_value::integer)
          when 'year' then v_next_due_at + make_interval(years => v_plan.frequency_value::integer)
        end;
        v_runs := v_runs + 1;
      end loop;

      update public.cmms_pm_plans set next_due_at=v_next_due_at where id=v_plan.id;

    elsif v_plan.frequency_basis='meter' then
      select mr.meter_value into v_latest_meter
      from public.cmms_asset_meter_readings mr
      where mr.asset_id=v_plan.asset_id
        and mr.meter_code=v_plan.meter_code
        and mr.meter_unit=v_plan.meter_unit
      order by mr.reading_at desc,mr.created_at desc
      limit 1;

      if v_latest_meter is null then
        continue;
      end if;

      v_next_due_meter := v_plan.next_due_meter_value;
      while v_next_due_meter <= v_latest_meter and v_runs < 100 loop
        insert into public.cmms_pm_tasks(pm_plan_id,asset_id,due_meter_value,trigger_type,status)
        values(v_plan.id,v_plan.asset_id,v_next_due_meter,'meter','due')
        on conflict do nothing;
        get diagnostics v_rows = row_count;
        v_created := v_created + v_rows;

        v_next_due_meter := v_next_due_meter + v_plan.frequency_value;
        v_runs := v_runs + 1;
      end loop;

      update public.cmms_pm_plans
      set next_due_meter_value=v_next_due_meter,last_meter_value=v_latest_meter
      where id=v_plan.id;
    end if;
  end loop;

  return v_created;
end;
$$;

create or replace function cmms_private.cmms_cancel_work_order(
  p_work_order_id uuid,
  p_reason text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_reason,'')), '') is null then
    raise exception 'Cancellation reason is mandatory';
  end if;

  select w.* into v_wo
  from public.cmms_work_orders w where w.id=p_work_order_id
  for update;
  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Work order is not open';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then
    raise exception 'Only technical supervisor or expert can cancel a work order';
  end if;

  update public.cmms_work_orders
  set status='cancelled',cancel_reason=btrim(p_reason),updated_at=now()
  where id=p_work_order_id;

  update public.cmms_work_order_assignments
  set unassigned_at=now(),unassign_reason='Work order cancelled: '||btrim(p_reason)
  where work_order_id=p_work_order_id and unassigned_at is null;

  return 'cancelled';
end;
$$;

create or replace function cmms_private.cmms_reassign_work_order(
  p_assignment_id uuid,
  p_new_assignee_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assignment public.cmms_work_order_assignments%rowtype;
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_new_assignment_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_reason,'')), '') is null then
    raise exception 'Reassignment reason is mandatory';
  end if;

  select wa.* into v_assignment
  from public.cmms_work_order_assignments wa
  where wa.id=p_assignment_id and wa.unassigned_at is null
  for update;
  if not found then raise exception 'Active assignment not found'; end if;
  if v_assignment.user_id=p_new_assignee_id then
    raise exception 'New assignee must be different from current assignee';
  end if;

  select w.* into v_wo
  from public.cmms_work_orders w where w.id=v_assignment.work_order_id
  for update;
  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Work order is not open for reassignment';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;
  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then
    raise exception 'Only technical supervisor or expert can reassign work';
  end if;

  if not cmms_private.cmms_user_has_active_role(
    p_new_assignee_id,array['technician','technical_expert']
  ) then
    raise exception 'New assignee has no active technician CMMS role';
  end if;

  insert into public.cmms_work_order_assignments(work_order_id,user_id,assigned_by)
  values(v_assignment.work_order_id,p_new_assignee_id,auth.uid())
  returning id into v_new_assignment_id;

  update public.cmms_work_order_assignments
  set unassigned_at=now(),unassign_reason=btrim(p_reason)
  where id=p_assignment_id;

  return v_new_assignment_id;
end;
$$;

create or replace function cmms_private.cmms_link_purchase_request(
  p_work_order_id uuid,
  p_purchase_request_id text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_link_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select w.* into v_wo
  from public.cmms_work_orders w where w.id=p_work_order_id
  for key share;
  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Only an open work order can be linked to a purchase request';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_wo.asset_id;
  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then
    raise exception 'Only technical supervisor or expert can link a purchase request';
  end if;

  if not exists (select 1 from public.pr_requests pr where pr.id=p_purchase_request_id) then
    raise exception 'Purchase request not found';
  end if;

  insert into public.cmms_work_order_purchase_links(
    work_order_id,purchase_request_id,created_by
  ) values(p_work_order_id,p_purchase_request_id,auth.uid())
  returning id into v_link_id;

  return v_link_id;
end;
$$;

create or replace function cmms_private.cmms_create_location(
  p_code text,
  p_name text,
  p_discipline text,
  p_parent_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not cmms_private.cmms_has_any_role(array['technical_supervisor']) then
    raise exception 'Only the technical supervisor may create locations';
  end if;
  if nullif(btrim(coalesce(p_code,'')),'') is null
     or nullif(btrim(coalesce(p_name,'')),'') is null then
    raise exception 'Location code and name are required';
  end if;
  if p_parent_id is not null and not exists (
    select 1 from public.cmms_locations where id=p_parent_id and is_active
  ) then
    raise exception 'Parent location is missing or inactive';
  end if;

  insert into public.cmms_locations(code,name,discipline,parent_id)
  values(btrim(p_code),btrim(p_name),p_discipline,p_parent_id)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function cmms_private.cmms_create_asset(
  p_asset_code text,
  p_name text,
  p_location_id uuid,
  p_criticality text default 'medium',
  p_category_id uuid default null,
  p_manufacturer text default null,
  p_model text default null,
  p_serial_number text default null,
  p_technical_specs jsonb default '{}'::jsonb,
  p_equipment_owner text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not cmms_private.cmms_has_any_role(array['technical_supervisor','technical_expert']) then
    raise exception 'Only technical supervisor or expert may register assets';
  end if;
  if nullif(btrim(coalesce(p_asset_code,'')),'') is null
     or nullif(btrim(coalesce(p_name,'')),'') is null then
    raise exception 'Asset code and name are required';
  end if;
  if not exists(select 1 from public.cmms_locations where id=p_location_id and is_active) then
    raise exception 'Asset location is missing or inactive';
  end if;
  if p_category_id is not null and not exists(
    select 1 from public.cmms_asset_categories where id=p_category_id
  ) then
    raise exception 'Asset category not found';
  end if;

  insert into public.cmms_assets(
    asset_code,name,location_id,criticality,category_id,manufacturer,model,
    serial_number,technical_specs,equipment_owner,created_by
  ) values (
    btrim(p_asset_code),btrim(p_name),p_location_id,p_criticality,p_category_id,
    nullif(btrim(p_manufacturer),''),nullif(btrim(p_model),''),nullif(btrim(p_serial_number),''),
    coalesce(p_technical_specs,'{}'::jsonb),nullif(btrim(p_equipment_owner),''),auth.uid()
  ) returning id into v_id;

  return v_id;
end;
$$;

-- Public API wrappers are SECURITY INVOKER, not SECURITY DEFINER.
create or replace function public.cmms_report_failure(
  p_asset_id uuid,p_priority text,p_description text,p_symptoms text default null,
  p_production_impact text default null,p_safety_impact text default null,
  p_environmental_impact text default null,p_attachment_paths text[] default '{}'::text[],
  p_downtime_started_at timestamptz default null
) returns uuid as $$ select cmms_private.cmms_report_failure($1,$2,$3,$4,$5,$6,$7,$8,$9); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_triage_failure(p_failure_report_id uuid,p_decision text,p_note text default null)
returns uuid as $$ select cmms_private.cmms_triage_failure($1,$2,$3); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_create_work_order(
  p_asset_id uuid,p_title text,p_work_type text,p_priority text default 'normal',
  p_description text default null,p_scope text default null,p_planned_start_at timestamptz default null,
  p_due_at timestamptz default null,p_estimated_duration_minutes integer default null,
  p_permit_required boolean default false,p_permit_reference text default null,
  p_isolation_required boolean default false
) returns uuid as $$ select cmms_private.cmms_create_work_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12); $$ language sql security invoker set search_path='';

create or replace function public.cmms_release_work_order(p_work_order_id uuid)
returns text as $$ select cmms_private.cmms_release_work_order($1); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_assign_work_order(p_work_order_id uuid,p_assignee_id uuid)
returns uuid as $$ select cmms_private.cmms_assign_work_order($1,$2); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_record_work_order_action(
  p_work_order_id uuid,p_action_type text,p_description text,p_duration_minutes integer default null,
  p_quantity numeric default null,p_unit text default null,p_meter_reading numeric default null,
  p_attachment_paths text[] default '{}'::text[]
) returns uuid as $$ select cmms_private.cmms_record_work_order_action($1,$2,$3,$4,$5,$6,$7,$8); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_set_work_order_progress(p_work_order_id uuid,p_next_status text)
returns text as $$ select cmms_private.cmms_set_work_order_progress($1,$2); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_submit_work_order_test(
  p_work_order_id uuid,p_test_result text,p_return_to_service_status text,
  p_returned_to_service_at timestamptz,p_test_description text,p_attachment_paths text[] default '{}'::text[]
) returns text as $$ select cmms_private.cmms_submit_work_order_test($1,$2,$3,$4,$5,$6); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_decide_work_order(
  p_work_order_id uuid,p_stage text,p_decision text,p_note text default null
) returns text as $$ select cmms_private.cmms_decide_work_order($1,$2,$3,$4); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_record_meter_reading(
  p_asset_id uuid,p_meter_code text,p_meter_unit text,p_meter_value numeric
) returns uuid as $$ select cmms_private.cmms_record_meter_reading($1,$2,$3,$4); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_assign_pm_task(p_pm_task_id uuid,p_assignee_id uuid)
returns uuid as $$ select cmms_private.cmms_assign_pm_task($1,$2); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_cancel_work_order(p_work_order_id uuid,p_reason text)
returns text as $$ select cmms_private.cmms_cancel_work_order($1,$2); $$ language sql security invoker set search_path='';

create or replace function public.cmms_reassign_work_order(p_assignment_id uuid,p_new_assignee_id uuid,p_reason text)
returns uuid as $$ select cmms_private.cmms_reassign_work_order($1,$2,$3); $$ language sql security invoker set search_path='';

create or replace function public.cmms_link_purchase_request(p_work_order_id uuid,p_purchase_request_id text)
returns uuid as $$ select cmms_private.cmms_link_purchase_request($1,$2); $$ language sql security invoker set search_path='';

create or replace function public.cmms_create_pm_plan(
  p_asset_id uuid,p_title text,p_frequency_basis text,p_frequency_unit text,
  p_frequency_value numeric,p_meter_code text,p_meter_unit text,p_next_due_at timestamptz,
  p_next_due_meter_value numeric,p_checklist jsonb
) returns uuid as $$ select cmms_private.cmms_create_pm_plan($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $$ language sql security invoker set search_path='';

create or replace function public.cmms_update_asset(
  p_asset_id uuid,p_asset_code text,p_name text,p_location_id uuid,p_criticality text,
  p_category_id uuid,p_manufacturer text,p_model text,p_serial_number text,
  p_technical_specs jsonb,p_equipment_owner text,p_attachment_paths text[]
) returns uuid as $$ select cmms_private.cmms_update_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12); $$ language sql security invoker set search_path='';

create or replace function public.cmms_change_asset_status(p_asset_id uuid,p_new_status text,p_reason text)
returns uuid as $$ select cmms_private.cmms_change_asset_status($1,$2,$3); $$ language sql security invoker set search_path='';

create or replace function public.cmms_update_pm_plan(
  p_pm_plan_id uuid,p_title text,p_frequency_basis text,p_frequency_unit text,
  p_frequency_value numeric,p_meter_code text,p_meter_unit text,p_next_due_at timestamptz,
  p_next_due_meter_value numeric,p_checklist jsonb
) returns uuid as $$ select cmms_private.cmms_update_pm_plan($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $$ language sql security invoker set search_path='';

create or replace function public.cmms_set_pm_plan_active(p_pm_plan_id uuid,p_is_active boolean)
returns uuid as $$ select cmms_private.cmms_set_pm_plan_active($1,$2); $$ language sql security invoker set search_path='';

create or replace function public.cmms_start_pm_task(p_pm_task_id uuid)
returns uuid as $$ select cmms_private.cmms_start_pm_task($1); $$ language sql security invoker set search_path='';

create or replace function public.cmms_create_location(p_code text,p_name text,p_discipline text,p_parent_id uuid default null)
returns uuid as $$ select cmms_private.cmms_create_location($1,$2,$3,$4); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_create_asset(
  p_asset_code text,p_name text,p_location_id uuid,p_criticality text default 'medium',
  p_category_id uuid default null,p_manufacturer text default null,p_model text default null,
  p_serial_number text default null,p_technical_specs jsonb default '{}'::jsonb,p_equipment_owner text default null
) returns uuid as $$ select cmms_private.cmms_create_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_complete_pm_task(p_pm_task_id uuid,p_checklist_result jsonb)
returns uuid as $$ select cmms_private.cmms_complete_pm_task($1,$2); $$ language sql security invoker set search_path = '';

-- Internal functions are not directly exposed as RPC endpoints.
revoke all on all functions in schema cmms_private from public, anon, authenticated;
grant usage on schema cmms_private to authenticated, service_role;
grant execute on function cmms_private.cmms_report_failure(uuid,text,text,text,text,text,text,text[],timestamptz) to authenticated;
grant execute on function cmms_private.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function cmms_private.cmms_create_work_order(uuid,text,text,text,text,text,timestamptz,timestamptz,integer,boolean,text,boolean) to authenticated;
grant execute on function cmms_private.cmms_release_work_order(uuid) to authenticated;
grant execute on function cmms_private.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function cmms_private.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function cmms_private.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function cmms_private.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function cmms_private.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
grant execute on function cmms_private.cmms_update_asset(uuid,text,text,uuid,text,uuid,text,text,text,jsonb,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_change_asset_status(uuid,text,text) to authenticated;
grant execute on function cmms_private.cmms_update_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
grant execute on function cmms_private.cmms_set_pm_plan_active(uuid,boolean) to authenticated;
grant execute on function cmms_private.cmms_start_pm_task(uuid) to authenticated;
grant execute on function cmms_private.cmms_complete_pm_task(uuid,jsonb) to authenticated;
grant execute on function cmms_private.cmms_create_location(text,text,text,uuid) to authenticated;
grant execute on function cmms_private.cmms_create_asset(text,text,uuid,text,uuid,text,text,text,jsonb,text) to authenticated;
grant execute on function cmms_private.cmms_cancel_work_order(uuid,text) to authenticated;

grant execute on function cmms_private.cmms_record_meter_reading(uuid,text,text,numeric) to authenticated;
grant execute on function cmms_private.cmms_assign_pm_task(uuid,uuid) to authenticated;
grant execute on function cmms_private.cmms_reassign_work_order(uuid,uuid,text) to authenticated;
grant execute on function cmms_private.cmms_link_purchase_request(uuid,text) to authenticated;

revoke all on function cmms_private.cmms_generate_due_pm_tasks() from public,anon,authenticated;
grant execute on function cmms_private.cmms_generate_due_pm_tasks() to service_role;
grant execute on function cmms_private.cmms_has_any_role(text[]) to authenticated;
grant execute on function cmms_private.cmms_has_role_at_location(text[],uuid) to authenticated;
-- cmms_user_has_active_role remains owner-only; workflow SECURITY DEFINER routines call it as owner.

revoke all on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[],timestamptz) from public, anon;
revoke all on function public.cmms_triage_failure(uuid,text,text) from public, anon;
revoke all on function public.cmms_create_work_order(uuid,text,text,text,text,text,timestamptz,timestamptz,integer,boolean,text,boolean) from public, anon;
revoke all on function public.cmms_release_work_order(uuid) from public, anon;
revoke all on function public.cmms_assign_work_order(uuid,uuid) from public, anon;
revoke all on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) from public, anon;
revoke all on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) from public, anon;
revoke all on function public.cmms_set_work_order_progress(uuid,text) from public, anon;
revoke all on function public.cmms_decide_work_order(uuid,text,text,text) from public, anon;
revoke all on function public.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) from public, anon;
revoke all on function public.cmms_update_asset(uuid,text,text,uuid,text,uuid,text,text,text,jsonb,text,text[]) from public, anon;
revoke all on function public.cmms_change_asset_status(uuid,text,text) from public, anon;
revoke all on function public.cmms_update_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) from public, anon;
revoke all on function public.cmms_set_pm_plan_active(uuid,boolean) from public, anon;
revoke all on function public.cmms_start_pm_task(uuid) from public, anon;
revoke all on function public.cmms_create_location(text,text,text,uuid) from public, anon;
revoke all on function public.cmms_create_asset(text,text,uuid,text,uuid,text,text,text,jsonb,text) from public, anon;
revoke all on function public.cmms_cancel_work_order(uuid,text) from public, anon;
revoke all on function public.cmms_complete_pm_task(uuid,jsonb) from public, anon;
revoke all on function public.cmms_reassign_work_order(uuid,uuid,text) from public, anon;
revoke all on function public.cmms_link_purchase_request(uuid,text) from public, anon;

revoke all on function public.cmms_record_meter_reading(uuid,text,text,numeric) from public, anon;
revoke all on function public.cmms_assign_pm_task(uuid,uuid) from public, anon;

grant execute on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[],timestamptz) to authenticated;
grant execute on function public.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function public.cmms_create_work_order(uuid,text,text,text,text,text,timestamptz,timestamptz,integer,boolean,text,boolean) to authenticated;
grant execute on function public.cmms_release_work_order(uuid) to authenticated;
grant execute on function public.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function public.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function public.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function public.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
grant execute on function public.cmms_update_asset(uuid,text,text,uuid,text,uuid,text,text,text,jsonb,text,text[]) to authenticated;
grant execute on function public.cmms_change_asset_status(uuid,text,text) to authenticated;
grant execute on function public.cmms_update_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
grant execute on function public.cmms_set_pm_plan_active(uuid,boolean) to authenticated;
grant execute on function public.cmms_start_pm_task(uuid) to authenticated;
grant execute on function public.cmms_complete_pm_task(uuid,jsonb) to authenticated;
grant execute on function public.cmms_create_location(text,text,text,uuid) to authenticated;
grant execute on function public.cmms_create_asset(text,text,uuid,text,uuid,text,text,text,jsonb,text) to authenticated;
grant execute on function public.cmms_cancel_work_order(uuid,text) to authenticated;

grant execute on function public.cmms_reassign_work_order(uuid,uuid,text) to authenticated;
grant execute on function public.cmms_link_purchase_request(uuid,text) to authenticated;

grant execute on function public.cmms_record_meter_reading(uuid,text,text,numeric) to authenticated;
grant execute on function public.cmms_assign_pm_task(uuid,uuid) to authenticated;

-- Remaining v1 server-side work before release:
-- * scheduling cmms_private.cmms_generate_due_pm_tasks() with pg_cron or a service-role scheduler;
-- * report export, notification delivery, and PM-failure-to-corrective-work-order RPC;
-- * integration tests in isolated PostgreSQL/Supabase staging;
-- * verify every status transition against the hardening trigger and audit log.


-- =====================================================================
-- SOURCE: supabase/drafts/cmms_v1_p1_business_rules_STAGING_ONLY.sql
-- =====================================================================
-- CMMS V1 P1 business-rule hardening — STAGING ONLY
-- Drafted from read-only Production function definitions on 2026-11-18.
-- DO NOT APPLY TO PRODUCTION. Applied successfully to isolated Staging on 2026-11-18; partial workflow/retirement tests passed. Remaining edge-case and concurrency tests are still required.
-- Preconditions: isolated staging schema/data, backup/restore path, and review of the audit report.
-- Locking: asset rows are locked FOR SHARE in write operations; retirement uses FOR UPDATE.
-- This serializes retirement against new meter readings, PM plan changes and failure conversion.

-- 1) Retiring an asset is blocked while it has active work orders or active PM plans.
create or replace function cmms_private.cmms_change_asset_status(
  p_asset_id uuid, p_new_status text, p_reason text
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_location_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_new_status not in ('operational','degraded','stopped','under_maintenance','retired') then
    raise exception 'Invalid asset operational status';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Asset status-change reason is mandatory';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=p_asset_id
  for update;
  if not found then raise exception 'Asset not found'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can change asset status'; end if;

  if p_new_status='retired' then
    if exists (
      select 1 from public.cmms_work_orders w
      where w.asset_id=p_asset_id and w.status not in ('closed','cancelled')
    ) then
      raise exception 'Cannot retire asset while active work orders exist';
    end if;
    if exists (
      select 1 from public.cmms_pm_plans p
      where p.asset_id=p_asset_id and p.is_active
    ) then
      raise exception 'Cannot retire asset while active PM plans exist; deactivate them first';
    end if;
  end if;

  perform set_config('cmms.status_change_reason',btrim(p_reason),true);
  update public.cmms_assets set operational_status=p_new_status,updated_at=now()
  where id=p_asset_id;
  perform set_config('cmms.status_change_reason','',true);
  return p_asset_id;
end;
$function$;

-- 2) Meter readings: non-negative finite values; reject retired assets.
create or replace function cmms_private.cmms_record_meter_reading(
  p_asset_id uuid, p_meter_code text, p_meter_unit text, p_meter_value numeric
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_location_id uuid;
  v_asset_status text;
  v_reading_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_meter_code,'')),'') is null
     or nullif(btrim(coalesce(p_meter_unit,'')),'') is null
     or p_meter_value is null or p_meter_value < 0
     or p_meter_value::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Valid meter code, unit and finite non-negative reading are required';
  end if;

  select a.location_id,a.operational_status into v_location_id,v_asset_status
  from public.cmms_assets a where a.id=p_asset_id
  for share;
  if not found then raise exception 'Asset not found'; end if;
  if v_asset_status='retired' then raise exception 'Cannot record meter reading for a retired asset'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technician','technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'No permission to record meter readings for this asset';
  end if;

  insert into public.cmms_asset_meter_readings(
    asset_id,meter_code,meter_unit,meter_value,recorded_by,source
  ) values (
    p_asset_id,btrim(p_meter_code),btrim(p_meter_unit),p_meter_value,auth.uid(),'manual'
  ) returning id into v_reading_id;
  return v_reading_id;
end;
$function$;

-- 3) PM creation: lock and reject retired equipment.
create or replace function cmms_private.cmms_create_pm_plan(
  p_asset_id uuid, p_title text, p_frequency_basis text, p_frequency_unit text,
  p_frequency_value numeric, p_meter_code text, p_meter_unit text,
  p_next_due_at timestamptz, p_next_due_meter_value numeric, p_checklist jsonb
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_location_id uuid;
  v_asset_status text;
  v_plan_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_title,'')), '') is null then raise exception 'PM plan title is required'; end if;
  if p_frequency_value is null or p_frequency_value <= 0
     or p_frequency_value::text in ('NaN','Infinity','-Infinity') then
    raise exception 'PM frequency must be positive and finite';
  end if;
  if p_checklist is null or not (
    (jsonb_typeof(p_checklist)='array' and p_checklist <> '[]'::jsonb)
    or (jsonb_typeof(p_checklist)='object' and p_checklist <> '{}'::jsonb)
  ) then raise exception 'A non-empty PM checklist is required'; end if;

  select a.location_id,a.operational_status into v_location_id,v_asset_status
  from public.cmms_assets a where a.id=p_asset_id for share;
  if not found then raise exception 'Asset not found'; end if;
  if v_asset_status='retired' then raise exception 'Cannot create PM plan for a retired asset'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can create PM plans'; end if;

  if p_frequency_basis='calendar' then
    if p_frequency_unit not in ('day','week','month','year')
       or p_frequency_value <> trunc(p_frequency_value)
       or p_next_due_at is null
       or p_meter_code is not null or p_meter_unit is not null or p_next_due_meter_value is not null then
      raise exception 'Invalid calendar PM frequency configuration';
    end if;
  elsif p_frequency_basis='meter' then
    if p_frequency_unit not in ('hour','cycle')
       or nullif(btrim(coalesce(p_meter_code,'')),'') is null
       or nullif(btrim(coalesce(p_meter_unit,'')),'') is null
       or p_next_due_meter_value is null or p_next_due_meter_value < 0
       or p_next_due_meter_value::text in ('NaN','Infinity','-Infinity')
       or p_next_due_at is not null then
      raise exception 'Invalid meter PM frequency configuration';
    end if;
  else
    raise exception 'V1 supports calendar or meter PM plans only';
  end if;

  insert into public.cmms_pm_plans(
    asset_id,title,frequency_basis,frequency_unit,frequency_value,
    meter_code,meter_unit,next_due_at,next_due_meter_value,checklist,created_by
  ) values (
    p_asset_id,btrim(p_title),p_frequency_basis,p_frequency_unit,p_frequency_value,
    nullif(btrim(coalesce(p_meter_code,'')),''),nullif(btrim(coalesce(p_meter_unit,'')),''),
    p_next_due_at,p_next_due_meter_value,p_checklist,auth.uid()
  ) returning id into v_plan_id;
  return v_plan_id;
end;
$function$;

-- 4) PM updates: re-check the linked asset status under a row lock.
create or replace function cmms_private.cmms_update_pm_plan(
  p_pm_plan_id uuid, p_title text, p_frequency_basis text, p_frequency_unit text,
  p_frequency_value numeric, p_meter_code text, p_meter_unit text,
  p_next_due_at timestamptz, p_next_due_meter_value numeric, p_checklist jsonb
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_location_id uuid;
  v_asset_status text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_title,'')), '') is null then raise exception 'PM plan title is required'; end if;
  if p_frequency_value is null or p_frequency_value <= 0
     or p_frequency_value::text in ('NaN','Infinity','-Infinity') then
    raise exception 'PM frequency must be positive and finite';
  end if;
  if p_checklist is null or not (
    (jsonb_typeof(p_checklist)='array' and p_checklist <> '[]'::jsonb)
    or (jsonb_typeof(p_checklist)='object' and p_checklist <> '{}'::jsonb)
  ) then raise exception 'A non-empty PM checklist is required'; end if;

  select a.location_id,a.operational_status into v_location_id,v_asset_status
  from public.cmms_pm_plans p join public.cmms_assets a on a.id=p.asset_id
  where p.id=p_pm_plan_id
  for update of p
  for share of a;
  if not found then raise exception 'PM plan not found'; end if;
  if v_asset_status='retired' then raise exception 'Cannot update PM plan for a retired asset'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can update PM plans'; end if;

  if p_frequency_basis='calendar' then
    if p_frequency_unit not in ('day','week','month','year')
       or p_frequency_value <> trunc(p_frequency_value)
       or p_next_due_at is null
       or p_meter_code is not null or p_meter_unit is not null or p_next_due_meter_value is not null then
      raise exception 'Invalid calendar PM frequency configuration';
    end if;
  elsif p_frequency_basis='meter' then
    if p_frequency_unit not in ('hour','cycle')
       or nullif(btrim(coalesce(p_meter_code,'')),'') is null
       or nullif(btrim(coalesce(p_meter_unit,'')),'') is null
       or p_next_due_meter_value is null or p_next_due_meter_value < 0
       or p_next_due_meter_value::text in ('NaN','Infinity','-Infinity')
       or p_next_due_at is not null then
      raise exception 'Invalid meter PM frequency configuration';
    end if;
  else
    raise exception 'V1 supports calendar or meter PM plans only';
  end if;

  update public.cmms_pm_plans
  set title=btrim(p_title),frequency_basis=p_frequency_basis,
      frequency_unit=p_frequency_unit,frequency_value=p_frequency_value,
      meter_code=nullif(btrim(coalesce(p_meter_code,'')),''),
      meter_unit=nullif(btrim(coalesce(p_meter_unit,'')),''),
      next_due_at=p_next_due_at,next_due_meter_value=p_next_due_meter_value,
      checklist=p_checklist
  where id=p_pm_plan_id;
  return p_pm_plan_id;
end;
$function$;

-- 5) PM scheduler: skip retired equipment and lock asset rows to serialize with retirement.
create or replace function cmms_private.cmms_generate_due_pm_tasks()
returns integer
language plpgsql security definer set search_path = ''
as $function$
declare
  v_plan public.cmms_pm_plans%rowtype;
  v_latest_meter numeric(14,3);
  v_next_due_at timestamptz;
  v_next_due_meter numeric(14,3);
  v_created integer := 0;
  v_rows integer;
  v_runs integer;
begin
  for v_plan in
    select p.* from public.cmms_pm_plans p
    join public.cmms_assets a on a.id=p.asset_id
    where p.is_active and a.operational_status <> 'retired'
    order by p.created_at,p.id
    for update of p
    for share of a skip locked
  loop
    v_runs := 0;
    if v_plan.frequency_basis='calendar' then
      v_next_due_at := v_plan.next_due_at;
      while v_next_due_at <= now() and v_runs < 100 loop
        insert into public.cmms_pm_tasks(pm_plan_id,asset_id,due_at,trigger_type,status)
        values(v_plan.id,v_plan.asset_id,v_next_due_at,'calendar','due')
        on conflict do nothing;
        get diagnostics v_rows = row_count;
        v_created := v_created + v_rows;
        v_next_due_at := case v_plan.frequency_unit
          when 'day' then v_next_due_at + make_interval(days => v_plan.frequency_value::integer)
          when 'week' then v_next_due_at + make_interval(weeks => v_plan.frequency_value::integer)
          when 'month' then v_next_due_at + make_interval(months => v_plan.frequency_value::integer)
          when 'year' then v_next_due_at + make_interval(years => v_plan.frequency_value::integer)
        end;
        v_runs := v_runs + 1;
      end loop;
      update public.cmms_pm_plans set next_due_at=v_next_due_at where id=v_plan.id;
    elsif v_plan.frequency_basis='meter' then
      select mr.meter_value into v_latest_meter
      from public.cmms_asset_meter_readings mr
      where mr.asset_id=v_plan.asset_id
        and mr.meter_code=v_plan.meter_code and mr.meter_unit=v_plan.meter_unit
      order by mr.reading_at desc,mr.created_at desc limit 1;
      if v_latest_meter is null then continue; end if;
      v_next_due_meter := v_plan.next_due_meter_value;
      while v_next_due_meter <= v_latest_meter and v_runs < 100 loop
        insert into public.cmms_pm_tasks(pm_plan_id,asset_id,due_meter_value,trigger_type,status)
        values(v_plan.id,v_plan.asset_id,v_next_due_meter,'meter','due')
        on conflict do nothing;
        get diagnostics v_rows = row_count;
        v_created := v_created + v_rows;
        v_next_due_meter := v_next_due_meter + v_plan.frequency_value;
        v_runs := v_runs + 1;
      end loop;
      update public.cmms_pm_plans
      set next_due_meter_value=v_next_due_meter,last_meter_value=v_latest_meter
      where id=v_plan.id;
    end if;
  end loop;
  return v_created;
end;
$function$;

-- 6) Failure conversion: lock/recheck asset status after locking the report.
create or replace function cmms_private.cmms_triage_failure(
  p_failure_report_id uuid, p_decision text, p_note text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_report public.cmms_failure_reports%rowtype;
  v_location_id uuid;
  v_asset_status text;
  v_work_order_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_decision is null or p_decision not in ('convert','reject') then raise exception 'Invalid triage decision'; end if;
  if p_decision='reject' and nullif(btrim(coalesce(p_note,'')), '') is null then
    raise exception 'Rejection reason is required';
  end if;

  select fr.* into v_report from public.cmms_failure_reports fr
  where fr.id=p_failure_report_id for update;
  if not found or v_report.status not in ('submitted','under_review') then
    raise exception 'Failure report is not available for triage';
  end if;

  select a.location_id,a.operational_status into v_location_id,v_asset_status
  from public.cmms_assets a where a.id=v_report.asset_id for share;
  if not found then raise exception 'Failure report asset no longer exists'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can triage failures'; end if;

  if p_decision='convert' and v_asset_status='retired' then
    raise exception 'Cannot convert failure report: asset has been retired';
  end if;

  if p_decision='reject' then
    update public.cmms_failure_reports
    set status='rejected',reviewed_by=auth.uid(),reviewed_at=now(),review_note=btrim(p_note)
    where id=p_failure_report_id;
    return null;
  end if;

  insert into public.cmms_work_orders(
    asset_id,failure_report_id,title,description,work_type,priority,status,opened_by
  ) values (
    v_report.asset_id,v_report.id,left(v_report.description,120),v_report.description,
    'corrective',v_report.priority,'triage',auth.uid()
  ) returning id into v_work_order_id;

  update public.cmms_failure_reports
  set status='converted',reviewed_by=auth.uid(),reviewed_at=now(),review_note=coalesce(p_note,'')
  where id=p_failure_report_id;
  return v_work_order_id;
end;
$function$;

-- 7) Work-order action measurements must be finite and non-negative.
create or replace function cmms_private.cmms_record_work_order_action(
  p_work_order_id uuid, p_action_type text, p_description text,
  p_duration_minutes integer default null, p_quantity numeric default null,
  p_unit text default null, p_meter_reading numeric default null,
  p_attachment_paths text[] default '{}'::text[]
) returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_action_id uuid;
  v_is_assigned boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_description,'')), '') is null then
    raise exception 'Action description is required';
  end if;
  if p_duration_minutes is not null and p_duration_minutes < 0 then
    raise exception 'Duration must be non-negative';
  end if;
  if p_quantity is not null and (
    p_quantity < 0 or p_quantity::text in ('NaN','Infinity','-Infinity')
  ) then raise exception 'Quantity must be finite and non-negative'; end if;
  if p_meter_reading is not null and (
    p_meter_reading < 0 or p_meter_reading::text in ('NaN','Infinity','-Infinity')
  ) then raise exception 'Meter reading must be finite and non-negative'; end if;

  select w.* into v_wo from public.cmms_work_orders w
  where w.id=p_work_order_id for key share;
  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Work order is not active';
  end if;

  select a.location_id into v_location_id from public.cmms_assets a where a.id=v_wo.asset_id;
  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=p_work_order_id and wa.user_id=auth.uid()
      and wa.unassigned_at is null
  ) into v_is_assigned;

  if v_is_assigned then
    if not cmms_private.cmms_user_has_active_role(auth.uid(),array['technician','technical_expert']) then
      raise exception 'Assigned user no longer has an active CMMS execution role';
    end if;
  elsif not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned active workers or technical supervisors/experts can log actions';
  end if;

  insert into public.cmms_work_order_actions(
    work_order_id,actor_id,action_type,description,duration_minutes,
    quantity,unit,meter_reading,attachment_paths
  ) values (
    p_work_order_id,auth.uid(),p_action_type,btrim(p_description),p_duration_minutes,
    p_quantity,p_unit,p_meter_reading,coalesce(p_attachment_paths,'{}'::text[])
  ) returning id into v_action_id;
  return v_action_id;
end;
$function$;

-- Required staging verification:
-- * Compile all replaced functions against staging schema before runtime tests.
-- * Assert retired asset cannot receive manual meter readings, PM plan create/update,
--   scheduler-generated PM tasks, or failure->WO conversion.
-- * Assert retirement is denied with any nonterminal work order or active PM plan.
-- * Assert negative, NaN, and +/-Infinity quantity/meter_reading are rejected.
-- * Assert zero values remain accepted; positive values remain accepted.
-- * Run concurrent test: retirement vs meter reading / PM update / scheduler.


-- =====================================================================
-- SOURCE: supabase/drafts/cmms_v1_purchase_link_hardening_STAGING_ONLY.sql
-- =====================================================================
-- CMMS V1 purchase-request link authorization hardening.
-- DRAFT ONLY — apply and test in isolated Staging after schema reconciliation.
-- Does not grant EXECUTE to API roles and does not modify the live purchase module.

create or replace function cmms_private.cmms_link_purchase_request(
  p_work_order_id uuid,
  p_purchase_request_id text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_link_id uuid;
  v_request_created_by uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if nullif(btrim(coalesce(p_purchase_request_id,'')),'') is null then
    raise exception 'Purchase request id is required';
  end if;

  -- Serialize against concurrent status transitions so a closed/cancelled WO
  -- cannot pass this check while another transaction closes it.
  select w.* into v_wo
  from public.cmms_work_orders w
  where w.id=p_work_order_id
  for update;

  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Only an open work order can be linked to a purchase request';
  end if;

  -- Lock asset location while authorization is evaluated.
  select a.location_id into v_location_id
  from public.cmms_assets a
  where a.id=v_wo.asset_id
  for share;

  if not found then
    raise exception 'Work order asset not found';
  end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then
    raise exception 'Only technical supervisor or expert can link a purchase request';
  end if;

  -- SECURITY DEFINER bypasses pr_requests RLS. Reproduce its current SELECT
  -- policy explicitly: any active internal profile role may read requests.
  if not exists (
    select 1 from public.user_profiles up
    where up.user_id=auth.uid()
      and up.is_active
      and up.role in ('admin','tech','maintenance','planner','procurement')
  ) then
    raise exception 'User is not authorized to access purchase requests';
  end if;

  -- Lock the request row so its existence/creator cannot change during linking.
  select pr.created_by into v_request_created_by
  from public.pr_requests pr
  where pr.id=p_purchase_request_id
  for share;

  if not found then
    raise exception 'Purchase request not found';
  end if;

  if v_request_created_by is null then
    raise exception 'Purchase request has no accountable creator';
  end if;

  insert into public.cmms_work_order_purchase_links(
    work_order_id,purchase_request_id,created_by
  )
  values(p_work_order_id,p_purchase_request_id,auth.uid())
  on conflict (work_order_id,purchase_request_id) do nothing
  returning id into v_link_id;

  if v_link_id is null then
    select l.id into v_link_id
    from public.cmms_work_order_purchase_links l
    where l.work_order_id=p_work_order_id
      and l.purchase_request_id=p_purchase_request_id;
  end if;

  return v_link_id;
end;
$function$;

-- The public SECURITY INVOKER wrapper, if present, must remain SECURITY INVOKER.
-- Do not grant broad EXECUTE. The exact private-function EXECUTE grant belongs
-- in the separately reviewed RPC privilege-chain migration after tests.


-- =====================================================================
-- SOURCE: supabase/drafts/cmms_v1_fk_indexes_STAGING_ONLY.sql
-- =====================================================================
-- CMMS V1 foreign-key supporting indexes — STAGING ONLY
-- Generated from Supabase Performance Advisor findings on isolated Staging.
-- Additive only. Do not apply to Production until external backup/restore and release review.
-- These indexes support FK checks, joins and delete/update referential-integrity work.

create index if not exists cmms_asset_meter_readings_recorded_by_idx
  on public.cmms_asset_meter_readings(recorded_by);
create index if not exists cmms_asset_status_history_asset_id_idx
  on public.cmms_asset_status_history(asset_id);
create index if not exists cmms_asset_status_history_changed_by_idx
  on public.cmms_asset_status_history(changed_by);
create index if not exists cmms_assets_created_by_idx
  on public.cmms_assets(created_by);
create index if not exists cmms_audit_logs_actor_id_idx
  on public.cmms_audit_logs(actor_id);
create index if not exists cmms_failure_reports_reviewed_by_idx
  on public.cmms_failure_reports(reviewed_by);
create index if not exists cmms_locations_manager_user_id_idx
  on public.cmms_locations(manager_user_id);
create index if not exists cmms_locations_parent_id_idx
  on public.cmms_locations(parent_id);
create index if not exists cmms_pm_plans_asset_id_idx
  on public.cmms_pm_plans(asset_id);
create index if not exists cmms_pm_plans_created_by_idx
  on public.cmms_pm_plans(created_by);
create index if not exists cmms_pm_tasks_asset_id_idx
  on public.cmms_pm_tasks(asset_id);
create index if not exists cmms_pm_tasks_assigned_to_idx
  on public.cmms_pm_tasks(assigned_to);
create index if not exists cmms_pm_tasks_completed_by_idx
  on public.cmms_pm_tasks(completed_by);
create index if not exists cmms_user_roles_location_id_idx
  on public.cmms_user_roles(location_id);
create index if not exists cmms_work_order_actions_actor_id_idx
  on public.cmms_work_order_actions(actor_id);
create index if not exists cmms_work_order_actions_work_order_id_idx
  on public.cmms_work_order_actions(work_order_id);
create index if not exists cmms_work_order_approvals_approver_id_idx
  on public.cmms_work_order_approvals(approver_id);
create index if not exists cmms_work_order_assignments_assigned_by_idx
  on public.cmms_work_order_assignments(assigned_by);
create index if not exists cmms_work_order_purchase_links_created_by_idx
  on public.cmms_work_order_purchase_links(created_by);
create index if not exists cmms_work_order_purchase_links_purchase_request_id_idx
  on public.cmms_work_order_purchase_links(purchase_request_id);
create index if not exists cmms_work_orders_manager_approved_by_idx
  on public.cmms_work_orders(manager_approved_by);
create index if not exists cmms_work_orders_opened_by_idx
  on public.cmms_work_orders(opened_by);
create index if not exists cmms_work_orders_supervisor_approved_by_idx
  on public.cmms_work_orders(supervisor_approved_by);


-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_storage_policy_draft.sql
-- =====================================================================
-- DRAFT ONLY — private evidence bucket and hardened row-level object policies.
-- STAGING ONLY. Do not apply to Production.
-- Path: cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}
-- record_type: assets | failures | work-orders | pm
-- Objects are immutable: no UPDATE or DELETE policies are created.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'cmms-evidence','cmms-evidence',false,10485760,
  array[
    'application/pdf','image/jpeg','image/png','image/webp',
    'image/heic','image/heif','text/csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
)
on conflict (id) do update
set public=false,file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists cmms_evidence_read_by_location on storage.objects;
drop policy if exists cmms_evidence_upload_by_location on storage.objects;

-- A syntactically valid path is not sufficient: the linked record must exist
-- and belong to the asset UUID embedded in the path.
create policy cmms_evidence_read_by_location
on storage.objects for select to authenticated
using (
  bucket_id='cmms-evidence'
  and array_length(string_to_array(storage.objects.name,'/'),1)=5
  and split_part(storage.objects.name,'/',1)='cmms'
  and split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',5) <> ''
  and split_part(storage.objects.name,'/',5) not in ('.','..')
  and position(chr(92) in storage.objects.name)=0
  and exists (
    select 1
    from public.cmms_assets a
    where a.id=case when split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',2)::uuid else null end
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
      and (
        (split_part(storage.objects.name,'/',3)='assets' and split_part(storage.objects.name,'/',4)=a.id::text)
        or (split_part(storage.objects.name,'/',3)='failures' and exists (
          select 1 from public.cmms_failure_reports fr
          where fr.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and fr.asset_id=a.id
        ))
        or (split_part(storage.objects.name,'/',3)='work-orders' and exists (
          select 1 from public.cmms_work_orders wo
          where wo.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and wo.asset_id=a.id
        ))
        or (split_part(storage.objects.name,'/',3)='pm' and exists (
          select 1 from public.cmms_pm_tasks pt
          where pt.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and pt.asset_id=a.id
        ))
      )
  )
);

create policy cmms_evidence_upload_by_location
on storage.objects for insert to authenticated
with check (
  bucket_id='cmms-evidence'
  and array_length(string_to_array(storage.objects.name,'/'),1)=5
  and split_part(storage.objects.name,'/',1)='cmms'
  and split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',5) <> ''
  and split_part(storage.objects.name,'/',5) not in ('.','..')
  and position(chr(92) in storage.objects.name)=0
  and exists (
    select 1 from public.cmms_assets a
    where a.id=case when split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',2)::uuid else null end
      and (
        (split_part(storage.objects.name,'/',3)='assets'
          and split_part(storage.objects.name,'/',4)=a.id::text
          and (select cmms_private.cmms_has_role_at_location(
            array['technical_expert','technical_supervisor'],a.location_id
          )))
        or
        (split_part(storage.objects.name,'/',3)='failures'
          and exists (
            select 1 from public.cmms_failure_reports fr
            where fr.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and fr.asset_id=a.id
              and (
                fr.reported_by=(select auth.uid())
                or (select cmms_private.cmms_has_role_at_location(
                  array['technical_expert','technical_supervisor'],a.location_id
                ))
              )
          )
          and (select cmms_private.cmms_has_role_at_location(
            array['reporter','technician','technical_expert','technical_supervisor'],a.location_id
          )))
        or
        (split_part(storage.objects.name,'/',3)='work-orders'
          and exists (
            select 1 from public.cmms_work_orders wo
            where wo.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and wo.asset_id=a.id
              and wo.status not in ('closed','cancelled')
              and (
                exists (
                  select 1 from public.cmms_work_order_assignments wa
                  where wa.work_order_id=wo.id and wa.user_id=(select auth.uid())
                    and wa.unassigned_at is null
                )
                or (select cmms_private.cmms_has_role_at_location(
                  array['technical_expert','technical_supervisor'],a.location_id
                ))
              )
          ))
        or
        (split_part(storage.objects.name,'/',3)='pm'
          and exists (
            select 1 from public.cmms_pm_tasks pt
            where pt.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and pt.asset_id=a.id
              and pt.status not in ('completed','cancelled')
              and (
                pt.assigned_to=(select auth.uid())
                or (select cmms_private.cmms_has_role_at_location(
                  array['technical_expert','technical_supervisor'],a.location_id
                ))
              )
          ))
      )
  )
);

-- No UPDATE/DELETE policies. Do not use Storage upsert for this bucket.
-- New versions must use a new object path and be linked through a reviewed,
-- auditable metadata workflow. Signed download URLs still require SELECT access.
