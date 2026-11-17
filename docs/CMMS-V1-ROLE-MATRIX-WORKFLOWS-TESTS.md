# CMMS v1 — Role Matrix, Workflow & Acceptance Tests

Status: design specification only. No production database changes have been made.

## 1. Confirmed operating boundary
- The module belongs to the Technical Department.
- It covers production, electrical, mechanical and utility assets.
- Both corrective/emergency maintenance and preventive maintenance are in scope.
- A work order cannot be closed until it has passed technical-supervisor approval and responsible-manager approval.
- Existing purchase requests remain the procurement path; CMMS may link a work order to a purchase request.
- The existing purchase workflow and its RPC functions must not be changed by CMMS v1.

## 2. Proposed CMMS role mapping

The current application has six active profiles. The CMMS uses a separate role mapping table so existing application roles are not reinterpreted globally.

| Existing profile | Existing role | Proposed CMMS role | Scope / note |
|---|---|---|---|
| masoud | admin | technical_supervisor | Technical work review and first closeout approval |
| biabani | admin | responsible_manager | Final closeout approval for ALL assets and locations in v1 |
| reza | tech | technical_expert | Technical review, diagnosis and work execution as assigned |
| hamid | maintenance | technician | Repair and preventive-maintenance execution as assigned |
| mohammadi | planner | none by default | No CMMS access unless explicitly requested |
| karami | procurement | none by default | Procurement continues through existing purchase module |

All six remain unchanged in `user_profiles`. These are proposed rows for `cmms_user_roles`, not applied permissions. The user confirmed on 2026-11-17 that `biabani` approves all CMMS equipment and locations in v1; no separate area-manager approval roles are required. Users may receive more than one CMMS role only where explicitly justified. A person must not approve both stages of the same work order.

### Authorization principles
- Every CMMS operation requires an authenticated user and an active CMMS role.
- Role membership is checked server-side from `cmms_user_roles`; hiding buttons in the browser is not authorization.
- Location scope is enforced server-side for locations assigned to the user.
- Only the technical supervisor role can perform the first approval.
- Only the responsible-manager role can perform the second approval.
- The second approver must be a different person from the first approver.
- Work-order creators and assignees cannot approve their own work order unless a separately approved governance exception is introduced.
- All status changes and approvals are recorded in an immutable audit trail.

## 3. Corrective-maintenance workflow

1. Report failure: select asset, describe symptoms, set priority and record downtime start when production/equipment is stopped.
2. Technical review: validate the report, set operational impact and convert it to a work order or reject it with a reason.
3. Assign: assign one or more technicians and a target date.
4. Execute: record diagnosis, repair actions, labor duration, parts/materials and evidence.
5. Test: record test method and result. Failed tests return the order to rework; they do not proceed to approval.
6. Return to service: record actual restoration time and asset status.
7. Technical-supervisor approval: approve or return for rework with a mandatory reason when rejected.
8. Responsible-manager approval: approve or return for rework. Must be a different authenticated user from the technical supervisor.
9. Close: only after both approvals and a successful test. Closing writes the final audit event and updates asset history.

Suggested priority definitions:
- Critical: immediate safety/environmental risk or major production shutdown.
- High: significant production impact or imminent failure.
- Normal: degraded operation without immediate major interruption.
- Low: minor defect with no immediate operational impact.

Priority labels must be calibrated against the plant's actual escalation and response-time policy before go-live.

## 4. Preventive-maintenance workflow
- Each plan belongs to one asset and defines either a calendar interval or a meter interval, checklist, owner and next due threshold.
- Hybrid calendar+meter plans are deferred from v1 until separate frequency units and cycle semantics are implemented.
- Due tasks are generated from the plan; a task must not be silently skipped when overdue. V1 generator and RPCs are drafted, but scheduling and staging tests remain release gates.
- Completion requires checklist results, actual completion time and executor identity.
- Failed checklist items must create or link to a corrective work order; the dedicated PM-failure conversion RPC is still outstanding.
- Plan edits preserve prior task history; plan creation/activation and task assignment/start/completion use controlled RPC drafts.
- Do not use browser timers as the scheduler; due-task generation must run server-side.

