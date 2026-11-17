-- DRAFT ONLY — scheduler function; do not install pg_cron or schedule in production yet.
-- Depends on the CMMS base schema. Uses idempotent unique keys and row locks.
-- Run only from a trusted scheduled job after staging validation.

create or replace function public.cmms_generate_due_pm_tasks(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.cmms_pm_plans%rowtype;
  v_latest_meter numeric(14,3);
  v_due_date boolean;
  v_due_meter boolean;
  v_due_at timestamptz;
  v_due_meter_value numeric(14,3);
  v_interval interval;
  v_created integer := 0;
  v_inserted integer;
begin
  for v_plan in
    select p.*
    from public.cmms_pm_plans p
    where p.is_active
    order by p.created_at
    for update skip locked
  loop
    v_interval := case v_plan.frequency_unit
      when 'day' then make_interval(days => v_plan.frequency_value::integer)
      when 'week' then make_interval(days => (7 * v_plan.frequency_value)::integer)
      when 'month' then make_interval(months => v_plan.frequency_value::integer)
      when 'year' then make_interval(months => (12 * v_plan.frequency_value)::integer)
      else null
    end;

    select mr.meter_value into v_latest_meter
    from public.cmms_asset_meter_readings mr
    where mr.asset_id=v_plan.asset_id
      and mr.meter_code=v_plan.meter_code
      and mr.meter_unit=v_plan.meter_unit
    order by mr.reading_at desc, mr.created_at desc
    limit 1;

    loop
      v_due_date := v_plan.frequency_basis in ('calendar','hybrid')
        and v_plan.next_due_at is not null
        and v_plan.next_due_at <= p_now;
      v_due_meter := v_plan.frequency_basis in ('meter','hybrid')
        and v_plan.next_due_meter_value is not null
        and v_latest_meter is not null
        and v_latest_meter >= v_plan.next_due_meter_value;

      exit when not v_due_date and not v_due_meter;

      v_due_at := case when v_due_date then v_plan.next_due_at else null end;
      v_due_meter_value := case when v_due_meter then v_plan.next_due_meter_value else null end;

      insert into public.cmms_pm_tasks(pm_plan_id,asset_id,due_at,due_meter_value,status)
      values(v_plan.id,v_plan.asset_id,v_due_at,v_due_meter_value,'due')
      on conflict do nothing;

      get diagnostics v_inserted = row_count;
      v_created := v_created + v_inserted;

      if v_due_date then
        if v_interval is null then
          raise exception 'Calendar PM plan has unsupported frequency unit: %',v_plan.frequency_unit;
        end if;
        v_plan.next_due_at := v_plan.next_due_at + v_interval;
      end if;

      if v_due_meter then
        v_plan.next_due_meter_value := v_plan.next_due_meter_value + v_plan.frequency_value;
      end if;
    end loop;

    update public.cmms_pm_plans
    set next_due_at=v_plan.next_due_at,
        next_due_meter_value=v_plan.next_due_meter_value
    where id=v_plan.id;
  end loop;

  return v_created;
end;
$$;

revoke all on function public.cmms_generate_due_pm_tasks(timestamptz) from public, anon, authenticated;
grant execute on function public.cmms_generate_due_pm_tasks(timestamptz) to service_role;

-- Scheduling decision is deliberately deferred. pg_cron is available on this
-- Supabase project but is not currently installed. After staging validation,
-- choose one: pg_cron (database job) or a scheduled Supabase Edge Function.
-- Never schedule from a browser timer.
