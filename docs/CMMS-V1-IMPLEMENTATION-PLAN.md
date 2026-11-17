# CMMS v1 — Technical Department Implementation Plan

Status: production schema partially installed and write-locked; not operational and not released.

## Guardrails
- Keep production branch `main` unchanged.
- Build only on `feature/cmms-v1`.
- Existing purchase requests remain in `public.pr_requests`; the current UI and RPC workflow must remain backward compatible.
- Do not apply further production DDL, grant workflow RPCs, enable Storage, or deploy the CMMS UI until an independently restorable off-site backup has been produced and restore-tested.
- Production currently contains 15 CMMS tables with RLS enabled and SELECT-only policies. No client write grants or executable public CMMS RPCs are enabled.
- No sample/fake operational records in production.

## Verified current system
- Supabase project: `jpzgtbafrpjjbtwqwzlr`, Postgres 17, ACTIVE_HEALTHY.
- Public tables: `pr_requests` (46 rows), `user_profiles` (6 rows), `technical_work_orders` (3 rows).
- `pr_requests.id` is TEXT; use that exact type for the optional work-order purchase link.
- Existing profile roles: admin, tech, maintenance, planner, procurement.
- Existing `technical_work_orders` is a basic task/mission table; it is not a full CMMS work-order model.
- Existing purchase workflow uses SECURITY DEFINER RPC functions. Do not change those functions as part of CMMS v1.
- Existing database has no recorded migration history in Supabase migration metadata.

## Backup checkpoint
An internal snapshot was created and verified in `private_backup.snapshots` under id `pre_cmms_2026_11_17`.
It contains all rows from the three public tables, public table column metadata, four public RLS policies, seven public function definitions, Auth user metadata (excluding password hashes and tokens), and Storage metadata.
Verified counts: 46 purchase requests, 6 profiles, 3 technical work orders, 7 functions, 4 policies, 6 Auth metadata records, 0 Storage buckets and 0 Storage objects.
Important limitation: this is an in-project logical snapshot, not an off-site disaster-recovery backup. It does not contain password hashes, active sessions, project settings, API keys, or actual Storage object bytes. No further database changes may be applied until a downloadable external backup is available and restore-tested.

## CMMS scope
Technical Department only. Assets include production, electrical, mechanical, and utility equipment. v1 supports corrective/emergency maintenance and preventive maintenance (PM).

## Modules
1. Asset register and hierarchical locations.
2. Failure reports with priority, downtime, symptoms, and optional attachments.
3. Work orders with assignment, action/time/parts logs, testing, and return-to-service.
4. PM plans and due tasks.
5. Two-stage closeout: Technical Supervisor approval, then responsible Manager approval.
6. Asset maintenance history and operational dashboard.
7. Link a work order to an existing purchase request when parts/services are needed.

## Workflow rules
- Failure report is distinct from work order.
- A failure report is reviewed before a work order is opened.
- Critical failure is highlighted and downtime is captured.
- Work order cannot close without a test result and both approvals.
- Supervisor and Manager approval are distinct identities; neither may substitute for the other.
- Rejection requires a reason and returns the order to correction.
- PM task generation must be server-side scheduled, not dependent on a user opening the page.
- Maintenance history and audit logs are append-only for ordinary users.

## Confirmed CMMS role model (design decision; not yet provisioned)
- `masoud` → `technical_supervisor`: technical review, assignment/supervision, first-stage approval.
- `biabani` → `responsible_manager`: final-stage approval for ALL CMMS assets and locations in v1, including production, electrical, mechanical and utilities. No separate area-manager approvers in v1.
- `reza` → `technical_expert`: technical review, diagnosis, asset technical data and assigned execution.
- `hamid` → `technician`: corrective and preventive maintenance execution as assigned.
- `mohammadi` and `karami`: no CMMS access by default; procurement remains in the existing purchase module.
- Keep these assignments in `cmms_user_roles`; do not alter or reinterpret legacy `user_profiles.role`.
Authorization must be enforced in PostgreSQL RLS/RPC, not merely by hiding buttons.

