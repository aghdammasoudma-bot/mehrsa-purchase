# CMMS V1 — evidence storage and purchase-link security review
Date: 2026-11-18
Branch: feature/cmms-v1
Status: draft artifacts only; no Production or Staging changes were applied.

## 1. Evidence storage findings and controls
- Production currently has no Storage buckets or objects. The CMMS evidence bucket is not live.
- Existing draft is tightened to enforce the exact five-segment object path:
  `cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}`.
- Bucket is private, max object size 10 MiB, and declared MIME allowlist is PDF, JPEG, PNG, WebP, HEIC/HEIF, CSV and XLSX.
- Upload authorization is record-specific:
  - asset master evidence: technical supervisor/expert;
  - failure evidence: original reporter or technical supervisor/expert, with location role;
  - work-order evidence: currently assigned worker or technical supervisor/expert, only while WO is active;
  - PM evidence: assigned technician or technical supervisor/expert, only while task is active.
- Read authorization requires a real linked record, matching asset UUID and a CMMS role at that asset location.
- No UPDATE or DELETE policy is created. Clients must not use upsert. New evidence versions need a new path and a separate audited metadata workflow.
- Signed download URLs depend on SELECT policy and must be tested with real authenticated users.
- MIME allowlists check declared content type, not actual file bytes. Malware scanning or content-signature verification requires a trusted server-side process.

## 2. Purchase request link findings and controls
- The existing private SECURITY DEFINER function checked that the work order was open, the caller had a technical supervisor/expert role at the asset location, and the PR id existed.
- Because SECURITY DEFINER bypasses table RLS, merely checking PR existence was insufficient: it did not reproduce the active internal-profile authorization in the current `pr_requests` SELECT policy.
- Revised draft explicitly requires the caller to have an active `user_profiles` row with one of the roles currently admitted by that SELECT policy: admin, tech, maintenance, planner or procurement. The CMMS supervisor/expert location-role check remains.
- Duplicate links now return the existing link id rather than failing on the unique constraint.
- Closed/cancelled work orders and unknown PR ids remain rejected.
- No changes are made to the existing purchase request table, policies, or purchase RPCs.
- Public wrapper remains SECURITY INVOKER; exact EXECUTE grants are deliberately deferred to the separate reviewed RPC privilege-chain migration.

## 3. Required Staging tests
See `supabase/tests/cmms_v1_evidence_purchase_link_acceptance.sql`.
Tests must cover role/location boundaries, record ownership/assignment, malformed paths, private downloads, update/delete denial, duplicate link idempotency, and purchase-module regression.

## 4. Safety and release gates
- No Storage bucket/policy was created in Production.
- No purchase-link function was replaced in Production.
- No API EXECUTE grant was issued.
- No Staging SQL was run; SQL syntax and policy behavior remain unvalidated against the isolated Staging catalog.
- The existing production CMMS tables are write-locked. Do not enable RPCs or deploy Storage until external backup/restore and Staging validation are complete.
