# CMMS V1 — Implementation status (2026-11-18)

## Completed in the feature branch
- Replaced the static CMMS preview cards with a live, read-only data layer in `index.html`.
- Added reads for assets, locations, categories, failure reports, work orders, PM plans, PM tasks, and audit events.
- Dashboard metrics are calculated from returned database rows; no sample/demo counts are used.
- Added loading, query-error, empty-state, and manual-refresh states.
- Added the first equipment master-data form with required-field validation, category/location selectors, technical metadata, criticality, operational status, commissioning and warranty dates, and a local review preview.
- Added a dedicated master-data tab with separate category and hierarchical-location forms. Location fields include code, name, parent location and discipline values aligned to the database CHECK constraint (mechanical, electrical, utilities, production, general); both forms include local required-field validation and case/whitespace-normalized duplicate-code warnings based on currently loaded rows.
- Added read-only tables for existing categories and the location hierarchy. Database-submit controls remain disabled.
- The form's database-submit control is intentionally disabled. The preview validates and displays entered data locally only; it does not create or change database records.
- Switching into CMMS hides the purchase request workspace and its KPIs; switching back restores the existing purchase view.
- CMMS access is now resolved from the authenticated user's active `cmms_user_roles` row, not a hardcoded username allowlist. Current production role assignments were read and matched to the four intended accounts: masoud (technical_supervisor), biabani (responsible_manager), reza (technical_expert), and hamid (technician).
- The `cmms_user_roles` RLS policy allows users to read their own assignment. The browser-side authenticated Data API path has not yet been exercised. If duplicate active role rows exist for one user, `.maybeSingle()` fails closed rather than granting access.
- The role table currently has no uniqueness constraint on `user_id`; this is a governance/schema gap to resolve in a reviewed migration after backup/recovery and staging validation.
- No CMMS INSERT, UPDATE, DELETE, or UPSERT operation was added.
- Existing purchase module code was not intentionally modified beyond view switching to show/hide the CMMS module.

## Verification performed
- Read-only catalog queries confirmed the eight queried CMMS tables and their columns exist in production.
- Current row counts: assets 0, locations 0, failure reports 0, work orders 0, PM plans 0, PM tasks 0.
- The inline JavaScript blocks in the updated HTML passed a JavaScript syntax parse check after the database-backed role-resolution change, equipment form, and master-data forms (all 4 script blocks parse successfully).
- A read-only count confirmed `cmms_asset_categories` and `cmms_locations` remain at 0 rows; no master-data records were written.
- A fresh read-only count confirmed `cmms_assets`, `cmms_locations`, and `cmms_asset_categories` remain at 0 rows; no equipment data was written.
- A read-only catalog query confirmed `cmms_user_roles` has `user_id`, `role`, and `is_active` columns, with a self-read RLS policy; a read-only join confirmed the four current user-to-role assignments.
- Compared the location discipline form options against the live production CHECK constraint and corrected the form to offer only accepted values (`mechanical`, `electrical`, `utilities`, `production`, `general`).
- JavaScript syntax parsing was rerun after this correction; all four inline script blocks parse successfully.
- A read-only constraint inspection confirmed unique constraints on category/location codes and the location self-reference foreign key; no schema was changed.
- The production database was queried with SELECT statements only during this milestone.

## Security review — read-only production inspection

- All 15 public CMMS tables inspected have RLS enabled and currently expose SELECT policies only; no INSERT/UPDATE/DELETE policy was found in this inspection.
- The public CMMS RPC wrapper functions inspected are not executable by either `anon` or `authenticated` in the current database ACL. Therefore, do not assume the write workflows can currently be called by the frontend; explicit least-privilege grants are a required reviewed migration step.
- The `cmms_private` schema is not usable by `anon`, but currently has USAGE for `authenticated`. The two role-check helper functions have EXECUTE for authenticated users because RLS policies call them. This should be included in the security review; do not expose additional private functions through grants.
- Private workflow functions are SECURITY DEFINER but their ACLs deny EXECUTE to anon/authenticated. The public SECURITY DEFINER functions observed are trigger functions and their ACLs also deny direct execution to anon/authenticated.
- This was a metadata/ACL inspection only. No GRANT, REVOKE, schema, policy, or function change was made.

## Not yet verified
- Authenticated browser reads through the Supabase Data API under each of the four CMMS user accounts.
- Cross-role and direct REST access behavior, including validation that the current helper-function exposure does not leak location-role information beyond the intended scope.
- End-to-end purchase regression tests in a browser.
- Any create/edit/approval workflow; the asset form is present but database submission remains disabled, and all CMMS write controls remain disabled/not implemented.
- Browser-level rendering, mobile layout, form validation behavior, and authenticated category/location option reads still require a preview-browser test.
- Master-data category/location create, edit, disable, and delete workflows are not enabled; uniqueness and hierarchy-cycle enforcement must be implemented server-side before writes are allowed.
- Storage uploads, notifications, PM scheduler, and reporting exports.
- Staging migration and isolated acceptance test execution.
- Least-privilege EXECUTE grants for the intended authenticated RPC wrappers; current ACLs deny authenticated execution, so write workflows are not yet callable from the client.

