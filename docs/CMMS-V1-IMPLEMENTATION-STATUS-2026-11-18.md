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
- The `cmms_user_roles` RLS policy allows users to read their own assignment. The browser-side authenticated Data API path has not yet been exercised. Users may hold multiple active roles. The latest branch code now fetches all active assignments and resolves a deterministic display/permission precedence; the real authenticated Data API path remains untested.
- The role table intentionally permits multiple role/location assignments per user through its composite uniqueness rule; the frontend now handles multiple active roles rather than assuming a single row.
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
- Real browser/Auth API tests, Storage HTTP tests, full purchase regression and clean-project migration replay; Staging migration and SQL-level acceptance have since been completed.
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
- Staging design selected and compiled: public business wrappers remain SECURITY INVOKER; only approved public signatures and their exact private SECURITY DEFINER implementations receive authenticated EXECUTE. Trigger-only routines and `cmms_user_has_active_role` remain owner-only. This pattern is safe only if `cmms_private` is excluded from the exposed Data API schemas; dashboard confirmation and real API/JWT tests remain release gates.
- The sampled private implementations include authorization checks: asset creation requires technical_supervisor or technical_expert; work-order creation checks those roles at the asset location; failure reporting permits reporter/technician/technical_expert/technical_supervisor at the location; the two-stage approval function checks the designated role and prevents the same user approving both stages. The full set of routines still requires function-by-function review.

This was a privilege-chain blocker before staging validation. The narrow invoker/private-definer chain now compiles and its ACLs have been verified in isolated Staging; Production remains unchanged.


## Function-by-function security audit — 2026-11-18

- Completed a read-only catalog and static body review of all 23 private business operations, all 3 private helpers, the PM scheduler, and the public wrapper/trigger inventory.
- Corrected the private routine count: 27 total (23 business operations + 3 helpers + 1 scheduler), not 24.
- Added `docs/CMMS-V1-FUNCTION-BY-FUNCTION-SECURITY-AUDIT-2026-11-18.md` with per-function authorization, validation, workflow, and P0/P1 findings.
- Identified unnecessary authenticated EXECUTE on `cmms_private.cmms_user_has_active_role(uuid,text[])`; no CMMS RLS policy references this helper, and it accepts an arbitrary user UUID. The staging-only draft now revokes client EXECUTE on this helper.
- Confirmed the staging wrapper pattern: exact public signatures remain SECURITY INVOKER; approved private SECURITY DEFINER implementations receive exact authenticated EXECUTE; helper `cmms_user_has_active_role` and trigger-only routines remain owner-only; scheduler remains service-role/owner-only.
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

All nine SQL layers (base schema, hardening, authorization, role seed, workflow RPCs, P1 rules, purchase-link hardening, FK indexes and Storage policies) returned success. Production was not targeted.

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
- Supabase Security Advisor reports no CMMS-specific ERROR after the build. Remaining items: INFO notices for the intentionally closed compatibility stubs (RLS enabled with no policies), a project-level leaked-password-protection warning, and performance INFO notices for unused indexes only; the 23 unindexed CMMS foreign keys were addressed by the staging-only FK-index migration.
- Confirm the Data API exposed-schema list in the Supabase dashboard and ensure `cmms_private` is not exposed. SQL session configuration did not reveal this project-level setting.
- No scheduler has been installed or scheduled; cron runtime behavior still requires separate testing.
- No actual mobile/browser workflow or purchase-module regression has been run because Staging contains only compatibility stubs, not the live purchase app schema/data.

### Release status
- Production schema, functions, grants, Storage and scheduler remain unchanged.
- `main` remains unchanged.
- External backup/restore, real API tests, UI integration/regression, scheduler validation and explicit release approval remain mandatory.


### Expanded Staging negative tests and performance follow-up — 2026-11-18
- Added a scoped technician in a separate sibling location; the user could not read an asset in another location (0 rows), confirming location isolation.
- Work-order creator self-approval was rejected by the database trigger.
- P1 negative tests passed: negative duration, NaN quantity, infinite meter reading, meter reading on a retired asset, PM-plan creation for a retired asset, and failure reporting for a retired asset were all rejected.
- A staging-only foreign-key index draft was added and applied. Supabase Performance Advisor no longer reports unindexed CMMS foreign keys. It now reports unused indexes only; this is expected on the low-volume staging database and is not a reason to remove workload-supporting indexes without production query evidence.
- Front-end read-only bug fixed in `index.html`: the CMMS dashboard now fetches audit logs only for technical supervisor/responsible manager roles. Previously, a technician/expert could receive an RLS denial for the governance-only audit table and have the entire dashboard marked as failed.
- UI write actions are still not implemented/enabled. The current UI contains read-only tables and local preview forms; this is not yet a complete operational CMMS frontend.


