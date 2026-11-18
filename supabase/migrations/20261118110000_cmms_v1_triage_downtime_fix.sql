-- Preserve failure downtime start when triage converts a report to a corrective work order.
-- Additive function replacement; no existing records are rewritten.
create or replace function cmms_private.cmms_triage_failure(
  p_failure_report_id uuid,
  p_decision text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
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
    asset_id,failure_report_id,title,description,work_type,priority,status,opened_by,downtime_started_at
  ) values (
    v_report.asset_id,v_report.id,left(v_report.description,120),v_report.description,
    'corrective',v_report.priority,'triage',auth.uid(),v_report.downtime_started_at
  ) returning id into v_work_order_id;

  update public.cmms_failure_reports
  set status='converted',reviewed_by=auth.uid(),reviewed_at=now(),review_note=coalesce(p_note,'')
  where id=p_failure_report_id;
  return v_work_order_id;
end;
$function$;
