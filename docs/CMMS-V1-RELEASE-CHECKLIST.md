# CMMS V1 — Release & Acceptance Checklist

Status: Production schema is installed but write-locked; Production has not been modified during this Staging run. Isolated Staging now contains the full 15-table CMMS schema, hardening, authorization, workflow RPCs, P1 rules, purchase-link hardening and private evidence bucket. Staging SQL-level workflow and negative tests have passed in part. Staging uses compatibility stubs for the purchase module and synthetic users, so it is not a full production clone. No versioned Supabase migration history, real browser/API acceptance, external backup/restore or Production deployment exists yet. All boxes below are release gates, not claims of completion.

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
- [ ] Enable RLS on `private_backup.snapshots` as defense in depth after backup/restore and a Production change window. Current catalog checks show anon/authenticated/service_role have no schema USAGE and no table privileges; the Advisor's RLS-disabled warning is generic and effective client access is currently denied. Proposed SQL (not executed):
  ```sql
  ALTER TABLE "private_backup"."snapshots" ENABLE ROW LEVEL SECURITY;
  ```
  Decide whether any explicit administrative policy is required; with no policies, client roles are blocked.

## B. Schema and migration
- [ ] Review base schema and hardening SQL with a second technical reviewer.
- [x] An earlier cut of the base schema, hardening, authorization, role-seed and workflow RPC SQL passed a single explicit PostgreSQL transaction that was rolled back; a subsequent catalog check found no CMMS relations or `cmms_private` schema remaining.
- [x] Revalidated the latest workflow RPC additions (asset/location CRUD, cancellation guard and latest approval logic) and Storage policy draft in isolated Staging; all SQL layers compiled/applied there.
- [x] Applied the base schema, hardening, authorization, workflow RPC, P1, purchase-link and Storage layers in isolated Staging.
- [ ] Consolidate the tested layers into ordered, versioned Supabase migrations and verify migration replay from an empty database.
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
- [x] Seeded four synthetic global CMMS roles in Staging and verified the four requested role mappings; one additional location-scoped synthetic technician was added solely for isolation tests. Production role seed remains pending.
- [ ] Verify mohammadi (planner) and karami (procurement) have no CMMS access.
- [ ] Verify role revocation takes effect on the next request and cannot be overridden by client metadata.

## D. RLS, API and function security
- [ ] Keep `cmms_private` outside the exposed Data API schemas.
- [ ] Explicitly grant only required authenticated table reads; no anon access.
- [ ] Test anonymous, authenticated-without-role, planner, procurement and each real CMMS role through Supabase Auth/API; SQL-level synthetic tests are not enough.
- [x] Test location-scoped role isolation (a technician scoped to a sibling location could not read another location's asset).
- [x] Verify direct authenticated CMMS table writes are denied and anon CMMS reads are denied by ACL.
- [x] Verify approved public SECURITY INVOKER wrappers are executable by authenticated and not anon in Staging.
- [x] Verify private workflow implementations are not granted to anon and the internal arbitrary-user role lookup helper remains owner-only.
- [ ] Confirm in Supabase Dashboard that `cmms_private` is not included in exposed Data API schemas.
- [ ] Test fixed search_path and explicit auth.uid checks on every privileged function.
- [x] Run Supabase Security Advisor after Staging build; no CMMS-specific security ERROR remains. Only expected stub-table INFO and project-level leaked-password-protection warning remain.
- [ ] Run real Auth/API security tests after exposed-schema confirmation.
- [ ] Do not change legacy purchase SECURITY DEFINER ACLs in the same release; handle their Advisor findings as a separate regression-tested security change.

## E. Corrective maintenance workflow
- [x] SQL-level Staging test: failure report creation, technical triage and conversion to work order.
- [x] SQL-level Staging test: technical release and assignment to an active technician.
- [x] SQL-level Staging test: duplicate purchase-link idempotency and role/PR rejection cases.
- [ ] Real API/JWT tests for failure report evidence and all role/location boundaries.
- [ ] Assigned workers can log diagnosis, repair, parts, labor, readings and evidence.
- [ ] Only assigned workers or authorized technical roles can update execution progress.
- [ ] Test submission requires a recorded test result and explicit return-to-service decision.
- [x] SQL-level Staging test: successful test, supervisor approval and distinct responsible-manager approval closed the work order.
- [x] SQL-level Staging negative test: work-order creator self-approval was rejected.
- [ ] Real API/JWT tests for approval roles, assignment exclusions and role revocation.
- [ ] Rejection returns the order to rework without deleting prior decisions.
- [ ] Closeout requires passed test, return-to-service decision and both current approvals.
- [ ] Creator and every assigned worker are blocked from approving the same order.
- [ ] Cancellation and reassignment RPCs require a reason and preserve history.

## F. Preventive maintenance
- [ ] Calendar-based and meter-based plans have separate, unambiguous units and next-due logic; hybrid plans are explicitly deferred from v1.
- [x] SQL-level Staging test: server-side PM task generation was idempotent on repeated execution.
- [ ] Install and test the named pg_cron job in Staging; verify owner, schedule, missed-run recovery and failure monitoring.
- [ ] Confirm scheduled generation recovers missed runs under real time-based execution.
- [ ] Confirm whether `pg_cron` or Supabase scheduled Edge Functions will be used; `pg_cron` is available but not currently installed in production.
- [ ] Meter readings have source, unit, timestamp and recorder identity.
- [ ] PM task completion requires assigned executor, timestamp and non-empty checklist.
- [ ] Failed checklist items can create/link a corrective work order.
- [ ] Overdue/escalation notifications are designed and verified end-to-end; the PM scheduler draft does not send notifications.

## G. Attachments, audit and reporting
- [x] Created private `cmms-evidence` bucket and SELECT/INSERT policies in isolated Staging only; Production has no CMMS bucket.
- [x] SQL-level Storage RLS test: valid expert asset evidence allowed; technician asset-master upload denied; authorized expert could read linked metadata.
- [ ] Real Storage HTTP API upload/download/signed-URL tests for each record type and role.
- [ ] Validate actual file bytes, spoofed MIME, size limits and malware/content scanning; declared MIME allowlist is not content inspection.
- [ ] Confirm unauthorized users cannot download real evidence objects.
- [ ] Audit all create/update/approval/status/assignment/PM/purchase-link actions.
- [ ] Confirm clients cannot update/delete audit, action, approval or status history.
- [ ] Reports include generation timestamp, filters and source-data completeness.
- [ ] MTTR/MTBF, downtime and PM compliance are calculated only from valid timestamps and complete data.
- [ ] Printable asset history and work order render correctly on desktop and iPhone.

## H. App integration and regression
- [ ] Load actual CMMS role from the database; do not treat username-based navigation hiding as authorization.
- [ ] Test the current read views against the Staging API with real users; current app config still points to Production.
- [ ] Implement the missing CMMS forms/actions; current frontend is still read-only with local preview forms.
- [ ] Wire each write action only to its corresponding tested RPC, with the release gate disabled until backup and API tests pass.
- [ ] Add loading, empty, error, retry, duplicate-submit and unsaved-form handling.
- [ ] Test RTL, desktop, iPhone Safari and print layouts.
- [ ] Test login/logout/session expiry and role revocation.
- [ ] Regression-test existing purchase request create/edit/submit/approve/reject/procurement/close/delete/print.
- [ ] Regression-test existing technical work-order list, assignment, progress and approval.
- [x] Fix the frontend audit-log query so non-governance roles do not request a table they cannot read under RLS.
- [ ] Run JavaScript syntax, browser tests, real API/Storage tests and full end-to-end acceptance suite.

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
