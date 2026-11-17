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

Important: the existing `admin` role currently represents a broad application administrator/technical approval role in existing purchase workflows. Do not automatically map every existing admin to the CMMS responsible-manager role. Confirm the real manager approval authority and map it explicitly. Likewise, `tech` and `maintenance` should not automatically be treated as identical CMMS roles without confirming who can report failures, maintain asset data, and execute repairs.

## Security audit correction
The earlier generic concern about a `SECURITY DEFINER` routine being executable by anonymous users must not be treated as a confirmed finding. The current function definitions show authorization checks in the purchase and work-order routines. Before any changes, inspect actual EXECUTE grants and function exposure. Preserve existing purchase RPC behavior. Any CMMS RPC must check `auth.uid()`, active `user_profiles` membership, role, location scope, and distinct approval identities server-side.


## 10. Existing-project security findings — 2026-11-17 (read-only)
Supabase Security Advisor was run against the existing production project. It currently reports:
- 2 SECURITY DEFINER functions executable by `anon`: `admin_update_purchase_request(text,jsonb)` and `rls_auto_enable()`.
- 7 SECURITY DEFINER functions executable by `authenticated`, including existing purchase and technical-work-order RPCs.
- Leaked-password protection is disabled.

These findings predate CMMS and are not CMMS changes. Do not modify the purchase RPCs as part of CMMS implementation. Before any production release, separately review each function body, caller checks, actual grants and intended exposure. In particular, `rls_auto_enable()` should not be callable as a public RPC; determine whether it is an event-trigger helper and restrict its EXECUTE grants / exposure through a separately reviewed security change. The purchase RPCs require regression tests before any grant changes. Leaked-password protection should be evaluated as a separate Auth policy decision.

Supabase's current Data API guidance distinguishes grants from RLS: both must be reviewed. New public tables are not automatically exposed by default as of the 2026-10-30 rollout; verify project-level defaults and explicit grants instead of assuming either exposure or isolation.
