-- CMMS evidence + purchase-link acceptance checks.
-- Run ONLY against isolated Staging with disposable fixtures and real role JWTs.
-- This file is a test plan/query aid; it has not been executed.

-- A. Storage catalog assertions (must return the expected single bucket and 2 policies).
select id,name,public,file_size_limit,allowed_mime_types
from storage.buckets where id='cmms-evidence';

select policyname,cmd
from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname in ('cmms_evidence_read_by_location','cmms_evidence_upload_by_location')
order by policyname;

-- B. Confirm there is no UPDATE or DELETE policy for the evidence bucket.
select policyname,cmd
from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname ilike 'cmms_evidence%'
  and cmd in ('UPDATE','DELETE');

-- C. Positive/negative Storage API cases to execute with authenticated clients:
-- 1. supervisor/expert uploads asset evidence for an asset in their location: ALLOW.
-- 2. technician uploads to an asset master record: DENY.
-- 3. assigned technician uploads to an active work-order record: ALLOW.
-- 4. unassigned technician uploads to that work-order record: DENY.
-- 5. assigned technician uploads to a closed/cancelled work order: DENY.
-- 6. original failure reporter uploads to their failure record: ALLOW.
-- 7. unrelated reporter uploads to another user's failure record: DENY.
-- 8. assigned technician uploads to an active PM task: ALLOW.
-- 9. unassigned technician uploads to another PM task: DENY.
-- 10. user from another location downloads any evidence object: DENY.
-- 11. anonymous download: DENY.
-- 12. UPDATE, DELETE and upsert replacement: DENY.
-- 13. malformed paths, unknown record type, wrong asset UUID, wrong record UUID,
--     empty filename, dot-segment filename and backslash path: DENY.
-- 14. MIME not in bucket allowlist and object > 10 MiB: DENY.
-- Note: MIME allowlists validate declared content type, not file bytes. If malware
-- scanning/content-signature validation is required, add a trusted server-side scan.

-- D. Purchase-link positive/negative cases with real authenticated JWTs:
-- 1. technical supervisor/expert with active legacy internal profile links existing PR: ALLOW.
-- 2. same user links same PR to same WO twice: return same link id; no duplicate row.
-- 3. CMMS user without active allowed user_profiles role: DENY.
-- 4. CMMS user lacking technical supervisor/expert location role: DENY.
-- 5. unknown PR id: DENY.
-- 6. closed/cancelled WO: DENY.
-- 7. cross-location WO: DENY.
-- 8. anonymous caller: DENY.
-- 9. direct INSERT/UPDATE/DELETE on link table by authenticated: DENY.
-- 10. confirm PR visibility under current RLS is preserved for planner/procurement
--     and existing purchase workflow regression tests remain unchanged.
