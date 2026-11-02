-- Apply on Supabase SQL Editor after deploying the matching test UI.
begin;

-- All internal roles can read purchase requests; write actions remain RPC-controlled.
drop policy if exists "role scoped request reads" on public.pr_requests;
create policy "internal team can read all requests"
on public.pr_requests for select to authenticated
using (
  exists (
    select 1 from public.user_profiles p
    where p.user_id = auth.uid()
      and p.is_active = true
      and p.role in ('admin','tech','maintenance','planner','procurement')
  )
);

-- Technical work orders assigned by the admin.
create table if not exists public.technical_work_orders (
  id bigint generated always as identity primary key,
  title text not null,
  description text not null,
  assigned_username text not null check (assigned_username in ('reza','hamid')),
  due_date date,
  status text not null default 'assigned'
    check (status in ('assigned','in_progress','completed','approved')),
  report text not null default '',
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.technical_work_orders enable row level security;
drop policy if exists "work order read by assignee or admin" on public.technical_work_orders;
drop policy if exists "admin creates work orders" on public.technical_work_orders;
drop policy if exists "assignee updates work orders" on public.technical_work_orders;

create policy "work order read by assignee or admin"
on public.technical_work_orders for select to authenticated
using (
  exists (select 1 from public.user_profiles p
    where p.user_id=auth.uid() and p.is_active=true
      and (p.role='admin' or p.username=assigned_username))
);

create policy "admin creates work orders"
on public.technical_work_orders for insert to authenticated
with check (
  created_by=auth.uid() and exists (
    select 1 from public.user_profiles p
    where p.user_id=auth.uid() and p.is_active=true and p.role='admin'
  )
);

create policy "assignee updates work orders"
on public.technical_work_orders for update to authenticated
using (
  exists (select 1 from public.user_profiles p
    where p.user_id=auth.uid() and p.is_active=true
      and (p.role='admin' or p.username=assigned_username))
)
with check (
  exists (select 1 from public.user_profiles p
    where p.user_id=auth.uid() and p.is_active=true
      and (p.role='admin' or p.username=assigned_username))
);

grant select, insert, update on public.technical_work_orders to authenticated;
grant usage, select on sequence public.technical_work_orders_id_seq to authenticated;

commit;