### Release-candidate review boundary — 2026-11-18
- Opened Draft PR #1 from `feature/cmms-v1` to `main`; PR is intentionally Draft and not merged.
- PR-triggered JavaScript syntax CI completed successfully.
- Final read-only Production check reconfirmed: 15 CMMS tables, 15 policies, four active CMMS roles, no `cmms-evidence` bucket, and no authenticated/anon EXECUTE on the public purchase-link wrapper.
- Production migration history is empty; the current Production CMMS schema was not installed through tracked Supabase migrations. The release-candidate migration therefore still requires careful live-schema reconciliation after backup before it can be run in Production.
- Production remains untouched by this Staging migration and test work; `main` remains at the PR base commit.


### Backup preparation
- Added `docs/CMMS-V1-PRODUCTION-BACKUP-CODESPACES-RUNBOOK.md` for a safe Codespaces-based export workflow, including hidden credential entry, no-commit/no-public-artifact rules, checksums and restore gates.
- Read-only Production counts: 6 Auth users, 6 Auth identities, 6 user profiles; zero Storage buckets and zero Storage objects.
- The runbook explicitly requires verifying whether the actual CLI dump contains Auth users/identities. If it does not, the logical dump is not treated as a complete recovery package; use a supported clone/backup or verified Auth export/restore process.
- No backup file has been generated, downloaded or restored.


### Frontend read-model enrichment
- The CMMS frontend now loads work-order assignments, action logs, approvals and meter readings under their existing RLS policies; purchase links are loaded only for technical expert/supervisor/responsible manager roles.
- The work-order table now shows active assignee IDs, action counts and approval-stage summaries.
- SQL-level role checks confirmed the relevant read queries succeed for a technician, expert and supervisor; governance-only audit reads remain limited to supervisor/manager.
- Push and PR JavaScript syntax CI passed for the updated branch.
- This is still a read model only. Operational write forms and browser/API tests remain outstanding.


## Operational frontend milestone — 2026-11-18 (feature branch only)

This section supersedes earlier statements that all CMMS forms were preview-only/read-only. The latest branch UI now calls the approved Staging-validated public RPC wrappers for:

- Asset master creation, restricted in the UI to technical supervisor and technical expert; server-side role/location validation remains authoritative.
- Failure reporting by technician, technical expert or technical supervisor; technical expert/supervisor triage can convert a report into a corrective work order or reject it with a reason.
- Independent work-order creation by technical expert/supervisor; technical release; supervisor-only technician assignment; action logging; execution progress transitions; test result submission; technical-supervisor approval followed by separate responsible-manager approval.
- Calendar-based PM plan creation, supervisor assignment of PM tasks, assigned technician/expert start, and checklist-backed completion.

The frontend reads role-scoped assignment rows only for the technical supervisor; manager-only governance access does not expose assignment controls. Assignment candidates are filtered to global or matching asset-location roles before the RPC call. The database remains the final authorization boundary.

### Verification in this milestone
- Inline JavaScript syntax checks passed in both push and PR GitHub Actions for the current feature branch head.
- Rollback-only SQL acceptance calls in isolated Staging validated the exact RPC signatures for failure report creation, failure triage/conversion, independent work-order creation, and calendar PM plan creation. Test transactions were rolled back; no durable fixture records were added.
- No browser-based real-user JWT test has yet been performed. The frontend workflows are implemented but are not yet certified end-to-end in a browser.
- Category/location master-data create/edit workflows, work-order reassignment/cancellation, meter-based PM setup, evidence upload UI, notifications, and reporting exports remain incomplete.

Production and main remain unchanged. The PR remains Draft. This milestone does not authorize production deployment.


### Additional equipment controls — 2026-11-18
- Added controlled asset operational-status changes with mandatory reason, confirmation before retirement, and server-side retirement guards.
- Added meter-reading capture for technician, technical expert and technical supervisor, plus a latest-readings view using the verified reading_at column.
- Rollback-only Staging SQL checks succeeded for meter-reading and asset-status RPC signatures. The transaction was rolled back, leaving the sample asset unchanged.
- Current branch head: 659444c9bcefc0d31234c3f928c5af43cccbf325; push and PR syntax checks passed.
