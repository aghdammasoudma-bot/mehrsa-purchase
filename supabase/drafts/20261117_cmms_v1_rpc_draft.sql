-- DRAFT ONLY — never apply to production before external backup + staging tests.
-- CMMS v1 controlled write RPCs. Depends on base, hardening and authorization drafts.
-- Client roles receive SELECT only on tables; all writes pass through these functions.
-- Every function validates auth.uid(), role, asset location and lifecycle state.

create or replace function public.cmms_submit_failure_report(
  p_asset_id uuid,
  p_priority text,
  p_description text,
  p_symptoms text default null,
  p_production_impact text default null,
  p_safety_impact text default null,
  p_environmental_impact text default null,
  p_attachment_paths text[] default '{}'::text[]
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
  if nullif(btrim(coalesce(p_description,'')),'') is null then
    raise exception 'Failure description is required';
  end if;
  if p_priority not in ('low','normal','high','critical') then
    raise exception 'Invalid failure priority';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a
  where a.id=p_asset_id and a.operational_status <> 'retired'
  for share;
  if not found then raise exception 'Asset not found or retired'; end if;

  if not cmms_private.cmms_has_role_at_location(
    array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
    v_location_id
  ) then raise exception 'No CMMS access to this asset location'; end if;

  insert into public.cmms_failure_reports(
    asset_id,reported_by,priority,description,symptoms,
    production_impact,safety_impact,environmental_impact,attachment_paths
  ) values (
    p_asset_id,auth.uid(),p_priority,btrim(p_description),nullif(btrim(coalesce(p_symptoms,'')),''),
    nullif(btrim(coalesce(p_production_impact,'')),''),
    nullif(btrim(coalesce(p_safety_impact,'')),''),
    nullif(btrim(coalesce(p_environmental_impact,'')),''),
    coalesce(p_attachment_paths,'{}'::text[])
  ) returning id into v_report_id;

  return v_report_id;
end;
$$;

create or replace function public.cmms_triage_failure_report(
  p_failure_report_id uuid,
  p_decision text,
  p_note text,
  p_work_order_title text default null,
  p_work_order_description text default null,
  p_priority text default null,
  p_assignee_ids uuid[] default '{}'::uuid[],
  p_due_at timestamptz default null
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
  v_assignee uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_decision not in ('convert','reject') then raise exception 'Decision must be convert or reject'; end if;
  if p_decision='reject' and nullif(btrim(coalesce(p_note,'')),'') is null then
    raise exception 'Rejection reason is mandatory';
  end if;

  select f.* into v_report
  from public.cmms_failure_reports f
  where f.id=p_failure_report_id
  for update;
  if not found then raise exception 'Failure report not found'; end if;

  select a.location_id into v_location_id
  from public.cmms_assets a where a.id=v_report.asset_id;
  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can triage'; end if;
  if v_report.status not in ('submitted','under_review') then
    raise exception 'Failure report is not open for triage';
  end if;

  if p_decision='reject' then
    update public.cmms_failure_reports
    set status='rejected',reviewed_by=auth.uid(),reviewed_at=now(),review_note=btrim(p_note)
    where id=p_failure_report_id;
    return null;
  end if;

  if nullif(btrim(coalesce(p_work_order_title,'')),'') is null then
    raise exception 'Work-order title is required';
  end if;
  if coalesce(array_length(p_assignee_ids,1),0)=0 then
    raise exception 'At least one technician must be assigned before release';
  end if;
  if p_priority is not null and p_priority not in ('low','normal','high','critical') then
    raise exception 'Invalid work-order priority';
  end if;

  foreach v_assignee in array p_assignee_ids loop
    if not exists (
      select 1 from public.cmms_user_roles ur
      where ur.user_id=v_assignee and ur.is_active
        and ur.role in ('technician','technical_expert')
        and ur.location_id is null
    ) then
      raise exception 'Each assignee must have an active global technician or technical-expert role';
    end if;
  end loop;

  insert into public.cmms_work_orders(
    asset_id,failure_report_id,title,description,work_type,priority,status,opened_by,due_at
  ) values (
    v_report.asset_id,p_failure_report_id,btrim(p_work_order_title),
    nullif(btrim(coalesce(p_work_order_description,'')),''),
    'corrective',coalesce(p_priority,v_report.priority),'triage',auth.uid(),p_due_at
  ) returning id into v_work_order_id;

  foreach v_assignee in array p_assignee_ids loop
    insert into public.cmms_work_order_assignments(work_order_id,user_id,assigned_by)
    values(v_work_order_id,v_assignee,auth.uid());
  end loop;

  update public.cmms_failure_reports
  set status='converted',reviewed_by=auth.uid(),reviewed_at=now(),
      review_note=nullif(btrim(coalesce(p_note,'')),'')
  where id=p_failure_report_id;

  return v_work_order_id;
end;
$$;

create or replace function public.cmms_release_work_order(p_work_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_status text;
  v_active_assignments integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select a.location_id,w.status into v_location_id,v_status
  from public.cmms_work_orders w
  join public.cmms_assets a on a.id=w.asset_id
  where w.id=p_work_order_id
  for update of w;
  if not found then raise exception 'Work order not found'; end if;
  if not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only technical expert or supervisor can release a work order'; end if;
  if v_status <> 'triage' then raise exception 'Work order is not in triage'; end if;

  select count(*) into v_active_assignments
  from public.cmms_work_order_assignments wa
  where wa.work_order_id=p_work_order_id and wa.unassigned_at is null;
  if v_active_assignments=0 then raise exception 'At least one active assignment is required'; end if;

  update public.cmms_work_orders set status='approved_for_execution',updated_at=now()
  where id=p_work_order_id;
  update public.cmms_work_orders set status='assigned',updated_at=now()
  where id=p_work_order_id;
end;
$$;

create or replace function public.cmms_log_work_order_action(
  p_work_order_id uuid,
  p_action_type text,
  p_description text,
  p_quantity numeric default null,
  p_unit text default null,
  p_duration_minutes integer default null,
  p_meter_reading numeric default null,
  p_attachment_paths text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_action_id uuid;
  v_assigned boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_action_type not in ('diagnosis','repair','part_used','time_log','test','note') then
    raise exception 'Invalid work-order action type';
  end if;
  if nullif(btrim(coalesce(p_description,'')),'') is null then
    raise exception 'Action description is required';
  end if;
  if p_duration_minutes is not null and p_duration_minutes < 0 then
    raise exception 'Duration cannot be negative';
  end if;

  select a.location_id into v_location_id
  from public.cmms_work_orders w
  join public.cmms_assets a on a.id=w.asset_id
  where w.id=p_work_order_id;
  if not found then raise exception 'Work order not found'; end if;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=p_work_order_id and wa.user_id=auth.uid() and wa.unassigned_at is null
  ) into v_assigned;

  if not v_assigned and not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only assigned users or technical governance roles may log actions'; end if;

  insert into public.cmms_work_order_actions(
    work_order_id,actor_id,action_type,description,quantity,unit,duration_minutes,meter_reading,attachment_paths
  ) values (
    p_work_order_id,auth.uid(),p_action_type,btrim(p_description),p_quantity,p_unit,
    p_duration_minutes,p_meter_reading,coalesce(p_attachment_paths,'{}'::text[])
  ) returning id into v_action_id;

  return v_action_id;
end;
$$;

create or replace function public.cmms_submit_work_order_for_approval(
  p_work_order_id uuid,
  p_test_result text,
  p_return_to_service_status text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_status text;
  v_assigned boolean;
  v_next_status text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_test_result not in ('passed','failed','partial') then raise exception 'Invalid test result'; end if;
  if p_return_to_service_status not in ('returned','not_returned','not_required') then
    raise exception 'Explicit return-to-service decision is required';
  end if;

  select a.location_id,w.status into v_location_id,v_status
  from public.cmms_work_orders w
  join public.cmms_assets a on a.id=w.asset_id
  where w.id=p_work_order_id
  for update of w;
  if not found then raise exception 'Work order not found'; end if;

  select exists (
    select 1 from public.cmms_work_order_assignments wa
    where wa.work_order_id=p_work_order_id and wa.user_id=auth.uid() and wa.unassigned_at is null
  ) into v_assigned;
  if not v_assigned and not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'Only assigned users or technical governance roles can submit test results'; end if;

  if v_status not in ('testing','rework') then
    raise exception 'Work order must be in testing or rework before submission';
  end if;

  if p_test_result='passed' and p_return_to_service_status in ('returned','not_required') then
    v_next_status := 'pending_supervisor_approval';
  else
    v_next_status := 'in_progress';
  end if;

  update public.cmms_work_orders
  set test_result=p_test_result,
      return_to_service_status=p_return_to_service_status,
      returned_to_service_at=case when p_return_to_service_status='returned' then now() else null end,
      status=v_next_status,
      updated_at=now()
  where id=p_work_order_id;

  return v_next_status;
end;
$$;

create or replace function public.cmms_approve_work_order(
  p_work_order_id uuid,
  p_stage text,
  p_decision text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_approval_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_stage not in ('technical_supervisor','responsible_manager') then raise exception 'Invalid approval stage'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Invalid approval decision'; end if;

  select a.location_id into v_location_id
  from public.cmms_work_orders w
  join public.cmms_assets a on a.id=w.asset_id
  where w.id=p_work_order_id;
  if not found then raise exception 'Work order not found'; end if;

  if p_stage='technical_supervisor' then
    if not cmms_private.cmms_has_role_at_location(array['technical_supervisor'],v_location_id) then
      raise exception 'Technical-supervisor role required';
    end if;
  else
    if not cmms_private.cmms_has_role_at_location(array['responsible_manager'],v_location_id) then
      raise exception 'Responsible-manager role required';
    end if;
  end if;

  insert into public.cmms_work_order_approvals(
    work_order_id,stage,approver_id,decision,note
  ) values (
    p_work_order_id,p_stage,auth.uid(),p_decision,nullif(btrim(coalesce(p_note,'')),'')
  ) returning id into v_approval_id;

  return v_approval_id;
end;
$$;

create or replace function public.cmms_complete_pm_task(
  p_pm_task_id uuid,
  p_checklist_result jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_assigned_to uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_checklist_result is null
     or not (
       (jsonb_typeof(p_checklist_result)='array' and jsonb_array_length(p_checklist_result)>0)
       or (jsonb_typeof(p_checklist_result)='object' and jsonb_object_length(p_checklist_result)>0)
     ) then raise exception 'Non-empty checklist result is required'; end if;

  select a.location_id,t.assigned_to into v_location_id,v_assigned_to
  from public.cmms_pm_tasks t
  join public.cmms_assets a on a.id=t.asset_id
  where t.id=p_pm_task_id
  for update of t;
  if not found then raise exception 'PM task not found'; end if;

  if v_assigned_to is distinct from auth.uid()
     and not cmms_private.cmms_has_role_at_location(
       array['technical_expert','technical_supervisor'],v_location_id
     ) then raise exception 'Only assigned user or technical governance role can complete this PM task'; end if;

  update public.cmms_pm_tasks
  set status='completed',completed_by=auth.uid(),completed_at=now(),
      checklist_result=p_checklist_result
  where id=p_pm_task_id and status in ('due','assigned','in_progress','overdue');

  if not found then raise exception 'PM task is not open'; end if;
end;
$$;

create or replace function public.cmms_record_meter_reading(
  p_asset_id uuid,
  p_meter_code text,
  p_meter_unit text,
  p_meter_value numeric,
  p_source text default 'manual'
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
  select location_id into v_location_id from public.cmms_assets where id=p_asset_id;
  if not found then raise exception 'Asset not found'; end if;
  if not cmms_private.cmms_has_role_at_location(
    array['technician','technical_expert','technical_supervisor'],v_location_id
  ) then raise exception 'No permission to record meter readings for this asset'; end if;

  insert into public.cmms_asset_meter_readings(
    asset_id,meter_code,meter_unit,meter_value,recorded_by,source
  ) values (
    p_asset_id,btrim(p_meter_code),btrim(p_meter_unit),p_meter_value,auth.uid(),p_source
  ) returning id into v_reading_id;
  return v_reading_id;
end;
$$;

-- Explicitly deny execution to PUBLIC/anon; grant only authenticated callers.
revoke all on function public.cmms_submit_failure_report(uuid,text,text,text,text,text,text,text[]) from public,anon;
revoke all on function public.cmms_triage_failure_report(uuid,text,text,text,text,text,uuid[],timestamptz) from public,anon;
revoke all on function public.cmms_release_work_order(uuid) from public,anon;
revoke all on function public.cmms_log_work_order_action(uuid,text,text,numeric,text,integer,numeric,text[]) from public,anon;
revoke all on function public.cmms_submit_work_order_for_approval(uuid,text,text) from public,anon;
revoke all on function public.cmms_approve_work_order(uuid,text,text,text) from public,anon;
revoke all on function public.cmms_complete_pm_task(uuid,jsonb) from public,anon;
revoke all on function public.cmms_record_meter_reading(uuid,text,text,numeric,text) from public,anon;

grant execute on function public.cmms_submit_failure_report(uuid,text,text,text,text,text,text,text[]) to authenticated;
grant execute on function public.cmms_triage_failure_report(uuid,text,text,text,text,text,uuid[],timestamptz) to authenticated;
grant execute on function public.cmms_release_work_order(uuid) to authenticated;
grant execute on function public.cmms_log_work_order_action(uuid,text,text,numeric,text,integer,numeric,text[]) to authenticated;
grant execute on function public.cmms_submit_work_order_for_approval(uuid,text,text) to authenticated;
grant execute on function public.cmms_approve_work_order(uuid,text,text,text) to authenticated;
grant execute on function public.cmms_complete_pm_task(uuid,jsonb) to authenticated;
grant execute on function public.cmms_record_meter_reading(uuid,text,text,numeric,text) to authenticated;

-- PM task generation is intentionally separate and will be service-role only,
-- after pg_cron or a scheduled Supabase Function is selected and tested.