## Integration design
- CMMS tables are additive and isolated from existing purchase tables.
- Optional `work_order_purchase_links.purchase_request_id` references `pr_requests.id` as TEXT.
- No modifications to existing purchase request schema or functions.

## Implementation sequence — full delivery checklist
1. Obtain a downloadable external logical backup; separately export Storage object bytes if any exist; restore into an isolated disposable database/project and verify row counts, schema, policies, functions and Auth migration implications.
2. Complete read-only audit of existing RLS, function definitions and EXECUTE grants, Auth/profile mapping, Data API exposure settings, app navigation and current technical-mission behavior.
3. Finalize schema constraints, indexes, lifecycle/state machine, immutable audit history and server-side PM generation. Review SQL independently before staging.
4. Build staging schema and least-privilege role/location RLS policies plus narrow RPCs. Test anonymous, no-role, each role, unauthorized locations, self-approval, approval ordering, rework, concurrency and audit immutability.
5. Build the separate CMMS UI in `feature/cmms-v1`: dashboard, asset register, hierarchical locations, failure intake, triage, work-order board, assignment, action/labor/parts/evidence logs, test/return-to-service, two-stage approvals, PM plans/tasks, history, audit and purchase links.
6. Integrate into the existing app shell/login without replacing existing technical missions or changing purchase module behavior.
7. Add server-side PM task generation and overdue handling; verify duplicate prevention and schedule recovery.
8. Run mobile/responsive, accessibility, validation, file upload/storage, session expiry, concurrency and regression tests for existing login, role views, purchase create/edit/approve/delete/print and technical work orders.
9. Run Supabase security/performance advisors, inspect Data API grants/exposure, verify backup/restore again after staging changes, and produce release notes + rollback plan.
10. Release only after user approval; keep `main` unchanged until explicit release approval. Never merge/deploy automatically.

## Current front-end integration points
The existing app is a single-page HTML/JS application with Supabase JS v2 loaded from jsDelivr. Relevant existing functions include `cloudLogin`, `loadUserProfile`, `switchView`, `renderAll`, `loadWorkOrders`, `newWorkOrder`, `submitWorkOrder`, `updateWork`, and `approveWork`.
The current `work-orders` view is already used for basic technical missions. CMMS should be a separate view/module and should not replace this flow until migration and regression tests are complete.


## Verified existing user-role mapping (read-only audit, 2026-11-17)
- masoud — admin — active
- biabani — admin — active
- reza — tech — active
- hamid — maintenance — active
- mohammadi — planner — active
- karami — procurement — active

Important: the existing `admin` role is broad in the legacy application. The user's explicit governance decision maps only `biabani` to CMMS `responsible_manager` and `masoud` to `technical_supervisor`; do not infer CMMS roles from legacy `admin`. Keep the CMMS role map separate. The remaining `tech` and `maintenance` accounts are mapped explicitly to `technical_expert` and `technician`.

## Security audit correction
Initial caution about `SECURITY DEFINER` exposure was provisional pending evidence. A subsequent live Security Advisor run and catalog inspection did identify anon EXECUTE grants on `admin_update_purchase_request` and the `rls_auto_enable` event-trigger function. Their bodies/trigger attachment were then inspected separately; see sections 10 and 15. Existing purchase and work-order RPCs remain unchanged. Any CMMS RPC must check `auth.uid()`, active `user_profiles` membership, role, location scope, and distinct approval identities server-side.


## 10. Existing-project security findings — 2026-11-17 (read-only)
Supabase Security Advisor was run against the existing production project. It currently reports:
- 2 SECURITY DEFINER functions executable by `anon`: `admin_update_purchase_request(text,jsonb)` and `rls_auto_enable()`.
- 7 SECURITY DEFINER functions executable by `authenticated`, including existing purchase and technical-work-order RPCs.
- Leaked-password protection is disabled.

These findings predate CMMS and are not CMMS changes. Do not modify the purchase RPCs as part of CMMS implementation. Before any production release, separately review each function body, caller checks, actual grants and intended exposure. In particular, `rls_auto_enable()` should not be callable as a public RPC; determine whether it is an event-trigger helper and restrict its EXECUTE grants / exposure through a separately reviewed security change. The purchase RPCs require regression tests before any grant changes. Leaked-password protection should be evaluated as a separate Auth policy decision.

