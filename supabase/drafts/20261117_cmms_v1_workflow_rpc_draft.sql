-- DRAFT ONLY — CMMS v1 controlled workflow RPCs.
-- NOT APPLIED. Depends on base schema, hardening triggers and authorization helpers.
-- Private SECURITY DEFINER implementations; public SECURITY INVOKER RPC entry points.
-- No broad client table UPDATE/DELETE grants are required.

begin;

create or replace function cmms_private.cmms_report_failure(
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
    production_impact, safety_impact, environmental_impact, attachment_paths
  )
  values (
    p_asset_id, auth.uid(), p_priority, btrim(p_description), p_symptoms,
    p_production_impact, p_safety_impact, p_environmental_impact,
    coalesce(p_attachment_paths,'{}'::text[])
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
  if p_decision not in ('convert','reject') then raise exception 'Invalid triage decision'; end if;
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
    asset_id, failure_report_id, title, description, work_type, priority, status, opened_by
  )
  values (
    v_report.asset_id, v_report.id, left(v_report.description,120), v_report.description,
    'corrective', v_report.priority, 'triage', auth.uid()
  )
  returning id into v_work_order_id;

  update public.cmms_failure_reports
  set status='converted', reviewed_by=auth.uid(), reviewed_at=now(), review_note=coalesce(p_note,'')
  where id=p_failure_report_id;

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

  if not exists (
    select 1 from public.cmms_user_roles r
    where r.user_id=p_assignee_id
      and r.is_active
      and r.location_id is null
      and r.role in ('technician','technical_expert')
      and exists (select 1 from public.user_profiles up where up.user_id=r.user_id and up.is_active)
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

  if not v_is_assigned and not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned workers or technical supervisors/experts can log actions';
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

  if not v_is_assigned and not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned workers or technical supervisors/experts can change execution status';
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
  if p_test_result not in ('passed','failed','partial') then raise exception 'Invalid test result'; end if;

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

  if not v_is_assigned and not cmms_private.cmms_has_role_at_location(
    array['technical_expert','technical_supervisor'],v_location_id
  ) then
    raise exception 'Only assigned workers or technical supervisors/experts can submit tests';
  end if;

  if p_test_result='passed' then
    if p_return_to_service_status not in ('returned','not_required') then
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

  if v_task.assigned_to is distinct from auth.uid() then
    raise exception 'Only the assigned user can start this PM task';
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
    if not exists (
      select 1 from public.cmms_user_roles ur
      join public.user_profiles up on up.user_id=ur.user_id
      where ur.user_id=auth.uid()
        and ur.is_active
        and ur.location_id is null
        and ur.role in ('technician','technical_expert')
        and up.is_active
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

  if not exists (
    select 1 from public.cmms_user_roles ur
    where ur.user_id=p_assignee_id and ur.is_active
      and ur.location_id is null and ur.role in ('technician','technical_expert')
      and exists (select 1 from public.user_profiles up where up.user_id=ur.user_id and up.is_active)
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

  if not exists (
    select 1 from public.cmms_user_roles ur
    where ur.user_id=p_new_assignee_id and ur.is_active
      and ur.location_id is null and ur.role in ('technician','technical_expert')
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
  p_environmental_impact text default null,p_attachment_paths text[] default '{}'::text[]
) returns uuid as $$ select cmms_private.cmms_report_failure($1,$2,$3,$4,$5,$6,$7,$8); $$ language sql security invoker set search_path = '';

create or replace function public.cmms_triage_failure(p_failure_report_id uuid,p_decision text,p_note text default null)
returns uuid as $$ select cmms_private.cmms_triage_failure($1,$2,$3); $$ language sql security invoker set search_path = '';

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
grant execute on function cmms_private.cmms_report_failure(uuid,text,text,text,text,text,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function cmms_private.cmms_release_work_order(uuid) to authenticated;
grant execute on function cmms_private.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function cmms_private.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function cmms_private.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function cmms_private.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function cmms_private.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
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

revoke all on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[]) from public, anon;
revoke all on function public.cmms_triage_failure(uuid,text,text) from public, anon;
revoke all on function public.cmms_release_work_order(uuid) from public, anon;
revoke all on function public.cmms_assign_work_order(uuid,uuid) from public, anon;
revoke all on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) from public, anon;
revoke all on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) from public, anon;
revoke all on function public.cmms_set_work_order_progress(uuid,text) from public, anon;
revoke all on function public.cmms_decide_work_order(uuid,text,text,text) from public, anon;
revoke all on function public.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) from public, anon;
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

grant execute on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[]) to authenticated;
grant execute on function public.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function public.cmms_release_work_order(uuid) to authenticated;
grant execute on function public.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function public.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function public.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function public.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
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

commit;

-- Remaining v1 server-side work before release:
-- * scheduling cmms_private.cmms_generate_due_pm_tasks() with pg_cron or a service-role scheduler;
-- * report export, notification delivery, and PM-failure-to-corrective-work-order RPC;
-- * integration tests in isolated PostgreSQL/Supabase staging;
-- * verify every status transition against the hardening trigger and audit log.
