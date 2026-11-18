# CMMS V1 — evidence storage and purchase-link security review
Date: 2026-11-18
Branch: feature/cmms-v1
Status: catalog reconciliation completed read-only; draft artifacts updated only. No Production or Staging changes were applied.

## 1. Production catalog reconciliation (read-only)

Verified directly against Production catalog:
- `cmms_work_order_purchase_links` columns are `id uuid`, `work_order_id uuid`, `purchase_request_id text`, `created_by uuid`, `created_at timestamptz`.
- Unique constraint exists on `(work_order_id, purchase_request_id)`; foreign keys reference `cmms_work_orders(id)`, `pr_requests(id)`, and `auth.users(id)`.
- `user_profiles` has `user_id uuid`, `username`, `full_name`, `role text`, `is_active boolean`. Active role values currently present: admin, tech, maintenance, planner, procurement.
- Exact `pr_requests` SELECT policy allows an authenticated caller with an active `user_profiles` row whose role is one of admin, tech, maintenance, planner, procurement.
- `cmms_pm_tasks` has `asset_id uuid`, `status text`, `assigned_to uuid`; status constraint allows due, assigned, in_progress, completed, overdue, cancelled.
- `cmms_work_order_assignments` uses `work_order_id`, `user_id`, `unassigned_at`; `cmms_failure_reports` uses `asset_id`, `reported_by`.
- The current private purchase-link function is SECURITY DEFINER and only checks PR existence; the public wrapper is SECURITY INVOKER. Both currently have owner-only EXECUTE ACL.
- `cmms_private.cmms_has_role_at_location(text[], uuid)` grants EXECUTE to authenticated; `cmms_user_has_active_role` is owner-only.
- Production has no `cmms-evidence` bucket and no CMMS Storage object policies.
- The purchase-link unique constraint supports the draft's `ON CONFLICT (work_order_id,purchase_request_id)` clause.

## 2. Evidence storage findings and controls
- Production currently has no Storage buckets or objects. The CMMS evidence bucket is not live.
- Draft path format is exact:
  `cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}`.
- Bucket is private, max object size 10 MiB, and declared MIME allowlist is PDF, JPEG, PNG, WebP, HEIC/HEIF, CSV and XLSX.
- Upload authorization is record-specific:
  - asset master evidence: technical supervisor/expert;
  - failure evidence: original reporter or technical supervisor/expert, with location role;
  - work-order evidence: currently assigned worker or technical supervisor/expert, only while WO is active;
  - PM evidence: assigned technician or technical supervisor/expert, only while task is active.
- The field names used by the draft were reconciled with Production: `reported_by`, `assigned_to`, `unassigned_at`, and PM statuses.
- Read authorization requires a real linked record, matching asset UUID and a CMMS role at that asset location.
- No UPDATE or DELETE policy is created. Clients must not use upsert. New evidence versions need a new path and a separate audited metadata workflow.
- Signed download URLs depend on SELECT policy and must be tested with real authenticated users.
- MIME allowlists check declared content type, not actual file bytes. Malware scanning or content-signature verification requires a trusted server-side process.
- Remaining configuration gate: confirm in the Supabase API settings that `cmms_private` is not an exposed Data API schema before any Storage policy is applied. Database schema USAGE is currently granted to authenticated; function ACLs and API schema exposure are separate controls.

## 3. Purchase-link draft changes
- Draft now explicitly reproduces the current `pr_requests` SELECT authorization check for active internal profile roles.
- Draft rejects blank IDs, missing PRs, PRs without an accountable `created_by`, and closed/cancelled work orders.
- Draft returns the existing link id on duplicate instead of creating a duplicate row.
- Draft uses row locks on the work order, asset, and PR lookup to reduce races with concurrent status/ownership changes.
- Public wrapper remains SECURITY INVOKER; exact EXECUTE grants are deliberately deferred to the separate reviewed RPC privilege-chain migration.
- Production's existing function has not been replaced.

## 4. Required Staging tests
See `supabase/tests/cmms_v1_evidence_purchase_link_acceptance.sql`.
Tests must cover role/location boundaries, record ownership/assignment, malformed paths, private downloads, update/delete denial, duplicate link idempotency, and purchase-module regression. Also verify the API schema exposure configuration and the helper-function privilege chain.

## 5. Safety and release gates
- This reconciliation used SELECT/catalog queries only.
- No Storage bucket/policy was created in Production.
- No purchase-link function was replaced in Production.
- No API EXECUTE grant was issued.
- No Staging SQL was run; SQL syntax and policy behavior remain unvalidated against isolated Staging.
- The existing production CMMS tables are write-locked. Do not enable RPCs or deploy Storage until external backup/restore and Staging validation are complete.