Supabase's current Data API guidance distinguishes grants from RLS: both must be reviewed. New public tables are not automatically exposed by default as of the 2026-10-30 rollout; verify project-level defaults and explicit grants instead of assuming either exposure or isolation.


## 11. Production baseline re-check — 2026-11-17
Read-only verification against project `jpzgtbafrpjjbtwqwzlr`:
- Project status: `ACTIVE_HEALTHY`; PostgreSQL 17.11.
- Existing operational tables: `pr_requests` (46 rows), `user_profiles` (6 rows), `technical_work_orders` (3 rows). RLS is enabled on all three.
- CMMS production state, verified again on 2026-11-17: 15 new CMMS tables, all with RLS; 15 SELECT-only policies; four active global role rows; four audit rows from role seeding; all asset/failure/work-order/PM operational tables remain empty.
- `private_backup.snapshots` contains snapshot `pre_cmms_2026_11_17`, captured at 2026-11-17 18:03:09 UTC. Snapshot sections include public table rows, table definitions, policies, functions, Auth user metadata, Storage bucket metadata and Storage object metadata. It is still an in-project JSON snapshot, not an external restorable backup.
- Supabase migration history currently returns zero tracked migrations. The live schema therefore must be treated as an existing baseline, not assumed to be reproducible from migration files.
- Supabase's current table-security advisory flags `private_backup.snapshots` as a CRITICAL RLS-disabled exposure and warns that anon/authenticated client roles can read or modify rows. Do not assume the schema name `private_backup` is a sufficient security boundary. The table contains an in-project JSON snapshot of operational records and metadata. No automatic remediation was applied; this needs explicit user approval. Suggested remediation from the advisor:
  ```sql
  ALTER TABLE "private_backup"."snapshots" ENABLE ROW LEVEL SECURITY;
  ```
  With RLS enabled and no policies, normal client roles will be blocked. Preserve administrative recovery access and verify grants and table access after the change.
- Performance Advisor findings on existing tables: one unindexed FK on `technical_work_orders.created_by`; four RLS init-plan warnings on existing policies; one unused index on `pr_requests`. These are existing-app tuning items, not reasons to alter purchase behavior during CMMS work. Review separately with regression tests.
- The CMMS base schema draft now defaults new work orders to `triage`, not `approved_for_execution`, to prevent bypassing the assessment gate.
- The hardening draft now requires explicit passed test, return-to-service timestamp, two distinct approvers and approval timestamps before a work order can be closed.

## 12. UI design artifact
- `docs/CMMS-V1-UI-SPEC.md` now defines navigation, required fields, workflow screens, role capabilities, responsive RTL behavior, acceptance tests and release gates.
- A branch-only CMMS UI shell has now been added to `index.html`: a dedicated navigation entry, separate CMMS view, six tabbed areas (overview, assets, failures, work orders, PM, reports), role-aware navigation visibility and an explicit read-only/disabled-action gate. It uses the existing login session and does not query or write any CMMS tables yet.
- The existing print helper contained a pre-existing JavaScript syntax error caused by literal newlines inside a single-quoted HTML string. This was corrected only on `feature/cmms-v1`. All four inline scripts now pass JavaScript syntax compilation via V8 `new Function`; this is syntax validation only, not browser or end-to-end testing.
- The app shell remains a 223 KB single HTML file with layered CSS and legacy navigation logic. The CMMS shell is a scaffold, not a production-ready interactive module. Browser/mobile testing, real data bindings and workflow actions remain outstanding.


## 13. Schema coverage added in the latest draft review
- Locations now support discipline classification (production, electrical, mechanical, utilities, general).
- Assets and failure reports support evidence paths; failure reports capture production, safety and environmental impact.
- Work orders capture work type, scope, root cause, planned/due dates, estimated duration, permit and isolation requirements, test result and explicit return-to-service status.
- PM plans support calendar or meter triggers; PM tasks can be generated from date or meter thresholds with a uniqueness guard for meter-based due points.
- New work orders default to `triage`, not an execution-approved state.
- Closeout hardening requires a passed test, return-to-service timestamp, both approval identities/timestamps and distinct approvers.