## 5. Data and integrity rules to enforce before migration
- Unique asset code; asset cannot be deleted if referenced by maintenance history.
- Location hierarchy must reject self-parenting and ancestor cycles.
- One active assignment per user/work order pair; assignment history is retained.
- Work-order approval stages are recorded separately and retained across rework cycles.
- Supervisor and manager approvers must be different users.
- A work order cannot close without a successful test and both approvals.
- A failure report can be converted to at most one active originating work order unless explicitly reopened.
- PM task completion requires executor, completion timestamp and checklist result.
- Asset status changes are written to status history in the same transaction.
- Audit records are written server-side; clients cannot update or delete them.
- Foreign keys use restrictive deletion where history must be retained.
- All CMMS tables remain inaccessible to anon/authenticated until RLS policies and grants have been reviewed and tested.

## 6. Minimum acceptance tests
1. Anonymous user cannot read or write any CMMS table or RPC.
2. Authenticated user without a CMMS role cannot read or write CMMS data.
3. Reporter can submit a failure report only within permitted location scope.
4. Technician can update only work orders assigned to them or their authorized team.
5. Technician cannot approve or close a work order.
6. Technical supervisor can approve stage one but cannot approve stage two for the same work order.
7. Responsible manager can approve stage two only after stage one and only as a different person.
8. Failed test or missing return-to-service timestamp blocks closeout.
9. A rejected approval returns the order to rework and preserves the previous decision.
10. PM due task cannot be marked complete without checklist result and executor.
11. Purchase link references a real `pr_requests.id` and does not alter the purchase request.
12. Existing login, role views, purchase create/edit/approve/delete, print and technical work-order flows still pass regression tests.

## 7. Release gates
- External database backup created and integrity-checked.
- Restore test completed in an isolated database/project.
- Role mapping and responsible-manager scope confirmed.
- RLS policies and RPC authorization tests pass.
- Existing application regression tests pass.
- Only then may the additive migration be applied and a release candidate deployed.

## 8. Confirmed governance decision
Decision confirmed by the user (2026-11-17): biabani is the responsible-manager approver for all equipment and locations in CMMS v1, including production, electrical, mechanical and utilities. Do not create separate area-manager approval roles in v1. Keep the role mapping separate from the legacy `user_profiles.role` field. The proposed mapping remains masoud = `technical_supervisor` and biabani = `responsible_manager`; it is a design decision, not yet provisioned in production.

## 9. Implementation artifacts and known gates
- `supabase/drafts/20261117_cmms_v1_draft.sql`: additive base schema, not applied.
- `supabase/drafts/20261117_cmms_v1_hardening_draft.sql`: hardening layer for NULL-safe role uniqueness, active assignment uniqueness, location cycle guard, PM completion integrity, approval ordering/identity, append-only approval/audit records and asset status history. Not applied; requires staging tests and review.
- External restorable backup remains the mandatory release gate. The in-project snapshot is not a disaster-recovery backup.
- Data API exposure must be explicitly reviewed: Supabase changed defaults so newly created public tables are not automatically exposed; never infer API accessibility from table existence.


## 7. Cancellation, reassignment and purchase references
- Work-order cancellation is restricted to technical supervisor/expert and requires a reason.
- Reassignment is performed as one controlled operation: create the new assignment, close the prior assignment with timestamp and mandatory reason, and preserve both records.
- A work order may link to an existing purchase request by its existing PR ID; the CMMS must not alter the purchase-request workflow.
- These RPCs are drafted only and must pass role, audit, concurrency and purchase-regression tests before release.


## 10. Additional negative and edge-case tests
- NULL decision, stage, priority, test result or return-to-service status must fail closed; SQL CHECK semantics must not allow NULL to pass a closeout condition.
- A disabled/inactive legacy `user_profiles` account cannot access CMMS even if a stale `cmms_user_roles.is_active` row remains.
- A technician/technical expert with an inactive legacy profile cannot be assigned to a new work order or PM task.
- A work order cannot be cancelled by a technician or responsible manager; cancellation requires technical governance role and a non-empty reason, and active assignments are closed with history.
- Asset status changes require a reason, and that exact reason is preserved in asset status history.
- A manager cannot approve before the latest supervisor approval; the two approval identities must differ; prior rejection history remains immutable.
- A closed work order must have passed test, explicit return-to-service decision, both current approval timestamps and distinct approvers.
- Evidence upload rejects invalid UUID path segments, nonexistent linked records, unauthorized asset locations, unsupported MIME types and oversized files; object update/delete is denied.
- PM task generation must be idempotent under repeated and concurrent scheduler runs; meter-based due thresholds must not create duplicate tasks.
