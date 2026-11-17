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

## Initial role model (to be mapped against real people before activation)
- Reporter: submit failure reports and see permitted status.
- Technician: see and execute assigned work orders.
- Technical expert: maintain asset technical data and propose assignments.
- Technical Supervisor: triage, assign, supervise, approve first stage.
- Responsible Manager: approve final closeout for their location.
Authorization must be enforced in PostgreSQL RLS/RPC, not merely by hiding buttons.

## Integration design
- CMMS tables are additive and isolated from existing purchase tables.
- Optional `work_order_purchase_links.purchase_request_id` references `pr_requests.id` as TEXT.
- No modifications to existing purchase request schema or functions.

## Implementation sequence
1. Obtain external logical backup using Supabase CLI/pg_dump; separately export Storage if buckets are later added; verify a restore into a disposable project.
2. Review existing RLS, SECURITY DEFINER functions, Auth/profile mapping, and current front-end navigation.
3. Create CMMS tables in a staging database; add explicit role/location policies.
4. Build asset registry and failure intake UI.
5. Add corrective work orders and two-stage approvals.
6. Add PM scheduler and task execution.
7. Link work orders to purchase requests.
8. Test role matrix, mobile flows, concurrency, auditability, and purchase module regression.
9. Release only after approval; never merge this branch to main automatically.

## Current front-end integration points
The existing app is a single-page HTML/JS application with Supabase JS v2 loaded from jsDelivr. Relevant existing functions include `cloudLogin`, `loadUserProfile`, `switchView`, `renderAll`, `loadWorkOrders`, `newWorkOrder`, `submitWorkOrder`, `updateWork`, and `approveWork`.
The current `work-orders` view is already used for basic technical missions. CMMS should be a separate view/module and should not replace this flow until migration and regression tests are complete.