## 14. Authorization and role-seed drafts
- `supabase/drafts/20261117_cmms_v1_authorization_draft.sql` adds a dedicated non-API helper schema, role/scope helper functions, location-ancestor access checks, SELECT-only RLS policies for all 15 CMMS tables, and explicit least-privilege table grants. Client-side direct writes are deliberately denied; state changes must go through narrowly scoped RPCs.
- `supabase/drafts/20261117_cmms_v1_role_seed_draft.sql` maps the four confirmed usernames using a query against `user_profiles`: masoud → technical_supervisor; biabani → responsible_manager; reza → technical_expert; hamid → technician. It does not alter legacy roles and leaves mohammadi/karami without CMMS access.
- Role mapping and read-only RLS are drafted. Workflow RPCs are now drafted in `supabase/drafts/20261117_cmms_v1_workflow_rpc_draft.sql`; they have passed a rolled-back SQL/dependency validation transaction but have not been tested in an isolated staging project. No write workflow is enabled in production.


## 15. SECURITY DEFINER function review — read-only detail
The production function definitions and ACLs were inspected, not just the Advisor summary:
- `admin_update_purchase_request(text,jsonb)` is executable by anon and authenticated, but its body checks `auth.uid()` against an active `admin` profile before updating. Anonymous calls should fail this guard; the anon EXECUTE grant is still unnecessary exposure and should be reviewed as a separate, regression-tested security change.
- `rls_auto_enable()` is not an ordinary RPC: it is the function for the enabled `ensure_rls` event trigger on `ddl_command_end`, owned by postgres. The generic Advisor flags its EXECUTE ACL; do not revoke blindly without confirming event-trigger behavior. Its public/anon/authenticated ACL should be tightened in a controlled change while preserving event-trigger operation.
- The other inspected SECURITY DEFINER functions include purchase creation, transition, deletion, admin approval and technical-work-order update/approval. Their bodies include profile/role, ownership, assignment or state checks. They are part of the live purchase/mission workflow and remain unchanged during CMMS work.
- No production security ACLs were changed.

- A dedicated asset-meter-reading table was added so meter-based PM plans have an auditable source for hour/cycle readings; its location-scoped read policy and grants are included in the authorization draft.
- The current project has the `pg_cron` extension available but not installed. Server-side PM generation will use a controlled scheduled database job or Supabase scheduled function only after the extension/scheduling choice is validated in staging; browser timers are not acceptable.


## 16. Workflow, PM and transactional SQL validation — 2026-11-17
- Added `supabase/drafts/20261117_cmms_v1_workflow_rpc_draft.sql` with private, fixed-search-path SECURITY DEFINER implementations and public SECURITY INVOKER entry points for:
  - location and asset creation, asset editing and reason-coded asset-status changes;
  - manual corrective/preventive/inspection/improvement work-order creation;
  - failure reporting and technical triage/conversion/rejection;
  - work-order release, assignment, progress and action logging;
  - test submission and explicit return-to-service decision;
  - two-stage approval (technical supervisor, then responsible manager);
  - PM plan creation/update/activation, task assignment/start/completion and manual meter readings;
  - idempotent, row-locked server-side calendar/meter PM task generation;
  - reason-coded work-order cancellation and reassignment, including automatic closure of active assignments on cancellation/final approval;
  - controlled links from work orders to existing purchase requests.
