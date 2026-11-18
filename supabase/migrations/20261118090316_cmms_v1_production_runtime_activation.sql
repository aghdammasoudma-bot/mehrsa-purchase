-- Production runtime activation: exact CMMS V1 RPC grants and private evidence storage.
-- Requires the CMMS V1 schema, roles and public wrappers from the release-candidate migration.
create or replace function cmms_private.cmms_report_failure(
  p_asset_id uuid,
  p_priority text,
  p_description text,
  p_symptoms text default null,
  p_production_impact text default null,
  p_safety_impact text default null,
  p_environmental_impact text default null,
  p_attachment_paths text[] default '{}'::text[],
  p_downtime_started_at timestamptz default null
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
    production_impact, safety_impact, environmental_impact, attachment_paths, downtime_started_at
  )
  values (
    p_asset_id, auth.uid(), p_priority, btrim(p_description), p_symptoms,
    p_production_impact, p_safety_impact, p_environmental_impact,
    coalesce(p_attachment_paths,'{}'::text[]), p_downtime_started_at
  )
  returning id into v_report_id;

  return v_report_id;
end;
$$;

create or replace function public.cmms_report_failure(
  p_asset_id uuid,p_priority text,p_description text,p_symptoms text default null,
  p_production_impact text default null,p_safety_impact text default null,
  p_environmental_impact text default null,p_attachment_paths text[] default '{}'::text[],
  p_downtime_started_at timestamptz default null
) returns uuid as $$ select cmms_private.cmms_report_failure($1,$2,$3,$4,$5,$6,$7,$8,$9); $$ language sql security invoker set search_path = '';

do $$
begin
  if to_regprocedure('public.cmms_report_failure(uuid,text,text,text,text,text,text,text[])') is not null then
    execute 'revoke all on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[]) from public, anon, authenticated';
  end if;
end
$$;
revoke all on all functions in schema cmms_private from public, anon, authenticated;
grant usage on schema cmms_private to authenticated, service_role;
grant execute on function cmms_private.cmms_report_failure(uuid,text,text,text,text,text,text,text[],timestamptz) to authenticated;
grant execute on function cmms_private.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function cmms_private.cmms_create_work_order(uuid,text,text,text,text,text,timestamptz,timestamptz,integer,boolean,text,boolean) to authenticated;
grant execute on function cmms_private.cmms_release_work_order(uuid) to authenticated;
grant execute on function cmms_private.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function cmms_private.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function cmms_private.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function cmms_private.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function cmms_private.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
grant execute on function cmms_private.cmms_update_asset(uuid,text,text,uuid,text,uuid,text,text,text,jsonb,text,text[]) to authenticated;
grant execute on function cmms_private.cmms_change_asset_status(uuid,text,text) to authenticated;
grant execute on function cmms_private.cmms_update_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
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
-- cmms_user_has_active_role remains owner-only; workflow SECURITY DEFINER routines call it as owner.

revoke all on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[],timestamptz) from public, anon;
revoke all on function public.cmms_triage_failure(uuid,text,text) from public, anon;
revoke all on function public.cmms_create_work_order(uuid,text,text,text,text,text,timestamptz,timestamptz,integer,boolean,text,boolean) from public, anon;
revoke all on function public.cmms_release_work_order(uuid) from public, anon;
revoke all on function public.cmms_assign_work_order(uuid,uuid) from public, anon;
revoke all on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) from public, anon;
revoke all on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) from public, anon;
revoke all on function public.cmms_set_work_order_progress(uuid,text) from public, anon;
revoke all on function public.cmms_decide_work_order(uuid,text,text,text) from public, anon;
revoke all on function public.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) from public, anon;
revoke all on function public.cmms_update_asset(uuid,text,text,uuid,text,uuid,text,text,text,jsonb,text,text[]) from public, anon;
revoke all on function public.cmms_change_asset_status(uuid,text,text) from public, anon;
revoke all on function public.cmms_update_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) from public, anon;
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

grant execute on function public.cmms_report_failure(uuid,text,text,text,text,text,text,text[],timestamptz) to authenticated;
grant execute on function public.cmms_triage_failure(uuid,text,text) to authenticated;
grant execute on function public.cmms_create_work_order(uuid,text,text,text,text,text,timestamptz,timestamptz,integer,boolean,text,boolean) to authenticated;
grant execute on function public.cmms_release_work_order(uuid) to authenticated;
grant execute on function public.cmms_assign_work_order(uuid,uuid) to authenticated;
grant execute on function public.cmms_record_work_order_action(uuid,text,text,integer,numeric,text,numeric,text[]) to authenticated;
grant execute on function public.cmms_submit_work_order_test(uuid,text,text,timestamptz,text,text[]) to authenticated;
grant execute on function public.cmms_set_work_order_progress(uuid,text) to authenticated;
grant execute on function public.cmms_decide_work_order(uuid,text,text,text) to authenticated;
grant execute on function public.cmms_create_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
grant execute on function public.cmms_update_asset(uuid,text,text,uuid,text,uuid,text,text,text,jsonb,text,text[]) to authenticated;
grant execute on function public.cmms_change_asset_status(uuid,text,text) to authenticated;
grant execute on function public.cmms_update_pm_plan(uuid,text,text,text,numeric,text,text,timestamptz,numeric,jsonb) to authenticated;
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
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'cmms-evidence','cmms-evidence',false,10485760,
  array[
    'application/pdf','image/jpeg','image/png','image/webp',
    'image/heic','image/heif','text/csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
)
on conflict (id) do update
set public=false,file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists cmms_evidence_read_by_location on storage.objects;
drop policy if exists cmms_evidence_upload_by_location on storage.objects;

