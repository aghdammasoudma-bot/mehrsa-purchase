# CMMS V1 — Release & Acceptance Checklist

Status: production schema is installed but write-locked. Verified: 15 CMMS tables with RLS, 15 SELECT-only policies, four active global role rows, four audit rows, and zero operational CMMS records. Public CMMS RPC wrappers are non-executable by anon/authenticated/service_role; direct authenticated table writes are denied. No CMMS Storage bucket or reporting views are installed. Do not rerun the base schema or enable RPCs until an external restorable backup and staging/security tests are complete. All boxes below are release gates, not claims of completion.

## A. Backup and recovery
- [ ] Export a complete database backup outside the production Supabase project.
- [ ] Include schema, data, sequences, indexes, constraints, functions, triggers, RLS policies and grants.
- [ ] Preserve Auth users in a supported secure backup process; do not export password hashes or secrets into GitHub.
- [ ] Back up Storage object bytes and metadata if any are present.
- [ ] Verify checksums and backup size.
- [ ] Restore into a separate isolated PostgreSQL/Supabase project.
- [ ] Compare table counts, critical row counts, function/policy counts and application login.
- [ ] Record restore duration and recovery-point timestamp.
- [ ] Keep the in-project `private_backup.snapshots` snapshot as a supplemental snapshot only, never as the sole disaster-recovery copy.
- [ ] Resolve the CRITICAL RLS-disabled exposure on `private_backup.snapshots`. Supabase's current security advisory warns anon/authenticated roles may read or modify it. Proposed SQL (not executed):
  ```sql
  ALTER TABLE "private_backup"."snapshots" ENABLE ROW LEVEL SECURITY;
  ```
  Decide whether any explicit administrative policy is required; with no policies, client roles are blocked.

## B. Schema and migration
- [ ] Review base schema and hardening SQL with a second technical reviewer.
- [x] An earlier cut of the base schema, hardening, authorization, role-seed and workflow RPC SQL passed a single explicit PostgreSQL transaction that was rolled back; a subsequent catalog check found no CMMS relations or `cmms_private` schema remaining.
- [ ] Revalidate the latest workflow RPC additions (asset/location CRUD, cancellation guard and latest approval logic) and the new Storage policy draft in isolated staging; they were added after the rollback syntax test.
- [ ] Re-run the same scripts on an isolated staging project and commit a versioned migration.
- [ ] Verify foreign keys, unique indexes, identity sequences and delete restrictions.
- [ ] Verify location hierarchy cycle guard under insert, update and concurrent update.
- [ ] Verify duplicate active work-order-per-failure protection.
- [ ] Verify meter-based PM uniqueness and separate calendar-versus-meter task semantics.
- [ ] Verify work-order status transition graph, rework cycles and closure checks.
- [ ] Verify append-only action, approval, asset-status and audit history.

## C. Identity and roles
- [x] Confirmed v1 mapping: masoud = technical_supervisor; biabani = responsible_manager; reza = technical_expert; hamid = technician.
- [x] Confirmed biabani is final approver for all production, electrical, mechanical and utility equipment.
- [x] Keep legacy `user_profiles.role` values unchanged.
- [ ] Seed CMMS roles only after staging schema exists; verify exactly four active mappings.
- [ ] Verify mohammadi (planner) and karami (procurement) have no CMMS access.
- [ ] Verify role revocation takes effect on the next request and cannot be overridden by client metadata.

## D. RLS, API and function security
- [ ] Keep `cmms_private` outside the exposed Data API schemas.
- [ ] Explicitly grant only required authenticated table reads; no anon access.
- [ ] Test anonymous, authenticated-without-role, planner, procurement and each CMMS role.
- [ ] Test location-scoped roles and ancestor/descendant access boundaries.
- [ ] Test direct REST table writes are denied.
- [ ] Test only approved public SECURITY INVOKER RPC wrappers are callable by authenticated users.
- [ ] Test private SECURITY DEFINER implementations are not exposed as RPC endpoints.
- [ ] Test fixed search_path and explicit auth.uid checks on every privileged function.
- [ ] Run Supabase Security Advisor after staging migration; resolve all CMMS-specific findings.
- [ ] Do not change legacy purchase SECURITY DEFINER ACLs in the same release; handle their Advisor findings as a separate regression-tested security change.

