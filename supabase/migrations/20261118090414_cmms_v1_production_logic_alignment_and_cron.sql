-- Align CMMS V1 business-rule routines with the Staging-validated release candidate.
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

create or replace function cmms_private.cmms_link_purchase_request(
  p_work_order_id uuid,
  p_purchase_request_id text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_link_id uuid;
  v_request_created_by uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if nullif(btrim(coalesce(p_purchase_request_id,'')),'') is null then
    raise exception 'Purchase request id is required';
  end if;

  -- Serialize against concurrent status transitions so a closed/cancelled WO
  -- cannot pass this check while another transaction closes it.
  select w.* into v_wo
  from public.cmms_work_orders w
  where w.id=p_work_order_id
  for update;

  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Only an open work order can be linked to a purchase request';
  end if;

  -- Lock asset location while authorization is evaluated.
  select a.location_id into v_location_id
  from public.cmms_assets a
  where a.id=v_wo.asset_id
  for share;

  if not found then
    raise exception 'Work order asset not found';
  end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then
    raise exception 'Only technical supervisor or expert can link a purchase request';
  end if;

  -- SECURITY DEFINER bypasses pr_requests RLS. Reproduce its current SELECT
  -- policy explicitly: any active internal profile role may read requests.
  if not exists (
    select 1 from public.user_profiles up
    where up.user_id=auth.uid()
      and up.is_active
      and up.role in ('admin','tech','maintenance','planner','procurement')
  ) then
    raise exception 'User is not authorized to access purchase requests';
  end if;

  -- Lock the request row so its existence/creator cannot change during linking.
  select pr.created_by into v_request_created_by
  from public.pr_requests pr
  where pr.id=p_purchase_request_id
  for share;

  if not found then
    raise exception 'Purchase request not found';
  end if;

  if v_request_created_by is null then
    raise exception 'Purchase request has no accountable creator';
  end if;

  insert into public.cmms_work_order_purchase_links(
    work_order_id,purchase_request_id,created_by
  )
  values(p_work_order_id,p_purchase_request_id,auth.uid())
  on conflict (work_order_id,purchase_request_id) do nothing
  returning id into v_link_id;

  if v_link_id is null then
    select l.id into v_link_id
    from public.cmms_work_order_purchase_links l
    where l.work_order_id=p_work_order_id
      and l.purchase_request_id=p_purchase_request_id;
  end if;

  return v_link_id;
end;
$function$;

-- The public SECURITY INVOKER wrapper, if present, must remain SECURITY INVOKER.
-- Do not grant broad EXECUTE. The exact private-function EXECUTE grant belongs
-- in the separately reviewed RPC privilege-chain migration after tests.


-- =====================================================================
-- SOURCE: supabase/drafts/cmms_v1_fk_indexes_STAGING_ONLY.sql
-- =====================================================================
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


-- =====================================================================
-- SOURCE: supabase/drafts/20261117_cmms_v1_storage_policy_draft.sql
-- =====================================================================
-- DRAFT ONLY — private evidence bucket and hardened row-level object policies.
-- STAGING ONLY. Do not apply to Production.
-- Path: cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}
-- record_type: assets | failures | work-orders | pm
-- Objects are immutable: no UPDATE or DELETE policies are created.

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

-- Required staging verification:
-- * Compile all replaced functions against staging schema before runtime tests.
-- * Assert retired asset cannot receive manual meter readings, PM plan create/update,
--   scheduler-generated PM tasks, or failure->WO conversion.
-- * Assert retirement is denied with any nonterminal work order or active PM plan.
-- * Assert negative, NaN, and +/-Infinity quantity/meter_reading are rejected.
-- * Assert zero values remain accepted; positive values remain accepted.
-- * Run concurrent test: retirement vs meter reading / PM update / scheduler.


-- =====================================================================
-- SOURCE: supabase/drafts/cmms_v1_purchase_link_hardening_STAGING_ONLY.sql
-- =====================================================================
-- CMMS V1 purchase-request link authorization hardening.
-- DRAFT ONLY — apply and test in isolated Staging after schema reconciliation.
-- Does not grant EXECUTE to API roles and does not modify the live purchase module.


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
create extension if not exists pg_cron;
