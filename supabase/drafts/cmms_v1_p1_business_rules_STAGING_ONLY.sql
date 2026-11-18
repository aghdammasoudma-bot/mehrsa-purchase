-- CMMS V1 P1 business-rule hardening — STAGING ONLY
-- Drafted from read-only Production function definitions on 2026-11-18.
-- DO NOT APPLY TO PRODUCTION. Applied successfully to isolated Staging on 2026-11-18; partial workflow/retirement tests passed. Remaining edge-case and concurrency tests are still required.
-- Preconditions: isolated staging schema/data, backup/restore path, and review of the audit report.
-- Locking: asset rows are locked FOR SHARE in write operations; retirement uses FOR UPDATE.
-- This serializes retirement against new meter readings, PM plan changes and failure conversion.

begin;

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

commit;

-- Required staging verification:
-- * Compile all replaced functions against staging schema before runtime tests.
-- * Assert retired asset cannot receive manual meter readings, PM plan create/update,
--   scheduler-generated PM tasks, or failure->WO conversion.
-- * Assert retirement is denied with any nonterminal work order or active PM plan.
-- * Assert negative, NaN, and +/-Infinity quantity/meter_reading are rejected.
-- * Assert zero values remain accepted; positive values remain accepted.
-- * Run concurrent test: retirement vs meter reading / PM update / scheduler.