## E. Corrective maintenance workflow
- [ ] Failure report creation validates asset access, reporter identity, severity and evidence.
- [ ] Technical triage accepts/rejects with reviewer identity and mandatory rejection reason.
- [ ] Conversion creates at most one active work order for a failure report.
- [ ] Technical release and assignment validate active roles and assignment history.
- [ ] Assigned workers can log diagnosis, repair, parts, labor, readings and evidence.
- [ ] Only assigned workers or authorized technical roles can update execution progress.
- [ ] Test submission requires a recorded test result and explicit return-to-service decision.
- [ ] Supervisor approval requires passed test and current work-order state.
- [ ] Manager approval requires current supervisor approval and a different person.
- [ ] Rejection returns the order to rework without deleting prior decisions.
- [ ] Closeout requires passed test, return-to-service decision and both current approvals.
- [ ] Creator and every assigned worker are blocked from approving the same order.
- [ ] Cancellation and reassignment RPCs require a reason and preserve history.

## F. Preventive maintenance
- [ ] Calendar-based and meter-based plans have separate, unambiguous units and next-due logic; hybrid plans are explicitly deferred from v1.
- [ ] Apply and test `supabase/drafts/20261117_cmms_v1_scheduler_draft.sql` in staging; verify one named pg_cron job, correct owner, successful runs, idempotency and missed-run recovery.
- [ ] Scheduled generation is server-side, idempotent and recovers missed runs.
- [ ] Confirm whether `pg_cron` or Supabase scheduled Edge Functions will be used; `pg_cron` is available but not currently installed in production.
- [ ] Meter readings have source, unit, timestamp and recorder identity.
- [ ] PM task completion requires assigned executor, timestamp and non-empty checklist.
- [ ] Failed checklist items can create/link a corrective work order.
- [ ] Overdue/escalation notifications are designed and verified end-to-end; the PM scheduler draft does not send notifications.

## G. Attachments, audit and reporting
- [ ] Create a private Storage bucket and policies; no public object URLs. Draft: `supabase/drafts/20261117_cmms_v1_storage_policy_draft.sql` (not applied).
- [ ] Validate file type, size, path ownership and asset/work-order association.
- [ ] Confirm unauthorized users cannot download evidence.
- [ ] Audit all create/update/approval/status/assignment/PM/purchase-link actions.
- [ ] Confirm clients cannot update/delete audit, action, approval or status history.
- [ ] Reports include generation timestamp, filters and source-data completeness.
- [ ] MTTR/MTBF, downtime and PM compliance are calculated only from valid timestamps and complete data.
- [ ] Printable asset history and work order render correctly on desktop and iPhone.

## H. App integration and regression
- [ ] Load actual CMMS role from the database; do not treat username-based navigation hiding as authorization.
- [ ] Wire all read views to live RLS-protected data.
- [ ] Wire each write action only to its corresponding tested RPC.
- [ ] Add loading, empty, error, retry, duplicate-submit and unsaved-form handling.
- [ ] Test RTL, desktop, iPhone Safari and print layouts.
- [ ] Test login/logout/session expiry and role revocation.
- [ ] Regression-test existing purchase request create/edit/submit/approve/reject/procurement/close/delete/print.
- [ ] Regression-test existing technical work-order list, assignment, progress and approval.
- [ ] Run JavaScript syntax, SQL staging tests, security tests and end-to-end acceptance suite.

## I. Deployment and rollback
- [ ] Prepare a versioned migration and release notes.
- [ ] Capture pre-deploy schema/version checksums and row counts.
- [ ] Confirm backup restore test and rollback owner.
- [ ] Confirm current write-lock state is preserved until explicit go-live approval.
- [ ] Do not rerun or replace the already-present production schema until live-vs-draft reconciliation and external restore testing are complete.
- [ ] Re-enable only the specifically tested RPCs after isolated staging and role-based negative tests pass.
- [ ] Deploy app changes only after schema/RLS/RPC tests pass.
- [ ] Verify production smoke tests with each role.
- [ ] Keep `main` untouched until the release candidate passes.
- [ ] Merge only after explicit go-live approval.
- [ ] Verify rollback procedure in staging before production release.
