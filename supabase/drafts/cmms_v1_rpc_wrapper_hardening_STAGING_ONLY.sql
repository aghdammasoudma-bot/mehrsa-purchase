-- CMMS V1 RPC wrapper hardening — STAGING ONLY
-- Generated from read-only inspection on 2026-11-18.
-- DO NOT APPLY TO PRODUCTION.
-- Preconditions:
--   1) Run only on an isolated Supabase development branch with verified reset/restore.
--   2) Review each private routine authorization and search_path.
--   3) Run the role-negative acceptance tests before any production release.
-- Strategy: keep cmms_private routines owner-only; elevate only the narrow public
-- wrappers to SECURITY DEFINER; pin search_path to empty; grant exact signatures.
-- Scheduler routine cmms_generate_due_pm_tasks is intentionally excluded.

begin;

-- Public wrappers: explicit signatures are required to avoid accidental overload grants.
alter function public.cmms_assign_pm_task(uuid, uuid) security definer;
alter function public.cmms_assign_work_order(uuid, uuid) security definer;
alter function public.cmms_cancel_work_order(uuid, text) security definer;
alter function public.cmms_change_asset_status(uuid, text, text) security definer;
alter function public.cmms_complete_pm_task(uuid, jsonb) security definer;
alter function public.cmms_create_asset(text, text, uuid, text, uuid, text, text, text, jsonb, text) security definer;
alter function public.cmms_create_location(text, text, text, uuid) security definer;
alter function public.cmms_create_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) security definer;
alter function public.cmms_create_work_order(uuid, text, text, text, text, text, timestamptz, timestamptz, integer, boolean, text, boolean) security definer;
alter function public.cmms_decide_work_order(uuid, text, text, text) security definer;
alter function public.cmms_link_purchase_request(uuid, text) security definer;
alter function public.cmms_reassign_work_order(uuid, uuid, text) security definer;
alter function public.cmms_record_meter_reading(uuid, text, text, numeric) security definer;
alter function public.cmms_record_work_order_action(uuid, text, text, integer, numeric, text, numeric, text[]) security definer;
alter function public.cmms_release_work_order(uuid) security definer;
alter function public.cmms_report_failure(uuid, text, text, text, text, text, text, text[]) security definer;
alter function public.cmms_set_pm_plan_active(uuid, boolean) security definer;
alter function public.cmms_set_work_order_progress(uuid, text) security definer;
alter function public.cmms_start_pm_task(uuid) security definer;
alter function public.cmms_submit_work_order_test(uuid, text, text, timestamptz, text, text[]) security definer;
alter function public.cmms_triage_failure(uuid, text, text) security definer;
alter function public.cmms_update_asset(uuid, text, text, uuid, text, uuid, text, text, text, jsonb, text, text[]) security definer;
alter function public.cmms_update_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) security definer;

-- Fix a pinned empty search_path on every SECURITY DEFINER wrapper.
alter function public.cmms_assign_pm_task(uuid, uuid) set search_path = '';
alter function public.cmms_assign_work_order(uuid, uuid) set search_path = '';
alter function public.cmms_cancel_work_order(uuid, text) set search_path = '';
alter function public.cmms_change_asset_status(uuid, text, text) set search_path = '';
alter function public.cmms_complete_pm_task(uuid, jsonb) set search_path = '';
alter function public.cmms_create_asset(text, text, uuid, text, uuid, text, text, text, jsonb, text) set search_path = '';
alter function public.cmms_create_location(text, text, text, uuid) set search_path = '';
alter function public.cmms_create_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) set search_path = '';
alter function public.cmms_create_work_order(uuid, text, text, text, text, text, timestamptz, timestamptz, integer, boolean, text, boolean) set search_path = '';
alter function public.cmms_decide_work_order(uuid, text, text, text) set search_path = '';
alter function public.cmms_link_purchase_request(uuid, text) set search_path = '';
alter function public.cmms_reassign_work_order(uuid, uuid, text) set search_path = '';
alter function public.cmms_record_meter_reading(uuid, text, text, numeric) set search_path = '';
alter function public.cmms_record_work_order_action(uuid, text, text, integer, numeric, text, numeric, text[]) set search_path = '';
alter function public.cmms_release_work_order(uuid) set search_path = '';
alter function public.cmms_report_failure(uuid, text, text, text, text, text, text, text[]) set search_path = '';
alter function public.cmms_set_pm_plan_active(uuid, boolean) set search_path = '';
alter function public.cmms_set_work_order_progress(uuid, text) set search_path = '';
alter function public.cmms_start_pm_task(uuid) set search_path = '';
alter function public.cmms_submit_work_order_test(uuid, text, text, timestamptz, text, text[]) set search_path = '';
alter function public.cmms_triage_failure(uuid, text, text) set search_path = '';
alter function public.cmms_update_asset(uuid, text, text, uuid, text, uuid, text, text, text, jsonb, text, text[]) set search_path = '';
alter function public.cmms_update_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) set search_path = '';

