# CMMS v1 — Production State Audit
Date: 2026-11-17
Project: `jpzgtbafrpjjbtwqwzlr`

## Executive state
The CMMS schema is present in the production Supabase database, but the module is not operational. The database is write-locked for client users. The CMMS app changes remain on `feature/cmms-v1`; `main` has not been changed or deployed.

## Verified database facts
- 15 `public.cmms_*` tables; RLS enabled on all 15. Live column-name comparison matches all 15 tables in the current base schema draft.
- 15 RLS policies; every policy is SELECT-only.
- Authenticated role: SELECT is granted on CMMS tables; INSERT, UPDATE and DELETE are not granted.
- Anonymous role: no SELECT on CMMS tables.
- 58 CMMS-named functions and 24 CMMS triggers exist. Live-vs-branch comparison found exact function-name and trigger-name matches; the only signature mismatch is `cmms_report_failure` (live 8 arguments, branch 9 with optional downtime timestamp).
- No public CMMS RPC is executable by `anon` or `authenticated`.
- Only two private read-only authorization helpers are executable by `authenticated`: `cmms_has_any_role` and `cmms_has_role_at_location`.
- No private CMMS function is executable by `service_role`; PM generation is not scheduled.
- Four active global CMMS role rows exist:
  - `masoud` → `technical_supervisor`
  - `biabani` → `responsible_manager`
  - `reza` → `technical_expert`
  - `hamid` → `technician`
- Four audit records exist for those role inserts; actor is NULL because they were seeded by a privileged database action.
- All operational CMMS tables are empty: no locations, assets, failure reports, work orders, assignments, actions, approvals, PM plans/tasks, meter readings or purchase links.
- `cmms-evidence` Storage bucket and objects: 0.
- Existing application data remains: `pr_requests` 46 rows, `user_profiles` 6 rows, `technical_work_orders` 3 rows.
- Supabase migration-list returns no migration history for this work.

## What this means
The four mapped users can read CMMS data only where the SELECT RLS policies allow it. There is currently no usable client-side CMMS write path: the public RPCs are not executable and direct table writes are denied. The production CMMS schema must be described as **installed, empty and write-locked**, not as a draft-only schema and not as a released CMMS.

## Backup and recovery
The `private_backup.snapshots` row `pre_cmms_2026_11_17` was captured at 2026-11-17 18:03 UTC, before the CMMS role-seed audit events. It is an in-project logical snapshot of the three legacy tables and selected metadata. It is not an external restorable backup and does not contain password hashes, sessions, project settings, API keys or Storage object bytes. No external dump or restore test exists.

The GitHub repository is public, so it must not be used to store a database dump, user records or other sensitive backup material. The connected Supabase tools in this session do not provide a downloadable `db dump` operation. Supabase documentation recommends CLI exports and off-site storage for Free projects.

## Safety / security observations
- Current CMMS privileges are fail-closed for client writes.
- Supabase Security Advisor reports pre-existing legacy SECURITY DEFINER warnings: 2 public functions callable by anon and 7 callable by authenticated, plus leaked-password protection disabled. These findings concern existing purchase/work-order functions; do not change them as part of CMMS v1.
- Performance Advisor reports 24 unindexed foreign keys (23 in CMMS), four legacy RLS initplan warnings, and 10 unused indexes (mostly CMMS indexes before any operational data exists). A separate 23-index proposal has been added for staging/query-plan review.
- No CMMS-specific Security Advisor lint was returned.
- The live production function definitions and grants are not guaranteed to match the latest branch drafts. The live catalog must be reconciled before any grant or migration change.

## GitHub / app state
- `main` is unchanged.
- `feature/cmms-v1` is the development branch. Current comparison: 163 commits ahead, 0 behind; 14 changed files at the latest check.
- `index.html` contains a CMMS UI shell only on the feature branch. It is not deployed from `main`; no live workflow is enabled. A function/DOM-ID comparison found all 53 pre-existing functions and all existing IDs preserved; four CMMS functions and three CMMS IDs were added.
- Existing purchase workflow tables and counts are unchanged.

## Release blockers
1. Produce an external logical backup and prove restoration in a separate disposable project.
2. Reconcile all 15 live tables, 58 functions and 24 triggers against the current GitHub drafts; generate a versioned migration that represents the actual live state.
3. Create or obtain a disposable staging database and execute the migration/test suite there. Do not use the connected SQL execution action for rollback-only testing; observed DDL and role-seed statements persisted despite an explicit rollback wrapper.
4. Run positive and negative role/RLS/RPC tests, including distinct supervisor/manager approval, creator/assignee self-approval denial, rework, cancellation, reassignment and PM generation.
5. Review 24 unindexed foreign keys and add only indexes justified by query patterns.
6. Deploy private evidence Storage bucket and policies, then test uploads/downloads.
7. Schedule server-side PM generation with idempotency and missed-run recovery.
8. Wire the feature-branch UI to RLS-protected reads and specifically approved RPCs; test desktop and iPhone.
9. Regression-test purchase request and existing technical-work-order workflows.
10. Only after all gates pass, enable the minimum required RPC grants and release the UI with explicit go-live approval.

## Operating instruction
Do not drop tables, reset the project, grant CMMS write access, apply another migration, or merge `feature/cmms-v1` into `main` until the external backup and staging gates are complete. Preserve the current write-lock.
