# CMMS V1 — UI and interaction specification
Status: design scaffold only. No live CMMS table exists yet; no CMMS writes are enabled.

## Product boundary
- CMMS is a distinct module inside the existing Mehrsa technical operations app, using the existing Supabase Auth session.
- Purchase requests and the current technical-mission module remain intact.
- CMMS is limited to the technical department in V1.
- Authorized accounts: masoud (technical supervisor), biabani (responsible manager), reza (technical expert), hamid (technician). mohammadi and karami have no CMMS access by default.
- Access must be enforced by database RLS/RPC, not by navigation visibility alone.

## Navigation
1. CMMS overview
2. Asset register
3. Failure reports
4. Work orders
5. Preventive maintenance
6. Equipment history
7. Reports and audit trail

## Screens and required fields

### Overview
- Counts: open failures, active work orders, waiting approvals, overdue PM tasks, equipment out of service.
- Filters by location, discipline, severity and date.
- All metrics must be computed from database rows; no demo counts in production.

### Asset register
- Unique asset code; asset name; category; discipline; parent location; exact location; manufacturer; model; serial number; criticality; operational status; commissioning date; technical specifications; attachments; notes.
- Create/edit and lifecycle status changes are server-controlled; every status change requires a reason and creates immutable history.
- Asset detail tabs: identity, work-order history, failure history, PM plan, status history, documents.
- Lifecycle statuses include in-service, limited, out-of-service, decommissioned.

### Failure intake
- Reporter, timestamp, location, asset, symptom, severity, production impact, safety/environmental impact, photos/documents.
- Duplicate/open-failure check before creating another report for the same asset and unresolved symptom.
- Emergency path must flag critical failures and notify responsible roles; notifications are not considered delivered until provider integration is verified.

### Triage and work order
- Failure assessment, root-cause hypothesis, priority, work type, scope, assigned technician(s), planned start/due time, isolation/permit requirements, required skills, estimated labor, required materials, related purchase request.
- Work order timeline: created, triaged, assigned, accepted, in progress, waiting parts, waiting shutdown, completed pending test, tested, pending technical approval, pending manager approval, closed / rejected for rework / cancelled.
- Log labor, actions, parts, readings, photos, attachments, downtime, and handover.
- Rework creates a new decision/history event; never overwrite prior approvals.

### Closeout and approvals
- Technician records action, parts, labor, test result, return-to-service status and evidence.
- Technical supervisor (masoud) is first-stage approver.
- Responsible manager (biabani) is final-stage approver for every asset/location in V1.
- Approvers must be different people and cannot approve their own work or a work order they executed.
- Rejection requires a reason and returns the work order to a controlled rework state.
- Closure is blocked unless test is passed, return-to-service decision is explicit, both approvals are current and all required fields/evidence are present.

### Preventive maintenance
- PM plan by asset, frequency (calendar-based or meter-based in v1), checklist template, responsible role, next due date, estimated duration and required materials.
- Hybrid calendar+meter scheduling is deferred; do not combine different frequency units in one interval field.
- Server-side task generation with duplicate protection and missed-run recovery.
- PM task completion requires executor, completion timestamp, checklist result and exceptions.
- Overdue/escalation rules must be visible and auditable.

### Equipment history and reporting
- Full asset timeline; repeated failures; downtime; MTTR; MTBF only when data quality supports it; labor and parts consumption; PM compliance; open/overdue work.
- Date/location/discipline/asset filters; export/print with clear generation timestamp.
- Do not show fabricated KPIs when source data is incomplete.

## Role capabilities
- Technical supervisor: all technical assets; triage; assignment oversight; approve stage 1; view full technical dashboard and audit.
- Responsible manager: all assets/locations; final approval stage; view full dashboard and audit; no self-approval.
- Technical expert: create/update technical asset data as authorized; triage/diagnose; create/assign work orders only if policy allows; view assigned/department work.
- Technician: view assigned tasks; update execution logs; upload evidence; complete checklist/test data; no approval.
- Planner/procurement: no CMMS access by default; purchase links remain references into existing purchase workflow.

## UX and device requirements
- Persian RTL, responsive desktop/iPhone layout, compact readable tables, searchable lists, filters, clear statuses, empty/error/loading states.
- Confirm destructive actions; prevent double submission; preserve unsaved form data on recoverable errors.
- File upload validation and access control; no public bucket by default.
- Keyboard accessibility and explicit focus states.
- Printable work order and asset history.

## Acceptance tests
- Role matrix: anonymous, no CMMS role, each of the four CMMS roles, planner, procurement.
- Cross-location access denied where role scope does not allow it.
- Direct REST/RPC attempts cannot bypass UI permissions.
- Creator/assignee self-approval denied.
- Manager approval denied until latest supervisor decision is approved.
- Rejection reason mandatory; reapproval preserves full history.
- Work-order closeout denied without passed test, explicit return-to-service, and both approvals.
- PM task generation is idempotent and catches up after missed runs.
- Concurrent updates do not double-assign or double-close.
- Attachments cannot be read by unauthorized users.
- Existing purchase create/edit/approve/delete/print and technical-mission flows pass regression tests.

## Release gates
- External restorable backup verified.
- Staging migration and role policies reviewed and tested.
- Data API grants and exposed schemas verified.
- Security/performance advisors reviewed.
- Existing app regression tests pass.
- Rollback instructions and release notes prepared.
- Explicit release approval received.