-- Remove implicit/public and anonymous access; grant only the exact reviewed wrappers.
revoke all on function public.cmms_assign_pm_task(uuid, uuid) from public, anon;
revoke all on function public.cmms_assign_work_order(uuid, uuid) from public, anon;
revoke all on function public.cmms_cancel_work_order(uuid, text) from public, anon;
revoke all on function public.cmms_change_asset_status(uuid, text, text) from public, anon;
revoke all on function public.cmms_complete_pm_task(uuid, jsonb) from public, anon;
revoke all on function public.cmms_create_asset(text, text, uuid, text, uuid, text, text, text, jsonb, text) from public, anon;
revoke all on function public.cmms_create_location(text, text, text, uuid) from public, anon;
revoke all on function public.cmms_create_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) from public, anon;
revoke all on function public.cmms_create_work_order(uuid, text, text, text, text, text, timestamptz, timestamptz, integer, boolean, text, boolean) from public, anon;
revoke all on function public.cmms_decide_work_order(uuid, text, text, text) from public, anon;
revoke all on function public.cmms_link_purchase_request(uuid, text) from public, anon;
revoke all on function public.cmms_reassign_work_order(uuid, uuid, text) from public, anon;
revoke all on function public.cmms_record_meter_reading(uuid, text, text, numeric) from public, anon;
revoke all on function public.cmms_record_work_order_action(uuid, text, text, integer, numeric, text, numeric, text[]) from public, anon;
revoke all on function public.cmms_release_work_order(uuid) from public, anon;
revoke all on function public.cmms_report_failure(uuid, text, text, text, text, text, text, text[]) from public, anon;
revoke all on function public.cmms_set_pm_plan_active(uuid, boolean) from public, anon;
revoke all on function public.cmms_set_work_order_progress(uuid, text) from public, anon;
revoke all on function public.cmms_start_pm_task(uuid) from public, anon;
revoke all on function public.cmms_submit_work_order_test(uuid, text, text, timestamptz, text, text[]) from public, anon;
revoke all on function public.cmms_triage_failure(uuid, text, text) from public, anon;
revoke all on function public.cmms_update_asset(uuid, text, text, uuid, text, uuid, text, text, text, jsonb, text, text[]) from public, anon;
revoke all on function public.cmms_update_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) from public, anon;

grant execute on function public.cmms_assign_pm_task(uuid, uuid) to authenticated;
grant execute on function public.cmms_assign_work_order(uuid, uuid) to authenticated;
grant execute on function public.cmms_cancel_work_order(uuid, text) to authenticated;
grant execute on function public.cmms_change_asset_status(uuid, text, text) to authenticated;
grant execute on function public.cmms_complete_pm_task(uuid, jsonb) to authenticated;
grant execute on function public.cmms_create_asset(text, text, uuid, text, uuid, text, text, text, jsonb, text) to authenticated;
grant execute on function public.cmms_create_location(text, text, text, uuid) to authenticated;
grant execute on function public.cmms_create_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) to authenticated;
grant execute on function public.cmms_create_work_order(uuid, text, text, text, text, text, timestamptz, timestamptz, integer, boolean, text, boolean) to authenticated;
grant execute on function public.cmms_decide_work_order(uuid, text, text, text) to authenticated;
grant execute on function public.cmms_link_purchase_request(uuid, text) to authenticated;
grant execute on function public.cmms_reassign_work_order(uuid, uuid, text) to authenticated;
grant execute on function public.cmms_record_meter_reading(uuid, text, text, numeric) to authenticated;
grant execute on function public.cmms_record_work_order_action(uuid, text, text, integer, numeric, text, numeric, text[]) to authenticated;
grant execute on function public.cmms_release_work_order(uuid) to authenticated;
grant execute on function public.cmms_report_failure(uuid, text, text, text, text, text, text, text[]) to authenticated;
grant execute on function public.cmms_set_pm_plan_active(uuid, boolean) to authenticated;
grant execute on function public.cmms_set_work_order_progress(uuid, text) to authenticated;
grant execute on function public.cmms_start_pm_task(uuid) to authenticated;
grant execute on function public.cmms_submit_work_order_test(uuid, text, text, timestamptz, text, text[]) to authenticated;
grant execute on function public.cmms_triage_failure(uuid, text, text) to authenticated;
grant execute on function public.cmms_update_asset(uuid, text, text, uuid, text, uuid, text, text, text, jsonb, text, text[]) to authenticated;
grant execute on function public.cmms_update_pm_plan(uuid, text, text, text, numeric, text, text, timestamptz, numeric, jsonb) to authenticated;

commit;

-- Post-migration verification (run separately in staging):
-- 1) Verify each public wrapper prosecdef=true and proconfig contains search_path="".
-- 2) Verify anon has no EXECUTE and authenticated has EXECUTE on listed wrappers.
-- 3) Verify every cmms_private write routine remains executable only by postgres.
-- 4) Execute acceptance matrix for anon + all four roles, including negative cross-role tests.
-- 5) Confirm no direct table DML grants exist for authenticated/anon.