- Added a `trigger_type` to PM tasks and separate source-of-truth meter readings. V1 supports calendar OR meter-based PM. Hybrid scheduling is deferred because one shared interval cannot safely represent independent date and meter frequencies.
- The PM generator is currently revoked from all client/service roles as part of the production write-lock; it is not scheduled. `pg_cron` is available but not installed in this project. The schedule mechanism remains a release decision for staging.
- The earlier public SECURITY DEFINER RPC draft and duplicate PM scheduler draft were removed. Location and asset master-data operations are now exposed through narrowly scoped public SECURITY INVOKER wrappers; master-data permissions are checked in the private implementation. The current workflow draft uses private implementations and public SECURITY INVOKER wrappers; no broad client UPDATE/DELETE grants are included.
- Added `docs/CMMS-V1-RELEASE-CHECKLIST.md` and `supabase/tests/cmms_v1_acceptance.sql` covering backup/restore, schema, identity, RLS/API security, corrective workflow, PM scheduling, attachments, audit/reporting, regression and rollback. The acceptance suite is authored but has not been run in isolated staging. Do not use the connected SQL execution action for rollback-only tests: production DDL and role-seed statements persisted despite an explicit rollback wrapper.
- The earlier SQL batch was incorrectly treated as a rollback-only validation. A later direct catalog inspection proved that schema, policies, triggers, functions and role-seed statements persisted in production despite the explicit rollback wrapper. The precise transaction boundary cannot be reconstructed from the tool history; the live catalog is authoritative.
- Production currently contains 15 CMMS tables, 15 SELECT-only RLS policies, 58 CMMS-named functions and 24 triggers. Four global role rows and four corresponding audit events are present. Operational CMMS tables remain empty.
- The current effective privileges are fail-closed: all 15 tables have RLS; authenticated users have SELECT but no INSERT/UPDATE/DELETE; anon has no SELECT; no public CMMS RPC is executable by anon or authenticated; only two private read-only authorization helpers are executable by authenticated. No private CMMS function is executable by service_role.
- Existing purchase baseline remains unchanged: 46 `pr_requests`, 6 `user_profiles`, 3 `technical_work_orders`. Supabase migration-list still returns no migration history.
- The production schema is not guaranteed to match the latest branch drafts. The live schema must be reconciled against the GitHub drafts before any further deployment or permission changes.
- All four inline scripts in the development-branch app pass JavaScript syntax compilation. This is not browser, mobile, RLS, security, workflow or end-to-end testing.
- After the rollback validation, additional asset/location CRUD, PM-plan management, asset-status, cancellation/reassignment and Storage policy drafts were added. The latest RPC/Storage changes have passed static structural checks (balanced SQL dollar quotes, no duplicate function names, all app inline scripts compile) but have not been rerun through PostgreSQL or isolated staging. They remain unvalidated release inputs.
- The feature branch comparison currently reports 169 commits ahead of `main`, 0 behind, with 15 changed files; `main` remains untouched. Function/DOM-ID comparison of `index.html` found no pre-existing app functions or IDs removed; four CMMS functions and three CMMS IDs were added. The feature branch includes the CMMS UI shell in `index.html`, but it is not deployed from `main`.
- Remaining release blockers: external restorable backup and restore test; isolated staging execution; full RLS/RPC negative and positive tests; actual scheduled PM job; cancellation/reassignment and controlled purchase-link RPCs; private Storage policies; UI data binding and browser/iPhone tests; purchase-module regression.


## 17. Backup inventory and remaining recovery gap
Current read-only production inventory:
- `public.pr_requests`: 46 rows.
- `public.user_profiles`: 6 rows.
- `public.technical_work_orders`: 3 rows.
- `auth.users`: 6 users.
- `storage.buckets` and `storage.objects`: both currently 0.
- CMMS: 15 tables with RLS enabled; 15 SELECT-only policies; 58 CMMS functions; 24 triggers; four global role rows; four role-seed audit rows; all operational CMMS tables remain empty. All public CMMS RPC wrappers are non-executable by anon/authenticated; authenticated direct INSERT/UPDATE/DELETE on CMMS tables is absent. Only two private read-only authorization helpers are executable by authenticated.
- No Supabase migration history was returned by the Supabase migration-list tool.

The existing `private_backup.snapshots` record is still an in-project snapshot. It is not an external restorable backup. Supabase's current backup documentation says Free projects should regularly export data using the Supabase CLI; database backups also do not include Storage object bytes. Current Storage inventory is zero, but Auth and application data still need an external backup and isolated restore test. The connected Supabase actions do not expose a downloadable `db dump` operation in this session. No backup export has been fabricated or claimed complete.


