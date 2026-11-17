-- DRAFT ONLY — private evidence bucket and row-level object policies.
-- NOT APPLIED. Depends on CMMS base schema + authorization helper schema.
-- Object path must contain exactly five segments:
-- cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}
-- record_type: assets | failures | work-orders | pm
-- Bucket remains private; access is via authenticated requests/signed URLs.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values (
  'cmms-evidence',
  'cmms-evidence',
  false,
  10485760,
  array[
    'application/pdf',
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
    'text/csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Read: any authorized CMMS role at the asset's location, including the
-- responsible manager (global in v1). The referenced record must exist.
create policy cmms_evidence_read_by_location
on storage.objects for select to authenticated
using (
  bucket_id='cmms-evidence'
  and array_length(string_to_array(name,'/'),1)=5
  and split_part(name,'/',1)='cmms'
  and split_part(name,'/',5)<>''
  and exists (
    select 1
    from public.cmms_assets a
    where a.id = case
      when split_part(name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then split_part(name,'/',2)::uuid
      else null
    end
      and (select cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      ))
      and (
        (split_part(name,'/',3)='assets' and split_part(name,'/',4)=a.id::text)
        or
        (split_part(name,'/',3)='failures' and exists (
          select 1 from public.cmms_failure_reports fr
          where fr.id::text=split_part(name,'/',4) and fr.asset_id=a.id
        ))
        or
        (split_part(name,'/',3)='work-orders' and exists (
          select 1 from public.cmms_work_orders wo
          where wo.id::text=split_part(name,'/',4) and wo.asset_id=a.id
        ))
        or
        (split_part(name,'/',3)='pm' and exists (
          select 1 from public.cmms_pm_tasks pt
          where pt.id::text=split_part(name,'/',4) and pt.asset_id=a.id
        ))
      )
  )
);

-- Upload: governance roles can attach to asset records; failure reporters and
-- assigned workers can attach evidence to their own workflow records.
create policy cmms_evidence_upload_by_location
on storage.objects for insert to authenticated
with check (
  bucket_id='cmms-evidence'
  and array_length(string_to_array(name,'/'),1)=5
  and split_part(name,'/',1)='cmms'
  and split_part(name,'/',5)<>''
  and exists (
    select 1
    from public.cmms_assets a
    where a.id = case
      when split_part(name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then split_part(name,'/',2)::uuid
      else null
    end
      and (
        (split_part(name,'/',3)='assets'
          and split_part(name,'/',4)=a.id::text
          and (select cmms_private.cmms_has_role_at_location(
            array['technical_expert','technical_supervisor'],a.location_id
          )))
        or
        (split_part(name,'/',3)='failures'
          and exists (
            select 1 from public.cmms_failure_reports fr
            where fr.id::text=split_part(name,'/',4) and fr.asset_id=a.id
          )
          and (select cmms_private.cmms_has_role_at_location(
            array['reporter','technician','technical_expert','technical_supervisor'],a.location_id
          )))
        or
        (split_part(name,'/',3)='work-orders'
          and exists (
            select 1 from public.cmms_work_orders wo
            where wo.id::text=split_part(name,'/',4) and wo.asset_id=a.id
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
        (split_part(name,'/',3)='pm'
          and exists (
            select 1 from public.cmms_pm_tasks pt
            where pt.id::text=split_part(name,'/',4) and pt.asset_id=a.id
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

-- No UPDATE or DELETE policy: evidence objects are immutable. Replacements
-- require a new versioned path linked by an audited CMMS RPC. Verify
-- storage.objects RLS is enabled before applying this draft.
