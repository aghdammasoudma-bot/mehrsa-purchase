-- Mehrsa Purchase: secure write API
-- Run only after deploying the matching index.html from this branch.
begin;

create sequence if not exists public.pr_request_number_seq;
select setval(
  'public.pr_request_number_seq',
  greatest(
    coalesce((select max(nullif(regexp_replace(id, '\D', '', 'g'), '')::bigint)
              from public.pr_requests
              where id ~ '^PR-[0-9]+$'), 0),
    1
  ),
  true
);

create or replace function public.create_purchase_request(p_payload jsonb, p_submit boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.user_profiles%rowtype;
  v_id text;
  v_payload jsonb;
begin
  select * into v_profile
  from public.user_profiles
  where user_id = auth.uid() and is_active = true;

  if not found or v_profile.role not in ('admin','tech','maintenance') then
    raise exception 'اجازه ثبت درخواست ندارید.';
  end if;
  if coalesce(trim(p_payload->>'title'),'') = '' then
    raise exception 'عنوان درخواست الزامی است.';
  end if;
  if p_submit and coalesce(trim(p_payload->>'justification'),'') = '' then
    raise exception 'توجیه فنی برای ارسال الزامی است.';
  end if;

  v_id := 'PR-' || lpad(nextval('public.pr_request_number_seq')::text, 3, '0');
  v_payload := (p_payload - 'id' - 'by' - 'role' - 'created_by')
    || jsonb_build_object(
      'id', v_id,
      'by', v_profile.full_name,
      'role', v_profile.role,
      'status', case when p_submit then 'submitted' else 'draft' end
    );

  insert into public.pr_requests(id, payload, created_by, updated_at)
  values (v_id, v_payload, auth.uid(), now());

  return v_payload;
end;
$$;

create or replace function public.transition_purchase_request(
  p_request_id text,
  p_action text,
  p_note text default '',
  p_supplier text default '',
  p_order_no text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.user_profiles%rowtype;
  v_row public.pr_requests%rowtype;
  v_status text;
  v_new_status text;
  v_event text;
  v_icon text;
  v_payload jsonb;
  v_now text;
begin
  select * into v_profile from public.user_profiles
  where user_id = auth.uid() and is_active = true;
  if not found then raise exception 'پروفایل فعال یافت نشد.'; end if;

  select * into v_row from public.pr_requests
  where id = p_request_id for update;
  if not found then raise exception 'درخواست پیدا نشد.'; end if;

  v_payload := v_row.payload;
  v_status := v_payload->>'status';

  if p_action in ('submit','resubmit') then
    if v_profile.role not in ('admin','tech','maintenance')
       or (v_profile.role <> 'admin' and v_row.created_by <> auth.uid())
       or v_status not in ('draft','planner_rejected') then
      raise exception 'اجازه ارسال این درخواست را ندارید.';
    end if;
    if coalesce(trim(v_payload->>'justification'),'') = '' then
      raise exception 'توجیه فنی الزامی است.';
    end if;
    v_new_status := 'submitted';
    v_event := case when p_action='resubmit' then 'ارسال مجدد پس از اصلاح' else 'ارسال به برنامه‌ریز' end;
    v_icon := '📤';
    if p_action='resubmit' then v_payload := v_payload - 'plannerNote'; end if;

  elsif p_action in ('approve','reject') then
    if v_profile.role not in ('planner','admin') or v_status <> 'submitted' then
      raise exception 'فقط برنامه‌ریز می‌تواند درخواست ارسالی را بررسی کند.';
    end if;
    if p_action='reject' and coalesce(trim(p_note),'')='' then
      raise exception 'دلیل رد الزامی است.';
    end if;
    v_new_status := case when p_action='approve' then 'planner_approved' else 'planner_rejected' end;
    v_payload := v_payload || jsonb_build_object('plannerNote',coalesce(p_note,''));
    v_event := case when p_action='approve' then 'تأیید — ارسال به بازرگانی' else 'رد شد — برگشت به فنی' end;
    v_icon := case when p_action='approve' then '✅' else '❌' end;

  elsif p_action in ('inquiry','order','ship','deliver','close') then
    if v_profile.role not in ('procurement','admin') then
      raise exception 'این عملیات فقط برای بازرگانی مجاز است.';
    end if;
    if p_action='inquiry' and v_status not in ('planner_approved','procurement_inquiry') then
      raise exception 'وضعیت درخواست برای شروع استعلام معتبر نیست.';
    elsif p_action='order' and v_status not in ('planner_approved','procurement_inquiry','procurement_ordered') then
      raise exception 'وضعیت درخواست برای ثبت سفارش معتبر نیست.';
    elsif p_action='ship' and v_status <> 'procurement_ordered' then
      raise exception 'ابتدا باید سفارش ثبت شود.';
    elsif p_action='deliver' and v_status <> 'in_transit' then
      raise exception 'درخواست هنوز در مسیر ارسال نیست.';
    elsif p_action='close' and v_status <> 'delivered' then
      raise exception 'فقط درخواست تحویل‌شده قابل بستن است.';
    end if;
    v_new_status := case p_action
      when 'inquiry' then 'procurement_inquiry'
      when 'order' then 'procurement_ordered'
      when 'ship' then 'in_transit'
      when 'deliver' then 'delivered'
      else 'closed' end;
    if coalesce(trim(p_supplier),'')<>'' then v_payload := v_payload || jsonb_build_object('supplier',trim(p_supplier)); end if;
    if coalesce(trim(p_order_no),'')<>'' then v_payload := v_payload || jsonb_build_object('orderNo',trim(p_order_no)); end if;
    v_event := case p_action
      when 'inquiry' then 'شروع استعلام قیمت'
      when 'order' then 'سفارش ثبت شد'
      when 'ship' then 'ارسال از تأمین‌کننده — در راه'
      when 'deliver' then 'تحویل به انبار'
      else 'درخواست بسته شد' end;
    v_icon := case p_action when 'inquiry' then '🔍' when 'order' then '📦' when 'ship' then '🚚' else '✅' end;
  else
    raise exception 'عملیات نامعتبر است.';
  end if;

  v_now := to_char(now(), 'YYYY/MM/DD HH24:MI');
  v_payload := jsonb_set(v_payload, '{status}', to_jsonb(v_new_status), true);
  v_payload := jsonb_set(
    v_payload, '{timeline}',
    coalesce(v_payload->'timeline','[]'::jsonb) ||
    jsonb_build_array(jsonb_build_object(
      'role',v_profile.role,'by',v_profile.full_name,'action',v_event,
      'note',coalesce(p_note,''),'ts',v_now,'icon',v_icon
    )), true
  );

  update public.pr_requests set payload=v_payload, updated_at=now()
  where id=p_request_id;
  return v_payload;
end;
$$;

create or replace function public.delete_purchase_request(p_request_id text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_profile public.user_profiles%rowtype;
  v_row public.pr_requests%rowtype;
begin
  select * into v_profile from public.user_profiles
  where user_id=auth.uid() and is_active=true;
  if not found then raise exception 'پروفایل فعال یافت نشد.'; end if;

  select * into v_row from public.pr_requests
  where id=p_request_id for update;
  if not found then return false; end if;

  if not (
    v_profile.role='admin'
    or (v_row.created_by=auth.uid() and v_row.payload->>'status' in ('draft','planner_rejected')
        and v_profile.role in ('tech','maintenance'))
  ) then
    raise exception 'اجازه حذف این درخواست را ندارید.';
  end if;

  delete from public.pr_requests where id=p_request_id;
  return true;
end;
$$;

-- Remove permissive direct-write policies and block direct table writes.
drop policy if exists "authenticated users can insert requests" on public.pr_requests;
drop policy if exists "authenticated users can update requests" on public.pr_requests;
drop policy if exists "authenticated users can delete requests" on public.pr_requests;
drop policy if exists "authenticated users can read requests" on public.pr_requests;

drop policy if exists "role scoped request reads" on public.pr_requests;

create policy "role scoped request reads"
on public.pr_requests for select to authenticated
using (
  exists (
    select 1 from public.user_profiles u
    where u.user_id=auth.uid()
      and u.is_active=true
      and (
        u.role in ('admin','planner','procurement')
        or (u.role in ('tech','maintenance') and pr_requests.created_by=auth.uid())
      )
  )
);

revoke insert, update, delete on public.pr_requests from anon, authenticated;
grant select on public.pr_requests to authenticated;

revoke all on function public.create_purchase_request(jsonb, boolean) from public;
revoke all on function public.transition_purchase_request(text,text,text,text,text) from public;
revoke all on function public.delete_purchase_request(text) from public;
grant execute on function public.create_purchase_request(jsonb, boolean) to authenticated;
grant execute on function public.transition_purchase_request(text,text,text,text,text) to authenticated;
grant execute on function public.delete_purchase_request(text) to authenticated;

commit;
