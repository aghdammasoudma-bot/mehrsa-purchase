# CMMS V1 — Implementation status (2026-11-18)

## Completed in the feature branch
- Replaced the static CMMS preview cards with a live, read-only data layer in `index.html`.
- Added reads for assets, locations, categories, failure reports, work orders, PM plans, PM tasks, and audit events.
- Dashboard metrics are calculated from returned database rows; no sample/demo counts are used.
- Added loading, query-error, empty-state, and manual-refresh states.
- Switching into CMMS hides the purchase request workspace and its KPIs; switching back restores the existing purchase view.
- The CMMS UI remains restricted to the four explicitly assigned accounts: masoud, biabani, reza, and hamid.
- No CMMS INSERT, UPDATE, DELETE, or UPSERT operation was added.
- Existing purchase module code was not intentionally modified beyond view switching to show/hide the CMMS module.

## Verification performed
- Read-only catalog queries confirmed the eight queried CMMS tables and their columns exist in production.
- Current row counts: assets 0, locations 0, failure reports 0, work orders 0, PM plans 0, PM tasks 0.
- The inline JavaScript blocks in the updated HTML passed a JavaScript syntax parse check.
- The production database was queried with SELECT statements only during this milestone.

## Not yet verified
- Authenticated browser reads through the Supabase Data API under each of the four CMMS user accounts.
- Cross-role and direct REST access behavior.
- End-to-end purchase regression tests in a browser.
- Any create/edit/approval workflow; all CMMS write controls remain disabled/not implemented.
- Storage uploads, notifications, PM scheduler, and reporting exports.
- Staging migration and isolated acceptance test execution.

## Release boundary
- This work is on `feature/cmms-v1` only.
- `main` was not merged or deployed.
- No production schema, grants, RLS policies, triggers, functions, storage buckets, or scheduler jobs were changed in this milestone.
- Do not merge or publish until authenticated read tests, role tests, backup/recovery decision, and purchase regression checks are complete.
