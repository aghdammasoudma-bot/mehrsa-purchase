-- DRAFT ONLY — DO NOT APPLY TO PRODUCTION.
-- CMMS v1 additive schema. RLS is enabled and no policies are granted yet.
-- Apply only after external backup + restore test and role mapping approval.

create table if not exists public.cmms_locations (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.cmms_locations(id) on delete restrict,
  code text not null unique,
  name text not null,
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
  criticality text not null default 'medium' check (criticality in ('low','medium','high','critical')),
  operational_status text not null default 'operational' check (operational_status in ('operational','degraded','stopped','under_maintenance','retired')),
  commissioned_at date,
  warranty_until date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
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
  priority text not null default 'normal' check (priority in ('low','normal','high','critical')),
  status text not null default 'approved_for_execution' check (status in ('approved_for_execution','assigned','in_progress','waiting_parts','testing','pending_supervisor_approval','pending_manager_approval','rework','closed','cancelled')),
  opened_by uuid not null references auth.users(id) on delete restrict,
  downtime_started_at timestamptz,
  returned_to_service_at timestamptz,
  test_result text,
  supervisor_approved_by uuid references auth.users(id) on delete set null,
  supervisor_approved_at timestamptz,
  manager_approved_by uuid references auth.users(id) on delete set null,
  manager_approved_at timestamptz,
  closed_at timestamptz,
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
  unassigned_at timestamptz
);

create table if not exists public.cmms_work_order_actions (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references public.cmms_work_orders(id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action_type text not null check (action_type in ('diagnosis','repair','part_used','time_log','test','note','status_change')),
  description text not null,
  quantity numeric(12,3),
  unit text,
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
  frequency_unit text not null check (frequency_unit in ('day','week','month','year')),
  frequency_value integer not null check (frequency_value > 0),
  checklist jsonb not null default '[]'::jsonb,
  next_due_at timestamptz not null,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.cmms_pm_tasks (
  id uuid primary key default gen_random_uuid(),
  pm_plan_id uuid not null references public.cmms_pm_plans(id) on delete restrict,
  asset_id uuid not null references public.cmms_assets(id) on delete restrict,
  due_at timestamptz not null,
  status text not null default 'due' check (status in ('due','assigned','in_progress','completed','overdue','cancelled')),
  assigned_to uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  checklist_result jsonb,
  created_at timestamptz not null default now(),
  unique(pm_plan_id, due_at)
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
create index if not exists cmms_failure_reports_asset_status_idx on public.cmms_failure_reports(asset_id,status);
create index if not exists cmms_work_orders_asset_status_idx on public.cmms_work_orders(asset_id,status);
create index if not exists cmms_work_orders_priority_idx on public.cmms_work_orders(priority,status);
create index if not exists cmms_assignments_user_idx on public.cmms_work_order_assignments(user_id,work_order_id);
create index if not exists cmms_pm_tasks_due_idx on public.cmms_pm_tasks(status,due_at);
create index if not exists cmms_audit_entity_idx on public.cmms_audit_logs(entity_type,entity_id,created_at desc);

alter table public.cmms_locations enable row level security;
alter table public.cmms_asset_categories enable row level security;
alter table public.cmms_assets enable row level security;
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
