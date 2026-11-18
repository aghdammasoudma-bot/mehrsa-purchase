-- Exactly one daily PM due-task generation job; PostgreSQL cron timezone is GMT.
create extension if not exists pg_cron;

do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='cmms-generate-due-pm-tasks';
  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;
  perform cron.schedule(
    'cmms-generate-due-pm-tasks',
    '15 0 * * *',
    'select cmms_private.cmms_generate_due_pm_tasks();'
  );
end
$$;
