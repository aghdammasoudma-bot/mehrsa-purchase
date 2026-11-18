-- CMMS V1 RPC ACL acceptance checks — run only on isolated STAGING after hardening migration.
-- Read-only assertions. This script does not insert, update, delete, or change grants.

do $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) args,
           p.prosecdef, coalesce(p.proconfig, array[]::text[]) config,
           pg_get_userbyid(p.proowner) owner_name
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'cmms_assign_pm_task','cmms_assign_work_order','cmms_cancel_work_order',
        'cmms_change_asset_status','cmms_complete_pm_task','cmms_create_asset',
        'cmms_create_location','cmms_create_pm_plan','cmms_create_work_order',
        'cmms_decide_work_order','cmms_link_purchase_request','cmms_reassign_work_order',
        'cmms_record_meter_reading','cmms_record_work_order_action','cmms_release_work_order',
        'cmms_report_failure','cmms_set_pm_plan_active','cmms_set_work_order_progress',
        'cmms_start_pm_task','cmms_submit_work_order_test','cmms_triage_failure',
        'cmms_update_asset','cmms_update_pm_plan'
      )
  loop
    v_count := v_count + 1;
    if not r.prosecdef then
      raise exception 'Wrapper %.%(%) is not SECURITY DEFINER', 'public', r.proname, r.args;
    end if;
    if not ('search_path=""' = any(r.config)) then
      raise exception 'Wrapper %.%(%) does not pin empty search_path: %', 'public', r.proname, r.args, r.config;
    end if;
    if has_function_privilege('anon', r.oid, 'EXECUTE') then
      raise exception 'anon unexpectedly has EXECUTE on public.%(%)', r.proname, r.args;
    end if;
    if not has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      raise exception 'authenticated lacks EXECUTE on public.%(%)', r.proname, r.args;
    end if;
    if r.owner_name <> 'postgres' then
      raise exception 'Unexpected wrapper owner for public.%(%) : %', r.proname, r.args, r.owner_name;
    end if;
  end loop;

  if v_count <> 23 then
    raise exception 'Expected 23 public business wrappers, found %', v_count;
  end if;

  if has_function_privilege('authenticated', 'cmms_private.cmms_create_asset(text,text,uuid,text,uuid,text,text,text,jsonb,text)', 'EXECUTE') then
    raise exception 'authenticated must not execute private write routine directly';
  end if;
  if has_function_privilege('authenticated', 'cmms_private.cmms_generate_due_pm_tasks()', 'EXECUTE') then
    raise exception 'authenticated must not execute PM scheduler routine';
  end if;
  if has_function_privilege('anon', 'cmms_private.cmms_has_any_role(text[])', 'EXECUTE') then
    raise exception 'anon must not execute role helper';
  end if;

  raise notice 'CMMS RPC ACL structural checks passed for % wrappers', v_count;
end $$;

-- Verify no direct client DML grants on CMMS operational tables.
do $$
declare r record;
begin
  for r in
    select c.oid, c.relname
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relname like 'cmms_%'
  loop
    if has_table_privilege('authenticated', r.oid, 'INSERT')
       or has_table_privilege('authenticated', r.oid, 'UPDATE')
       or has_table_privilege('authenticated', r.oid, 'DELETE')
       or has_table_privilege('anon', r.oid, 'INSERT')
       or has_table_privilege('anon', r.oid, 'UPDATE')
       or has_table_privilege('anon', r.oid, 'DELETE') then
      raise exception 'Direct client DML grant detected on public.%', r.relname;
    end if;
  end loop;
  raise notice 'CMMS direct-DML privilege checks passed';
end $$;