-- A syntactically valid path is not sufficient: the linked record must exist
-- and belong to the asset UUID embedded in the path.
create policy cmms_evidence_read_by_location
on storage.objects for select to authenticated
using (
  bucket_id='cmms-evidence'
  and array_length(string_to_array(storage.objects.name,'/'),1)=5
  and split_part(storage.objects.name,'/',1)='cmms'
  and split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',5) <> ''
  and split_part(storage.objects.name,'/',5) not in ('.','..')
  and position(chr(92) in storage.objects.name)=0
  and exists (
    select 1
    from public.cmms_assets a
    where a.id=case when split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',2)::uuid else null end
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
      and (
        (split_part(storage.objects.name,'/',3)='assets' and split_part(storage.objects.name,'/',4)=a.id::text)
        or (split_part(storage.objects.name,'/',3)='failures' and exists (
          select 1 from public.cmms_failure_reports fr
          where fr.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and fr.asset_id=a.id
        ))
        or (split_part(storage.objects.name,'/',3)='work-orders' and exists (
          select 1 from public.cmms_work_orders wo
          where wo.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and wo.asset_id=a.id
        ))
        or (split_part(storage.objects.name,'/',3)='pm' and exists (
          select 1 from public.cmms_pm_tasks pt
          where pt.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and pt.asset_id=a.id
        ))
      )
  )
);

create policy cmms_evidence_upload_by_location
on storage.objects for insert to authenticated
with check (
  bucket_id='cmms-evidence'
  and array_length(string_to_array(storage.objects.name,'/'),1)=5
  and split_part(storage.objects.name,'/',1)='cmms'
  and split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and split_part(storage.objects.name,'/',5) <> ''
  and split_part(storage.objects.name,'/',5) not in ('.','..')
  and position(chr(92) in storage.objects.name)=0
  and exists (
    select 1 from public.cmms_assets a
    where a.id=case when split_part(storage.objects.name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',2)::uuid else null end
      and (
        (split_part(storage.objects.name,'/',3)='assets'
          and split_part(storage.objects.name,'/',4)=a.id::text
          and (select cmms_private.cmms_has_role_at_location(
            array['technical_expert','technical_supervisor'],a.location_id
          )))
        or
        (split_part(storage.objects.name,'/',3)='failures'
          and exists (
            select 1 from public.cmms_failure_reports fr
            where fr.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and fr.asset_id=a.id
              and (
                fr.reported_by=(select auth.uid())
                or (select cmms_private.cmms_has_role_at_location(
                  array['technical_expert','technical_supervisor'],a.location_id
                ))
              )
          )
          and (select cmms_private.cmms_has_role_at_location(
            array['reporter','technician','technical_expert','technical_supervisor'],a.location_id
          )))
        or
        (split_part(storage.objects.name,'/',3)='work-orders'
          and exists (
            select 1 from public.cmms_work_orders wo
            where wo.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and wo.asset_id=a.id
              and wo.status not in ('closed','cancelled')
              and (
                exists (
                  select 1 from public.cmms_work_order_assignments wa
                  where wa.work_order_id=wo.id and wa.user_id=(select auth.uid())
                    and wa.unassigned_at is null
                )
                or (select cmms_private.cmms_has_role_at_location(
                  array['technical_expert','technical_supervisor'],a.location_id
                ))
              )
          ))
        or
        (split_part(storage.objects.name,'/',3)='pm'
          and exists (
            select 1 from public.cmms_pm_tasks pt
            where pt.id=case when split_part(storage.objects.name,'/',4) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(storage.objects.name,'/',4)::uuid else null end and pt.asset_id=a.id
              and pt.status not in ('completed','cancelled')
              and (
                pt.assigned_to=(select auth.uid())
                or (select cmms_private.cmms_has_role_at_location(
                  array['technical_expert','technical_supervisor'],a.location_id
                ))
              )
          ))
      )
  )
);

-- No UPDATE/DELETE policies. Do not use Storage upsert for this bucket.
-- New versions must use a new object path and be linked through a reviewed,
-- auditable metadata workflow. Signed download URLs still require SELECT access.
