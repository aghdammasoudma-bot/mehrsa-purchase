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
  v_status text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_stage not in ('technical_supervisor','responsible_manager') then raise exception 'Invalid approval stage'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Invalid approval decision'; end if;

  insert into public.cmms_work_order_approvals(
    work_order_id,stage,approver_id,decision,note
  )
  values(p_work_order_id,p_stage,auth.uid(),p_decision,p_note);

  select w.status into v_status
  from public.cmms_work_orders w where w.id=p_work_order_id;

  return v_status;
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

  if v_task.assigned_to is distinct from auth.uid()
     and not cmms_private.cmms_has_role_at_location(
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

-- Public API wrappers are SECURITY INVOKER, not SECURITY DEFINER.
create or replace function public.cmms_report_failure(
  p_asset_id uuid,p_priority text,p_description text,p_symptoms text default null,
  p_production_impact text default null,p_safety_impact text default null,
  p_environmental_impact text default null,p_attachment_paths text[] default '{}'::text[]
) returns uuid language sql security invoker set search_path=''
as $$ select cmms_private.cmms_report_failure($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.cmms_triage_failure(p_failure_report_id uuid,p_decision text,p_note text default null)
returns uuid language sql security invoker set search_path=''
as $$ select cmms_private.cmms_triage_failure($1,$2,$3); $$;

create or replace function public.cmms_release_work_order(p_work_order_id uuid)
returns text language sql security invoker set search_path=''
as $$ select cmms_private.cmms_release_work_order($1); $$;

create or replace function public.cmms_assign_work_order(p_work_order_id uuid,p_assignee_id uuid)
returns uuid language sql security invoker set search_path=''
as $$ select cmms_private.cmms_assign_work_order($1,$2); $$;

create or replace function public.cmms_record_work_order_action(
  p_work_order_id uuid,p_action_type text,p_description text,p_duration_minutes integer default null,
  p_quantity numeric default null,p_unit text default null,p_meter_reading numeric default null,
  p_attachment_paths text[] default '{}'::text[]
) returns uuid language sql security invoker set search_path=''
as $$ select cmms_private.cmms_record_work_order_action($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.cmms_set_work_order_progress(p_work_order_id uuid,p_next_status text)
returns text language sql security invoker set search_path=''
as $$ select cmms_private.cmms_set_work_order_progress($1,$2); $$;

create or replace function public.cmms_submit_work_order_test(
  p_work_order_id uuid,p_test_result text,p_return_to_service_status text,
  p_returned_to_service_at timestamptz,p_test_description text,p_attachment_paths text[] default '{}'::text[]
) returns text language sql security invoker set search_path=''
as $$ select cmms_private.cmms_submit_work_order_test($1,$2,$3,$4,$5,$6); $$;

create or replace function public.cmms_decide_work_order(
  p_work_order_id uuid,p_stage text,p_decision text,p_note text default null
) returns text language sql security invoker set search_path=''
as $$ select cmms_private.cmms_decide_work_order($1,$2,$3,$4); $$;

create or replace function public.cmms_complete_pm_task(p_pm_task_id uuid,p_checklist_result jsonb)
returns uuid language sql security invoker set search_path=''
as $$ select cmms_private.cmms_complete_pm_task($1,$2); $$;

-- Internal functions are not directly exposed as RPC endpoints.
revoke all on all functions in schema cmms_private from public, anon, authenticated;
grant usage on schema cmms_private to authenticated;
grant execute on function cmms_private.cmms_report_failure(uuid,text,text,text,text,text,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function cmms_private.cmms_release_work_order(uuid) to authenticated;
grant execute on function cmms_private.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function cmms_private.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function cmms_private.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function cmms_private.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function cmms_private.cmms_complete_pm_task(uuid,jsonb) to authenticated;
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
revoke all on function public.cmms_complete_pm_task(uuid,jsonb) from public, anon;

grant execute on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[]) to authenticated;
grant execute on function public.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function public.cmms_release_work_order(uuid) to authenticated;
grant execute on function public.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function public.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function public.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function public.cmms_complete_pm_task(uuid,jsonb) to authenticated;

commit;

-- Remaining v1 server-side work before release:
-- * scheduled calendar/meter/hybrid PM generation and missed-run recovery;
-- * cancellation and controlled reassignment/unassignment RPCs;
-- * report export, notification delivery, and purchase-link RPC;
-- * integration tests in isolated PostgreSQL/Supabase staging;
-- * verify every status transition against the hardening trigger and audit log.
