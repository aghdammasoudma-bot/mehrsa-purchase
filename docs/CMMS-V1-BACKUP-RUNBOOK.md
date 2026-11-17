# CMMS v1 — External Backup and Restore Runbook
Date: 2026-11-17
Project ref: `jpzgtbafrpjjbtwqwzlr`

## Purpose
Create an external, downloadable logical backup of the current production database and prove it can be restored to a separate disposable project before enabling any CMMS writes or deploying the app.

## Important constraints
- The existing `private_backup.snapshots` row is inside the same Supabase project. It is not an off-site disaster-recovery backup.
- The GitHub repository is public. Never upload database dumps, Auth records, passwords, tokens, or user data to this repository.
- Do not paste the database password, connection string, Supabase access token, service-role key or JWT secret into ChatGPT.
- Supabase Free projects do not have downloadable scheduled database backups. Supabase recommends CLI exports and off-site storage: https://supabase.com/docs/guides/platform/backups
- Supabase CLI dump requires Docker because it runs `pg_dump` in a container.

## 1. Prepare a secure machine
Use a personal or otherwise authorized machine, not a restricted company workstation if software installation is prohibited.

Install:
- Supabase CLI: https://supabase.com/docs/guides/local-development/cli/getting-started
- Docker Desktop: https://www.docker.com/products/docker-desktop/

Create a private folder outside the public GitHub repository, for example:
`Mehrsa-CMMS-Backup-2026-11-17/`

## 2. Get a database connection string
In the Supabase Dashboard for project `jpzgtbafrpjjbtwqwzlr`:
1. Open **Connect**.
2. Choose the Session Pooler connection string unless the network supports the direct connection.
3. Keep the password local. Do not send it in chat or commit it to Git.

## 3. Export roles, schema and data
Run the official Supabase CLI commands from the private backup folder. Replace the placeholder locally; do not include the actual password in a shared script.

```bash
supabase db dump --db-url "$DB_URL" -f roles.sql --role-only
supabase db dump --db-url "$DB_URL" -f schema.sql
supabase db dump --db-url "$DB_URL" -f data.sql --use-copy --data-only
```

If the CLI version requires linking first, run:
```bash
supabase link --project-ref jpzgtbafrpjjbtwqwzlr
```

Do not assume the export is complete just because the commands exit successfully. Inspect the output files and verify that they contain:
- `public.pr_requests`
- `public.user_profiles`
- `public.technical_work_orders`
- `public.cmms_*` schema, RLS policies, functions, triggers and role rows
- `auth.users` and the required Auth data, if supported by the selected dump options

If Auth users or required schemas are absent, stop and use the official Supabase backup/restore guide to export those components separately. Do not declare the backup complete until the required objects and data are present.

## 4. Record integrity checks
The current production baseline to compare against:
- `public.pr_requests`: 46 rows
- `public.user_profiles`: 6 rows
- `public.technical_work_orders`: 3 rows
- `public.cmms_user_roles`: 4 rows
- `public.cmms_audit_logs`: 4 rows
- All other CMMS operational tables: 0 rows
- `storage.buckets`: 0 rows
- `storage.objects`: 0 rows

Save file hashes (SHA-256) for `roles.sql`, `schema.sql`, and `data.sql` in a local manifest. Keep the files encrypted and in at least one location outside the Supabase project.

## 5. Prove restoration
Restore only into a separate disposable Supabase project or isolated PostgreSQL instance. Never restore over production for this test.

Use the official restore guide and a single transaction with stop-on-error semantics. Verify:
- The restore completes without SQL errors.
- The row counts above match.
- RLS is enabled and the expected policies exist.
- CMMS functions and triggers are present.
- The four role mappings are present.
- The purchase-request workflow tables and data remain intact.
- Auth users can authenticate in the restored environment according to the intended Auth configuration.

A successful dump without a successful restore test is not a verified backup.

## 6. Release gate
Only after the restore test passes:
1. Save the backup date, file hashes, restore target and verification results.
2. Reconcile the live production catalog against the branch SQL drafts.
3. Test all migrations and acceptance tests in isolated staging.
4. Review the minimum required RPC grants and enable only the approved ones.
5. Deploy Storage, scheduler and UI only after staging and purchase-regression tests pass.

Official references:
- Database backups: https://supabase.com/docs/guides/platform/backups
- CLI database dump: https://supabase.com/docs/reference/cli/supabase-db-dump
- Backup/restore with CLI: https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore
