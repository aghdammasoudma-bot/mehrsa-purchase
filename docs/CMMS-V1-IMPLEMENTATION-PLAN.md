# CMMS v1 — Technical Department Implementation Plan

Status: design baseline only; not deployed.

## Guardrails
- Keep production branch `main` unchanged.
- Build only on `feature/cmms-v1`.
- Existing purchase requests remain in `public.pr_requests`; the current UI and RPC workflow must remain backward compatible.
- Do not apply the draft migration until an independently restorable off-site database backup has been produced and tested.
- All CMMS tables start with RLS enabled and no permissive policies. Access is deny-by-default until role mapping and policies are reviewed.
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
Important limitation: this is an in-project logical snapshot, not an off-site disaster-recovery backup. It does not contain password hashes, active sessions, project settings, API keys, or actual Storage object bytes. No database migration may be applied until a downloadable external backup is available and restore-tested.

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
- Current public tables: `pr_requests` (46 rows), `user_profiles` (6 rows), `technical_work_orders` (3 rows). RLS is enabled on all three.
- `private_backup.snapshots` contains snapshot `pre_cmms_2026_11_17`, captured at 2026-11-17 18:03:09 UTC. Snapshot sections include public table rows, table definitions, policies, functions, Auth user metadata, Storage bucket metadata and Storage object metadata. It is still an in-project JSON snapshot, not an external restorable backup.
- Supabase migration history currently returns zero tracked migrations. The live schema therefore must be treated as an existing baseline, not assumed to be reproducible from migration files.
- Supabase Security Advisor flags `private_backup.snapshots` because RLS is disabled. Catalog checks show the `private_backup` schema has no USAGE grant for `anon` or `authenticated`, and neither role has SELECT on the snapshot table; the table ACL currently lists only `postgres`. This reduces current Data API reachability, but the RLS warning remains a hardening item. Do not change it without explicit user decision. Suggested remediation from the advisor:
  ```sql
  ALTER TABLE "private_backup"."snapshots" ENABLE ROW LEVEL SECURITY;
  ```
  With RLS enabled and no policies, normal client roles remain blocked; preserve postgres/service administrative access and verify catalog grants after any change.
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
  - failure reporting and technical triage/conversion/rejection;
  - work-order release, assignment, progress and action logging;
  - test submission and explicit return-to-service decision;
  - two-stage approval (technical supervisor, then responsible manager);
  - PM plan creation/activation, task assignment/start/completion and manual meter readings;
  - idempotent, row-locked server-side calendar/meter PM task generation;
  - reason-coded work-order cancellation and reassignment;
  - controlled links from work orders to existing purchase requests.
- Added a `trigger_type` to PM tasks and separate source-of-truth meter readings. V1 supports calendar OR meter-based PM. Hybrid scheduling is deferred because one shared interval cannot safely represent independent date and meter frequencies.
- The PM generator is restricted to `service_role`; it is not scheduled. `pg_cron` is available but not installed in this project. The schedule mechanism remains a release decision for staging.
- The earlier public SECURITY DEFINER RPC draft and duplicate PM scheduler draft were removed. The current workflow draft uses private implementations and public SECURITY INVOKER wrappers; no broad client UPDATE/DELETE grants are included.
- Added `docs/CMMS-V1-RELEASE-CHECKLIST.md` covering backup/restore, schema, identity, RLS/API security, corrective workflow, PM scheduling, attachments, audit/reporting, regression and rollback.
- Ran the complete current base schema + hardening + authorization + role-seed + workflow-RPC SQL as one explicit PostgreSQL transaction against the production database, then rolled it back. PostgreSQL accepted the complete DDL, functions, triggers, policies, grants and role-seed verification query. The returned mapping was exactly:
  - masoud → technical_supervisor
  - biabani → responsible_manager
  - reza → technical_expert
  - hamid → technician
- A subsequent read-only catalog check confirmed zero `cmms_*` relations and zero `cmms_private` schema remaining; the pre-existing `private_backup.snapshots` table remained present. This was syntax/dependency validation only; no CMMS tables, roles, policies, functions or grants remain in production.
- All four inline scripts in the development-branch app pass JavaScript syntax compilation. This is not browser, mobile, RLS, security, workflow or end-to-end testing.
- No CMMS production migration or deployment has occurred. `main` remains untouched.
- Remaining release blockers: external restorable backup and restore test; isolated staging execution; full RLS/RPC negative and positive tests; actual scheduled PM job; cancellation/reassignment and controlled purchase-link RPCs; private Storage policies; UI data binding and browser/iPhone tests; purchase-module regression.


## 17. Backup inventory and remaining recovery gap
Read-only production inventory after the rollback validation:
- `public.pr_requests`: 46 rows.
- `public.user_profiles`: 6 rows.
- `public.technical_work_orders`: 3 rows.
- `auth.users`: 6 users.
- `storage.buckets` and `storage.objects`: both currently 0.
- Public base tables: 3. No CMMS relations remain in production.
- No Supabase migration history was returned by the Supabase migration-list tool.

The existing `private_backup.snapshots` record is still an in-project snapshot. It is not an external restorable backup. Supabase's current backup documentation says Free projects should regularly export data using the Supabase CLI; database backups also do not include Storage object bytes. Current Storage inventory is zero, but Auth and application data still need an external backup and isolated restore test. The connected Supabase actions do not expose a downloadable `db dump` operation in this session. No backup export has been fabricated or claimed complete.
