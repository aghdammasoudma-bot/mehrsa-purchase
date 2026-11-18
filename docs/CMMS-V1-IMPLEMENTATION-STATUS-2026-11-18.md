# CMMS V1 — Implementation status (2026-11-18)

## Completed in the feature branch
- Replaced the static CMMS preview cards with a live, read-only data layer in `index.html`.
- Added reads for assets, locations, categories, failure reports, work orders, PM plans, PM tasks, and audit events.
- Dashboard metrics are calculated from returned database rows; no sample/demo counts are used.
- Added loading, query-error, empty-state, and manual-refresh states.
- Added the first equipment master-data form with required-field validation, category/location selectors, technical metadata, criticality, operational status, commissioning and warranty dates, and a local review preview.
- Added a dedicated master-data tab with separate category and hierarchical-location forms. Location fields include code, name, parent location and discipline values aligned to the database CHECK constraint (mechanical, electrical, utilities, production, general); both forms include local required-field validation and case/whitespace-normalized duplicate-code warnings based on currently loaded rows.
- Added read-only tables for existing categories and the location hierarchy. Database-submit controls remain disabled.
- The form's database-submit control is intentionally disabled. The preview validates and displays entered data locally only; it does not create or change database records.
- Switching into CMMS hides the purchase request workspace and its KPIs; switching back restores the existing purchase view.
- CMMS access is now resolved from the authenticated user's active `cmms_user_roles` row, not a hardcoded username allowlist. Current production role assignments were read and matched to the four intended accounts: masoud (technical_supervisor), biabani (responsible_manager), reza (technical_expert), and hamid (technician).
- The `cmms_user_roles` RLS policy allows users to read their own assignment. The browser-side authenticated Data API path has not yet been exercised. If duplicate active role rows exist for one user, `.maybeSingle()` fails closed rather than granting access.
- The role table currently has no uniqueness constraint on `user_id`; this is a governance/schema gap to resolve in a reviewed migration after backup/recovery and staging validation.
- No CMMS INSERT, UPDATE, DELETE, or UPSERT operation was added.
- Existing purchase module code was not intentionally modified beyond view switching to show/hide the CMMS module.

## Verification performed
- Read-only catalog queries confirmed the eight queried CMMS tables and their columns exist in production.
- Current row counts: assets 0, locations 0, failure reports 0, work orders 0, PM plans 0, PM tasks 0.
- The inline JavaScript blocks in the updated HTML passed a JavaScript syntax parse check after the database-backed role-resolution change, equipment form, and master-data forms (all 4 script blocks parse successfully).
- A read-only count confirmed `cmms_asset_categories` and `cmms_locations` remain at 0 rows; no master-data records were written.
- A fresh read-only count confirmed `cmms_assets`, `cmms_locations`, and `cmms_asset_categories` remain at 0 rows; no equipment data was written.
- A read-only catalog query confirmed `cmms_user_roles` has `user_id`, `role`, and `is_active` columns, with a self-read RLS policy; a read-only join confirmed the four current user-to-role assignments.
- Compared the location discipline form options against the live production CHECK constraint and corrected the form to offer only accepted values (`mechanical`, `electrical`, `utilities`, `production`, `general`).
- JavaScript syntax parsing was rerun after this correction; all four inline script blocks parse successfully.
- A read-only constraint inspection confirmed unique constraints on category/location codes and the location self-reference foreign key; no schema was changed.
- The production database was queried with SELECT statements only during this milestone.

## Security review — read-only production inspection

- All 15 public CMMS tables inspected have RLS enabled and currently expose SELECT policies only; no INSERT/UPDATE/DELETE policy was found in this inspection.
- The public CMMS RPC wrapper functions inspected are not executable by either `anon` or `authenticated` in the current database ACL. Therefore, do not assume the write workflows can currently be called by the frontend; explicit least-privilege grants are a required reviewed migration step.
- The `cmms_private` schema is not usable by `anon`, but currently has USAGE for `authenticated`. The two role-check helper functions have EXECUTE for authenticated users because RLS policies call them. This should be included in the security review; do not expose additional private functions through grants.
- Private workflow functions are SECURITY DEFINER but their ACLs deny EXECUTE to anon/authenticated. The public SECURITY DEFINER functions observed are trigger functions and their ACLs also deny direct execution to anon/authenticated.
- This was a metadata/ACL inspection only. No GRANT, REVOKE, schema, policy, or function change was made.

## Not yet verified
- Authenticated browser reads through the Supabase Data API under each of the four CMMS user accounts.
- Cross-role and direct REST access behavior, including validation that the current helper-function exposure does not leak location-role information beyond the intended scope.
- End-to-end purchase regression tests in a browser.
- Any create/edit/approval workflow; the asset form is present but database submission remains disabled, and all CMMS write controls remain disabled/not implemented.
- Browser-level rendering, mobile layout, form validation behavior, and authenticated category/location option reads still require a preview-browser test.
- Master-data category/location create, edit, disable, and delete workflows are not enabled; uniqueness and hierarchy-cycle enforcement must be implemented server-side before writes are allowed.
- Storage uploads, notifications, PM scheduler, and reporting exports.
- Staging migration and isolated acceptance test execution.
- Least-privilege EXECUTE grants for the intended authenticated RPC wrappers; current ACLs deny authenticated execution, so write workflows are not yet callable from the client.

## Release boundary
- This work is on `feature/cmms-v1` only.
- `main` was not merged or deployed.
- No production schema, grants, RLS policies, triggers, functions, storage buckets, or scheduler jobs were changed in this milestone.
- Do not merge or publish until authenticated read tests, role tests, backup/recovery decision, and purchase regression checks are complete.
