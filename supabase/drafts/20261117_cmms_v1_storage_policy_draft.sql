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
