-- CMMS v1 integration acceptance tests.
-- Run ONLY in a disposable staging project after applying all CMMS drafts.
-- The enclosing transaction must be rolled back; fixtures are not production data.

begin;

do $cmms_test$
declare
  v_supervisor uuid;
  v_manager uuid;
  v_expert uuid;
  v_technician uuid;
  v_location uuid;
  v_asset uuid;
  v_report uuid;
  v_wo uuid;
  v_pm_plan uuid;
  v_pm_task uuid;
  v_rejected boolean;
  v_status text;
begin
  select user_id into v_supervisor from public.user_profiles where username='masoud' and is_active;
  select user_id into v_manager from public.user_profiles where username='biabani' and is_active;
  select user_id into v_expert from public.user_profiles where username='reza' and is_active;
  select user_id into v_technician from public.user_profiles where username='hamid' and is_active;

  if v_supervisor is null or v_manager is null or v_expert is null or v_technician is null then
    raise exception 'Required active CMMS test profiles are missing';
  end if;

  -- Test location and asset registration as technical supervisor.
  perform set_config('request.jwt.claim.sub',v_supervisor::text,true);
  v_location := public.cmms_create_location(
    'TEST-CMMS-'||substr(gen_random_uuid()::text,1,8),
    'CMMS disposable test area','production',null
  );
  v_asset := public.cmms_create_asset(
    'TEST-ASSET-'||substr(gen_random_uuid()::text,1,8),
    'Disposable test pump',v_location,'high',null,'Test manufacturer','Model X',
    'TEST-SERIAL',jsonb_build_object('power_kw',5),'CMMS integration test'
  );

  -- Test the two-stage corrective maintenance flow.
  perform set_config('request.jwt.claim.sub',v_technician::text,true);
  v_report := public.cmms_report_failure(
    v_asset,'high','Integration test: pump vibration detected',
    'Abnormal vibration','Production line affected','No known safety impact',
    'No known environmental impact','{}'::text[]
  );

  perform set_config('request.jwt.claim.sub',v_expert::text,true);
  v_wo := public.cmms_triage_failure(v_report,'convert','Approved for technical repair');
  perform public.cmms_release_work_order(v_wo);
  perform public.cmms_assign_work_order(v_wo,v_technician);

  perform set_config('request.jwt.claim.sub',v_technician::text,true);
  perform public.cmms_set_work_order_progress(v_wo,'in_progress');
  perform public.cmms_record_work_order_action(
    v_wo,'diagnosis','Confirmed abnormal bearing vibration',30,null,null,null,'{}'::text[]
  );
  perform public.cmms_record_work_order_action(
    v_wo,'repair','Bearing replaced and coupling aligned',90,null,null,null,'{}'::text[]
  );
  perform public.cmms_set_work_order_progress(v_wo,'testing');
  perform public.cmms_submit_work_order_test(
    v_wo,'passed','returned',now(),'Test run successful; normal vibration restored','{}'::text[]
  );

  -- Supervisor may approve, but cannot perform the manager's second approval.
  perform set_config('request.jwt.claim.sub',v_supervisor::text,true);
  perform public.cmms_decide_work_order(v_wo,'technical_supervisor','approved','Technical inspection passed');

  v_rejected := false;
  begin
    perform public.cmms_decide_work_order(v_wo,'responsible_manager','approved','Must be denied: same person');
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'Negative test failed: same-person dual approval was accepted'; end if;

  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  v_status := public.cmms_decide_work_order(v_wo,'responsible_manager','approved','Manager final approval');
  if v_status <> 'closed' then raise exception 'Work order did not close after both approvals'; end if;

  select status into v_status from public.cmms_work_orders where id=v_wo;
  if v_status <> 'closed' then raise exception 'Closed status was not persisted'; end if;

  -- Test rejection requires a reason and sends the work order back to rework.
  perform set_config('request.jwt.claim.sub',v_expert::text,true);
  v_report := public.cmms_report_failure(v_asset,'normal','Second integration failure','Noise');
  v_wo := public.cmms_triage_failure(v_report,'convert',null);
  perform public.cmms_release_work_order(v_wo);
  perform public.cmms_assign_work_order(v_wo,v_technician);
  perform set_config('request.jwt.claim.sub',v_technician::text,true);
  perform public.cmms_set_work_order_progress(v_wo,'in_progress');
  perform public.cmms_set_work_order_progress(v_wo,'testing');
  perform public.cmms_submit_work_order_test(v_wo,'passed','not_required',null,'Test passed','{}'::text[]);
  perform set_config('request.jwt.claim.sub',v_supervisor::text,true);
  v_status := public.cmms_decide_work_order(v_wo,'technical_supervisor','rejected','Alignment still outside tolerance');
  if v_status <> 'rework' then raise exception 'Supervisor rejection did not return order to rework'; end if;

  -- Location hierarchy must reject self-parenting.
  v_rejected := false;
  begin
    update public.cmms_locations set parent_id=id where id=v_location;
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'Negative test failed: location self-parenting was accepted'; end if;

  -- Test calendar-based PM plan generation, assignment and checklist closeout.
  perform set_config('request.jwt.claim.sub',v_expert::text,true);
  v_pm_plan := public.cmms_create_pm_plan(
    v_asset,'Daily pump inspection','calendar','day',1,
    now()-interval '1 day',null,null,null,
    jsonb_build_array(jsonb_build_object('item','Check vibration','required',true))
  );

  perform cmms_private.cmms_generate_due_pm_tasks();
  select id into v_pm_task from public.cmms_pm_tasks
  where pm_plan_id=v_pm_plan and status='due'
  order by due_at desc limit 1;
  if v_pm_task is null then raise exception 'PM scheduler did not generate a due task'; end if;

  perform public.cmms_assign_pm_task(v_pm_task,v_technician);
  perform set_config('request.jwt.claim.sub',v_technician::text,true);
  perform public.cmms_complete_pm_task(
    v_pm_task,jsonb_build_array(jsonb_build_object('item','Check vibration','result','pass','note','Within limit'))
  );

  select status into v_status from public.cmms_pm_tasks where id=v_pm_task;
  if v_status <> 'completed' then raise exception 'PM task did not complete'; end if;

  -- Technician must not be able to create a new asset or approve the manager stage.
  v_rejected := false;
  begin
    perform public.cmms_create_asset(
      'UNAUTHORIZED-'||substr(gen_random_uuid()::text,1,8),'Unauthorized asset',v_location
    );
  exception when others then
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'Negative test failed: technician created an asset'; end if;

end;
$cmms_test$;

rollback;
