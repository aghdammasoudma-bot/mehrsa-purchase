# Production backup runbook — Mehrsa CMMS release gate

Date: 2026-11-18
Target: Production Supabase project `jpzgtbafrpjjbtwqwzlr`
Purpose: create an off-project logical backup and prove it can be restored before any Production CMMS write-enablement.

## Important safety rules

- Never paste the database password, connection string, Supabase access token, service-role key or Auth export into ChatGPT.
- Never commit backup files to this repository. The repository is public; a database dump may contain personal data, email addresses, Auth password hashes and operational records.
- Store downloaded backup files only in encrypted storage controlled by the company/user.
- Never run restore commands against Production. Restore only into a separate disposable project or isolated local Supabase stack.
- Do not use raw `pg_dump` as a substitute for Supabase CLI without a reviewed restore plan; Supabase CLI applies platform-specific filtering.

## 1. Prepare a temporary GitHub Codespace

1. Open the public repository in GitHub.
2. Select branch `feature/cmms-v1`.
3. Open **Code → Codespaces → Create codespace on feature/cmms-v1**.
4. In the Codespaces terminal, check Docker is available:
   ```bash
   docker info
   ```
   If this fails, stop. Supabase CLI database dumps run `pg_dump` in a container; do not improvise with raw dumps.

5. Install the Supabase CLI if it is not already available:
   ```bash
   npm install -g supabase
   supabase --version
   ```

## 2. Connect to Production without saving credentials

1. In Supabase Dashboard, open the Production project and select **Connect**.
2. Copy the Session Pooler connection string if the Codespace network does not support IPv6; otherwise use the direct connection string.
3. In the Codespaces terminal, enter the connection string through a hidden prompt. Do not place it in a command literal or a file:
   ```bash
   read -s -p "Production database connection string: " SUPABASE_DB_URL
   echo
   export SUPABASE_DB_URL
   ```
4. Before dumping, verify the project reference in the connection string is `jpzgtbafrpjjbtwqwzlr`. If it is not, stop.

## 3. Create the logical dumps

Run each command separately and confirm it completes successfully:

```bash
supabase db dump --remote="$SUPABASE_DB_URL" -f roles.sql --role-only
supabase db dump --remote="$SUPABASE_DB_URL" -f schema.sql
supabase db dump --remote="$SUPABASE_DB_URL" -f data.sql --use-copy --data-only -x "storage.buckets_vectors" -x "storage.vector_indexes"
```

These are the Supabase-recommended logical dump layers: custom roles, schema, and data. The CLI may filter platform-managed schemas; do not assume the three files alone preserve every Auth/Storage component.

## 4. Verify what was actually captured

```bash
ls -lh roles.sql schema.sql data.sql
sha256sum roles.sql schema.sql data.sql > SHA256SUMS.txt
grep -nE 'COPY auth\\.(users|identities)|INSERT INTO auth\\.(users|identities)' data.sql | head
```

Production catalog count at the time of this runbook:
- Auth users: 6
- Auth identities: 6
- User profiles: 6
- Storage buckets: 0
- Storage objects: 0

**Auth gate:** confirm whether the dump contains the six Auth users and identities. Supabase CLI behavior around managed `auth` schema differs by command/version and must be verified from the actual dump. If Auth rows are absent, the logical dump is not a complete application recovery package. Use a Supabase-supported project-clone/backup workflow or obtain a documented Auth export/restore procedure before proceeding. Do not hand-edit `auth.users` or attempt to recreate password hashes without a verified procedure.

**Storage gate:** Production currently has no buckets or objects, so no Storage object bytes need exporting at this time. Recheck before backup in case this changes.

## 5. Download and protect the backup

- Download `roles.sql`, `schema.sql`, `data.sql`, and `SHA256SUMS.txt` from the Codespace to encrypted company-controlled storage.
- Verify the downloaded checksums.
- Do not commit them, attach them to this public repository, upload them to a public GitHub Actions artifact, or share them in ChatGPT.
- Delete the temporary Codespace workspace after confirming the encrypted copy is usable.

## 6. Restore test — mandatory before Production release

A successful dump is not proof of recoverability.

- Restore into a separate disposable Supabase project or an isolated local Supabase stack. Never overwrite Production or the existing CMMS Staging project.
- Use the matching PostgreSQL/Supabase version and required extensions.
- Follow the official Supabase logical restore sequence and inspect all errors.
- Verify schema, table counts, indexes, constraints, functions, triggers, RLS policies, grants, Auth user/identity counts, and application login.
- Verify that a restored Auth user can sign in and that existing user IDs still map to the correct purchase and CMMS profiles.
- Record restore start/end time, backup timestamp, file sizes, checksums and any exclusions.
- Only after successful restore should Production changes be considered.

## Current status

No external Production backup has been created or downloaded. No restore test has been performed. This runbook is preparation only; it does not authorize Production DDL, ACL, Storage or scheduler changes.