## Release boundary
- This work is on `feature/cmms-v1` only.
- `main` was not merged or deployed.
- No production schema, grants, RLS policies, triggers, functions, storage buckets, or scheduler jobs were changed in this milestone.
- Do not merge or publish until authenticated read tests, role tests, backup/recovery decision, and purchase regression checks are complete.


## Follow-up ACL inventory — 2026-11-18 (read-only)

A second read-only catalog query enumerated all CMMS routines in `public` and `cmms_private`:

- The 27 private routines in `cmms_private` are SECURITY DEFINER with an empty search_path and postgres ownership. The two role-check helpers `cmms_has_any_role(text[])` and `cmms_has_role_at_location(text[], uuid)` additionally grant EXECUTE to `authenticated`; the remaining private routines, including `cmms_user_has_active_role` and the scheduler, are owner-only.
- The public RPC wrappers for CMMS business operations have owner-only EXECUTE ACLs. Their `SECURITY DEFINER` attribute is false; they are invoker functions and are not directly executable by `anon` or `authenticated` under the observed ACL.
- Public trigger functions also show owner-only EXECUTE ACLs. Trigger invocation is managed by trigger bindings; direct client execution is not enabled.
- This confirms the client cannot currently invoke the CMMS write wrappers. Do not solve this by granting EXECUTE broadly on a schema or all functions.
- Before enabling writes, inspect each wrapper's full definition and its corresponding private routine's authorization checks, verify caller identity/role and workflow stage, then draft explicit per-function grants to `authenticated` only for approved wrappers. Keep private routines owner-only. Validate in an isolated staging project and test allowed/denied role cases before any production migration.
- No database writes, grants, revokes, policy changes, or function changes were made during this follow-up inspection.

## Next engineering gate

The next implementation milestone is a function-by-function authorization matrix for the public CMMS RPC wrappers, cross-checked against the four seeded CMMS roles and the intended approval chain (technical supervisor then responsible manager). A wrapper must not be enabled until its authorization contract and negative tests are documented. In parallel, the branch UI remains read-only until this gate and staging validation pass.


## Critical RPC call-chain finding — 2026-11-18 (read-only)

Inspection of representative public wrappers and private implementations found an additional privilege-chain blocker:

- The public business-operation wrappers (for example `public.cmms_create_asset`, `public.cmms_create_work_order`, `public.cmms_decide_work_order`, and `public.cmms_report_failure`) are SQL functions running as INVOKER (their `prosecdef` is false).
- Their corresponding `cmms_private.*` implementations are SECURITY DEFINER but have EXECUTE granted only to postgres. The authenticated caller therefore lacks permission to invoke the private routine through the wrapper, even if EXECUTE were granted on the public wrapper alone.
- Do not grant EXECUTE to authenticated on all private routines. That would expose a large privileged surface and bypass the intended public-wrapper boundary.
- Preferred design for review: make each approved public wrapper a narrow SECURITY DEFINER entry point with a fixed empty search_path and fully-qualified private routine call, while retaining role/location/workflow authorization inside the private implementation; then grant EXECUTE on only that exact public signature to authenticated. Validate ownership, search_path, auth.uid propagation, and negative role tests in staging first. This is a design recommendation, not an applied change.
- The sampled private implementations include authorization checks: asset creation requires technical_supervisor or technical_expert; work-order creation checks those roles at the asset location; failure reporting permits reporter/technician/technical_expert/technical_supervisor at the location; the two-stage approval function checks the designated role and prevents the same user approving both stages. The full set of routines still requires function-by-function review.

This is a newly identified blocker to enabling CMMS writes. No database object or privilege was changed.


## Function-by-function security audit — 2026-11-18

- Completed a read-only catalog and static body review of all 23 private business operations, all 3 private helpers, the PM scheduler, and the public wrapper/trigger inventory.
- Corrected the private routine count: 27 total (23 business operations + 3 helpers + 1 scheduler), not 24.
- Added `docs/CMMS-V1-FUNCTION-BY-FUNCTION-SECURITY-AUDIT-2026-11-18.md` with per-function authorization, validation, workflow, and P0/P1 findings.
- Identified unnecessary authenticated EXECUTE on `cmms_private.cmms_user_has_active_role(uuid,text[])`; no CMMS RLS policy references this helper, and it accepts an arbitrary user UUID. The staging-only draft now revokes client EXECUTE on this helper.
- Confirmed the existing narrow-wrapper pattern is viable for staging review only: exact public signatures, SECURITY DEFINER, empty search_path, REVOKE from PUBLIC/anon, GRANT to authenticated; private write routines and scheduler remain owner-only.
- Added an acceptance assertion for the helper revoke and corrected the private routine count to 27.
- No SQL was executed against Production or Staging. No database object, ACL, policy, trigger, storage, or scheduler was changed. No backup or restore was performed.
- `feature/cmms-v1` only; `main` and production deployment remain unchanged.


## Isolated Staging build and first acceptance run — 2026-11-18

The earlier statement that no Staging SQL had been executed is superseded by this section.

### Staging environment
- Project: `mehrsa-cmms-staging` (`sdemtfdzpwcbiiysaipm`), PostgreSQL 17.12, ACTIVE_HEALTHY.
- Staging began with no public CMMS tables and no tracked migrations.
- Created minimal compatibility stubs for `public.pr_requests` and `public.user_profiles` only to satisfy the CMMS foreign-key/function dependencies. Both stubs have RLS enabled, no client grants and no policies. They contain no production data and do not reproduce the live purchase module.
- Created four synthetic Auth identities and matching profile/CMMS role rows for database-level tests only. No production identities, credentials or operational data were copied.

### SQL layers applied successfully to Staging
1. CMMS base schema (15 tables).
2. CMMS hardening triggers and constraints.
3. Location/role RLS authorization layer.
4. Workflow RPCs and least-privilege ACLs.
5. P1 business-rule hardening.
6. Purchase-link authorization hardening.
7. Private evidence bucket and Storage object policies.

All seven SQL layers returned success. Production was not targeted.

### Verified Staging outcomes
- 15/15 CMMS tables have RLS enabled.
- 15 read policies exist; all are SELECT-only.
- Authenticated has SELECT but no direct INSERT/UPDATE/DELETE on CMMS tables; anon has no CMMS table SELECT.
- Public business wrappers are SECURITY INVOKER. Authenticated can execute approved wrappers; anon cannot. Private workflow implementations are SECURITY DEFINER and have narrow EXECUTE grants. The internal arbitrary-user role lookup helper `cmms_user_has_active_role` remains owner-only.
- PM scheduler is not executable by authenticated users; its service-role/owner path remains separate.
- Purchase-link tests passed: authorized expert can link; duplicate returns the same link id; technician without supervisor/expert role is denied; unknown PR is denied.
- RLS smoke test passed: an active expert sees the test asset; a caller with no active profile sees zero assets.
- Corrective workflow passed end-to-end: failure report → technical triage → release → assignment → execution log → successful test → supervisor approval → distinct responsible-manager approval → closed.
- PM workflow passed: plan creation → server-side due-task generation → repeated scheduler run without duplicate tasks → assignment → start → checklist completion.
- Retirement guard passed: retirement was blocked while an active work order or active PM plan remained; after the test work order was cancelled and PM plan deactivated, retirement succeeded.
- Storage policy test initially exposed a real bug: unqualified `name` references inside nested subqueries resolved to `cmms_assets.name`, not `storage.objects.name`. The policy draft was corrected to qualify the outer object name. After reapplying, valid expert asset-evidence upload passed, technician asset-master upload was denied, and an authorized expert could read linked evidence. The synthetic metadata-only test object was cleaned using the Storage lifecycle cleanup routine; no file bytes were uploaded.

### Remaining Staging validation
- The current test run used synthetic database identities and SQL-level JWT claim simulation. It is not a substitute for real browser/Auth JWT and Storage HTTP API tests.
- The Storage upload test validated RLS metadata authorization only; actual byte upload/download, signed URLs, MIME spoofing and content scanning remain untested.
- Supabase Security Advisor reports no CMMS-specific ERROR after the build. Remaining items: INFO notices for the intentionally closed compatibility stubs (RLS enabled with no policies), a project-level leaked-password-protection warning, and performance INFO notices for 23 unindexed foreign keys plus unused indexes in the low-volume test database.
- Confirm the Data API exposed-schema list in the Supabase dashboard and ensure `cmms_private` is not exposed. SQL session configuration did not reveal this project-level setting.
- No scheduler has been installed or scheduled; cron runtime behavior still requires separate testing.
- No actual mobile/browser workflow or purchase-module regression has been run because Staging contains only compatibility stubs, not the live purchase app schema/data.

### Release status
- Production schema, functions, grants, Storage and scheduler remain unchanged.
- `main` remains unchanged.
- External backup/restore, real API tests, UI integration/regression, scheduler validation and explicit release approval remain mandatory.