## 19. Evidence storage policy draft
- Added `supabase/drafts/20261117_cmms_v1_storage_policy_draft.sql` for a private `cmms-evidence` bucket with file-size/MIME restrictions, asset-location scoped read access, record-linked upload checks and no update/delete policy.
- Object paths are constrained to `cmms/{asset_uuid}/{record_type}/{record_uuid}/{filename}`; reads require a real linked asset/failure/work-order/PM record and the caller's CMMS location role.
- This is a draft only. Bucket creation and Storage policies have not been applied or tested. Signed URLs and upload/download flows must be verified in staging.


## 18. Verified production state and safety lockdown — 2026-11-17
A fresh read-only catalog inspection shows the following CMMS objects are currently present in the production Supabase project:
- 15 CMMS tables, all 15 with RLS enabled; live column-name comparison matches all 15 tables in the current base schema draft.
- 15 CMMS row policies; all are SELECT policies. No INSERT/UPDATE/DELETE policies exist.
- 58 CMMS-named functions across `public` and `cmms_private`, and 24 CMMS triggers. Live-vs-branch comparison found exact function-name and trigger-name matches; only the `cmms_report_failure` signature differs (live 8 arguments, branch draft 9 with optional `downtime_started_at`).
- Active global role assignments: masoud = technical_supervisor; biabani = responsible_manager; reza = technical_expert; hamid = technician.
- Four audit rows record those four role-seed inserts, with system actor `NULL`.
- No locations, assets, failure reports, work orders, assignments, actions, approvals, PM plans/tasks, meter readings or purchase links have been created; those operational tables are empty.
- No `cmms-evidence` Storage bucket exists.
- Existing purchase baseline remains `pr_requests` 46 rows, `user_profiles` 6 rows and `technical_work_orders` 3 rows.

Current verified safety posture (read-only privilege audit):
- No `public.cmms_*` function is executable by `anon` or `authenticated`.
- Only `cmms_private.cmms_has_any_role` and `cmms_private.cmms_has_role_at_location` are executable by `authenticated`; workflow functions and PM scheduler are not executable by client or service roles.
- Direct authenticated table INSERT/UPDATE/DELETE privileges are absent; authenticated SELECT is filtered by RLS.
- RLS read access remains available for the four mapped roles, but no operational rows exist. The CMMS UI is not in `main`; no live workflow is enabled.
- The production schema should be treated as **installed but write-locked**, not as an uninstalled draft. Do not drop these tables or attempt a rollback cleanup without a verified external backup and a reviewed recovery plan.
- The precise originating deployment action cannot be established from the current tool history. The prior assumption that the rollback validation had left no persistent objects was wrong; the live catalog is the source of truth.
- Performance Advisor flags 23 unindexed CMMS foreign keys; `supabase/drafts/20261117_cmms_v1_fk_indexes_draft.sql` adds a separate 23-index proposal for staging/query-plan review. The live schema currently has 17 explicit CMMS indexes matching the branch drafts.
- Security advisor reports pre-existing legacy SECURITY DEFINER exposures: 2 functions callable by anon and 7 by authenticated; leaked-password protection is disabled. No CMMS-specific security lint was returned. Performance advisor reports 24 unindexed foreign keys (23 CMMS), four legacy RLS initplan warnings and 10 unused indexes (mostly CMMS indexes with no operational data). Do not alter legacy purchase RPCs within this CMMS task.
- Release remains blocked on an external restorable backup/restore test, live-vs-draft schema reconciliation, isolated staging validation, re-enabling only approved RPCs after tests, index review, Storage policy deployment, PM scheduling and UI integration.


## 20. Reporting layer draft
- Added `supabase/drafts/20261117_cmms_v1_reporting_draft.sql` with SECURITY INVOKER views for dashboard counts, per-asset work/failure/PM KPIs, a unified asset timeline, and PM completion compliance.
- Downtime metrics derive only from recorded `downtime_started_at` and `returned_to_service_at`; no MTBF/MTTR estimate is shown where source data is insufficient.
- The latest branch draft extends failure intake with an optional downtime start timestamp and carries it into the resulting work order. The live production RPC currently has the earlier eight-argument signature; reconcile the live function and branch draft before release.
- Reporting views are not applied or tested. Verify the PostgreSQL 17 view options, RLS behavior, Data API grants and aggregate accuracy in staging.
