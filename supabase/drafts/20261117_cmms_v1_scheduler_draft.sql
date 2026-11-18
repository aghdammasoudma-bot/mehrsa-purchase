-- DRAFT ONLY — do not apply until external backup, live/draft reconciliation and staging tests pass.
-- pg_cron 1.6.4 is available in production but is not installed.
-- This job generates due calendar/meter PM tasks; it does not send notifications.

begin;

create extension if not exists pg_cron with schema pg_catalog;

do $cmms_schedule$
declare
  v_job record;
begin
  if current_user <> 'postgres' then
    raise exception 'Schedule CMMS PM generation as the postgres database owner';
  end if;

  -- Idempotent replacement: exactly one named schedule remains.
  for v_job in
    select jobid from cron.job where jobname='cmms-v1-pm-generation'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
end;
$cmms_schedule$;

select cron.schedule(
  'cmms-v1-pm-generation',
  '*/15 * * * *',
  'select cmms_private.cmms_generate_due_pm_tasks();'
);

commit;

-- Operational verification after staging:
-- 1. Confirm exactly one cron.job row named cmms-v1-pm-generation.
-- 2. Confirm cron.job.username is postgres.
-- 3. Wait for at least two runs and inspect cron.job_run_details for successful status.
-- 4. Verify repeated runs do not duplicate tasks and catch up after missed intervals.
-- 5. Alert on failed runs; do not assume notifications are sent by this job.
