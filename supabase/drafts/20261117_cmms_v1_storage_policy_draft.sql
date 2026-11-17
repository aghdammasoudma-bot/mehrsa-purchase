-- DRAFT ONLY — private evidence bucket and row-level object policies.
-- NOT APPLIED. Depends on CMMS base schema + authorization helper schema.
-- Storage object path: cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}
-- record_type: assets | failures | work-orders | pm
-- Use authenticated signed URLs only. Never make this bucket public.

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
    'text/csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
)
on conflict (id) do update
set public=false,
    file_size_limit=excluded.file_size_limit,
    allowed_mime_types=excluded.allowed_mime_types;

-- Read: any authorized CMMS role at the asset's location, including the
-- responsible manager (global in v1). Object must reference a real CMMS record.
create policy cmms_evidence_read_by_location
on storage.objects for select to authenticated
using (
  bucket_id='cmms-evidence'
  and split_part(name,'/',1)='cmms'
  and split_part(name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1
    from public.cmms_assets a
    where a.id=(split_part(name,'/',2))::uuid
      and cmms_private.cmms_has_role_at_location(
        array['reporter','technician','technical_expert','technical_supervisor','responsible_manager'],
        a.location_id
      )
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

-- Upload: scope and record linkage are validated. Governance roles can attach
-- evidence to asset records; assigned technical roles can attach work evidence.
create policy cmms_evidence_upload_by_location
on storage.objects for insert to authenticated
with check (
  bucket_id='cmms-evidence'
  and split_part(name,'/',1)='cmms'
  and split_part(name,'/',2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1
    from public.cmms_assets a
    where a.id=(split_part(name,'/',2))::uuid
      and (
        (split_part(name,'/',3)='assets'
          and split_part(name,'/',4)=a.id::text
          and cmms_private.cmms_has_role_at_location(
            array['technical_expert','technical_supervisor'],a.location_id
          ))
        or
        (split_part(name,'/',3)='failures'
          and exists (
            select 1 from public.cmms_failure_reports fr
            where fr.id::text=split_part(name,'/',4) and fr.asset_id=a.id
          )
          and cmms_private.cmms_has_role_at_location(
            array['reporter','technician','technical_expert','technical_supervisor'],a.location_id
          ))
        or
        (split_part(name,'/',3)='work-orders'
          and exists (
            select 1 from public.cmms_work_orders wo
            where wo.id::text=split_part(name,'/',4) and wo.asset_id=a.id
          )
          and cmms_private.cmms_has_role_at_location(
            array['technician','technical_expert','technical_supervisor'],a.location_id
          ))
        or
        (split_part(name,'/',3)='pm'
          and exists (
            select 1 from public.cmms_pm_tasks pt
            where pt.id::text=split_part(name,'/',4) and pt.asset_id=a.id
          )
          and cmms_private.cmms_has_role_at_location(
            array['technician','technical_expert','technical_supervisor'],a.location_id
          ))
      )
  )
);

-- Intentionally no UPDATE or DELETE policy: evidence objects are immutable.
-- Replacements must be new versioned paths and must be linked in the relevant
-- CMMS record through an audited RPC. Verify storage.objects RLS is enabled.
