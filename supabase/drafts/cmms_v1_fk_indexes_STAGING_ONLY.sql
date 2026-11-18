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
