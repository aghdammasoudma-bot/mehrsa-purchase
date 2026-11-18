-- CMMS V1 purchase-request link authorization hardening.
-- DRAFT ONLY — apply and test in isolated Staging after schema reconciliation.
-- Does not grant EXECUTE to API roles and does not modify the live purchase module.

create or replace function cmms_private.cmms_link_purchase_request(
  p_work_order_id uuid,
  p_purchase_request_id text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_wo public.cmms_work_orders%rowtype;
  v_location_id uuid;
  v_link_id uuid;
  v_request_created_by uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if nullif(btrim(coalesce(p_purchase_request_id,'')),'') is null then
    raise exception 'Purchase request id is required';
  end if;

  select w.* into v_wo
  from public.cmms_work_orders w
  where w.id=p_work_order_id
  for key share;

  if not found or v_wo.status in ('closed','cancelled') then
    raise exception 'Only an open work order can be linked to a purchase request';
  end if;

  select a.location_id into v_location_id
  from public.cmms_assets a
  where a.id=v_wo.asset_id
  for key share;

  if not found then
    raise exception 'Work order asset not found';
  end if;

  if not cmms_private.cmms_has_role_at_location(
    array['technical_supervisor','technical_expert'],v_location_id
  ) then
    raise exception 'Only technical supervisor or expert can link a purchase request';
  end if;

  -- SECURITY DEFINER bypasses pr_requests RLS. Reproduce its current SELECT
  -- policy explicitly: any active internal profile role may read requests.
  if not exists (
    select 1 from public.user_profiles up
    where up.user_id=auth.uid()
      and up.is_active
      and up.role in ('admin','tech','maintenance','planner','procurement')
  ) then
    raise exception 'User is not authorized to access purchase requests';
  end if;

  select pr.created_by into v_request_created_by
  from public.pr_requests pr
  where pr.id=p_purchase_request_id
  for key share;

  if not found then
    raise exception 'Purchase request not found';
  end if;

  -- The request must remain attributable to an authenticated creator.
  if v_request_created_by is null then
    raise exception 'Purchase request has no accountable creator';
  end if;

  insert into public.cmms_work_order_purchase_links(
    work_order_id,purchase_request_id,created_by
  )
  values(p_work_order_id,p_purchase_request_id,auth.uid())
  on conflict (work_order_id,purchase_request_id) do nothing
  returning id into v_link_id;

  if v_link_id is null then
    select l.id into v_link_id
    from public.cmms_work_order_purchase_links l
    where l.work_order_id=p_work_order_id
      and l.purchase_request_id=p_purchase_request_id;
  end if;

  return v_link_id;
end;
$function$;

-- The public SECURITY INVOKER wrapper, if present, must remain SECURITY INVOKER.
-- Do not grant broad EXECUTE. The exact private-function EXECUTE grant belongs
-- in the separately reviewed RPC privilege-chain migration after tests.
