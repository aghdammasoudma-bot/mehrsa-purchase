-- DRAFT ONLY — read-only CMMS reporting views.
-- Views must remain SECURITY INVOKER so underlying table RLS applies.
-- No materialized copies; all metrics derive from auditable source rows.

create or replace view public.cmms_v1_dashboard_summary
with (security_invoker = true)
as
select
  (select count(*) from public.cmms_failure_reports
   where status in ('submitted','under_review'))::bigint as open_failures,
  (select count(*) from public.cmms_work_orders
   where status not in ('closed','cancelled'))::bigint as open_work_orders,
  (select count(*) from public.cmms_work_orders
   where status in ('pending_supervisor_approval','pending_manager_approval'))::bigint as pending_approvals,
  (select count(*)
   from public.cmms_pm_tasks t
   join public.cmms_pm_plans p on p.id=t.pm_plan_id
   left join lateral (
     select mr.meter_value
     from public.cmms_asset_meter_readings mr
     where mr.asset_id=t.asset_id
       and mr.meter_code=p.meter_code
       and mr.meter_unit=p.meter_unit
     order by mr.reading_at desc,mr.created_at desc
     limit 1
   ) latest_meter on true
   where t.status in ('due','assigned','in_progress','overdue')
     and (
       (t.trigger_type='calendar' and t.due_at is not null and t.due_at <= now())
       or
       (t.trigger_type='meter' and t.due_meter_value is not null
        and latest_meter.meter_value >= t.due_meter_value)
     ))::bigint as overdue_pm_tasks,
  (select count(*) from public.cmms_assets
   where operational_status in ('stopped','under_maintenance'))::bigint as unavailable_assets,
  now() as generated_at;

create or replace view public.cmms_v1_asset_kpis
with (security_invoker = true)
as
with wo as (
  select
    asset_id,
    count(*) filter (where status not in ('cancelled'))::bigint as work_orders_total,
    count(*) filter (where status='closed')::bigint as work_orders_closed,
    count(*) filter (where status not in ('closed','cancelled'))::bigint as work_orders_open,
    sum(extract(epoch from (returned_to_service_at-downtime_started_at))/60)
      filter (where downtime_started_at is not null and returned_to_service_at is not null) as downtime_minutes_total,
    avg(extract(epoch from (returned_to_service_at-downtime_started_at))/60)
      filter (where downtime_started_at is not null and returned_to_service_at is not null) as downtime_minutes_average
  from public.cmms_work_orders
  group by asset_id
),
fr as (
  select asset_id,count(*)::bigint as failure_reports_total
  from public.cmms_failure_reports group by asset_id
),
pm as (
  select asset_id,
    count(*)::bigint as pm_tasks_total,
    count(*) filter (where status='completed')::bigint as pm_tasks_completed,
    count(*) filter (where status in ('due','assigned','in_progress','overdue'))::bigint as pm_tasks_open
  from public.cmms_pm_tasks group by asset_id
)
select
  a.id as asset_id,
  a.asset_code,
  a.name as asset_name,
  a.location_id,
  a.operational_status,
  coalesce(wo.work_orders_total,0) as work_orders_total,
  coalesce(wo.work_orders_closed,0) as work_orders_closed,
  coalesce(wo.work_orders_open,0) as work_orders_open,
  coalesce(fr.failure_reports_total,0) as failure_reports_total,
  coalesce(pm.pm_tasks_total,0) as pm_tasks_total,
  coalesce(pm.pm_tasks_completed,0) as pm_tasks_completed,
  coalesce(pm.pm_tasks_open,0) as pm_tasks_open,
  wo.downtime_minutes_total,
  wo.downtime_minutes_average
from public.cmms_assets a
left join wo on wo.asset_id=a.id
left join fr on fr.asset_id=a.id
left join pm on pm.asset_id=a.id;

create or replace view public.cmms_v1_asset_timeline
with (security_invoker = true)
as
select
  a.id as asset_id,
  fr.occurred_at as event_at,
  'failure'::text as event_type,
  fr.id as event_id,
  'Failure report #'||fr.report_no::text||': '||fr.description as summary,
  jsonb_build_object('status',fr.status,'priority',fr.priority,'reported_by',fr.reported_by) as details
from public.cmms_failure_reports fr
join public.cmms_assets a on a.id=fr.asset_id
union all
select
  a.id,w.created_at,'work_order',w.id,
  'Work order #'||w.wo_no::text||': '||w.title,
  jsonb_build_object('status',w.status,'priority',w.priority,'closed_at',w.closed_at)
from public.cmms_work_orders w
join public.cmms_assets a on a.id=w.asset_id
union all
select
  h.asset_id,h.changed_at,'asset_status',h.id,
  'Asset status: '||coalesce(h.old_status,'—')||' → '||h.new_status,
  jsonb_build_object('reason',h.reason,'changed_by',h.changed_by)
from public.cmms_asset_status_history h
union all
select
  t.asset_id,t.created_at,'pm_task',t.id,
  'Preventive maintenance task',
  jsonb_build_object('status',t.status,'due_at',t.due_at,'due_meter_value',t.due_meter_value)
from public.cmms_pm_tasks t
union all
select
  w.asset_id,act.created_at,'work_order_action',act.id,
  act.action_type||': '||act.description,
  jsonb_build_object('work_order_id',w.id,'wo_no',w.wo_no,'actor_id',act.actor_id,'duration_minutes',act.duration_minutes)
from public.cmms_work_order_actions act
join public.cmms_work_orders w on w.id=act.work_order_id
union all
select
  w.asset_id,ap.decided_at,'approval',ap.id,
  ap.stage||' '||ap.decision,
  jsonb_build_object('work_order_id',w.id,'wo_no',w.wo_no,'approver_id',ap.approver_id,'note',ap.note)
from public.cmms_work_order_approvals ap
join public.cmms_work_orders w on w.id=ap.work_order_id
union all
select
  mr.asset_id,mr.reading_at,'meter_reading',mr.id,
  mr.meter_code||': '||mr.meter_value::text||' '||mr.meter_unit,
  jsonb_build_object('recorded_by',mr.recorded_by,'source',mr.source)
from public.cmms_asset_meter_readings mr;

create or replace view public.cmms_v1_pm_compliance
with (security_invoker = true)
as
select
  p.id as pm_plan_id,
  p.asset_id,
  p.title,
  p.frequency_basis,
  p.is_active,
  count(t.id)::bigint as tasks_total,
  count(t.id) filter (where t.status='completed')::bigint as tasks_completed,
  count(t.id) filter (where t.status in ('due','assigned','in_progress','overdue'))::bigint as tasks_open,
  case when count(t.id)=0 then null
       else round(100.0*count(t.id) filter (where t.status='completed')/count(t.id),1)
  end as completion_percent
from public.cmms_pm_plans p
left join public.cmms_pm_tasks t on t.pm_plan_id=p.id
group by p.id,p.asset_id,p.title,p.frequency_basis,p.is_active;

grant select on public.cmms_v1_dashboard_summary,
  public.cmms_v1_asset_kpis,
  public.cmms_v1_asset_timeline,
  public.cmms_v1_pm_compliance
to authenticated;

-- Do not grant anon. Confirm each view reports security_invoker=true and that
-- RLS on all underlying tables remains enabled before Data API exposure.
