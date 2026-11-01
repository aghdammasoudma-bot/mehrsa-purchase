-- مرحله ۱ مهاجرت امن سامانه درخواست خرید
-- این اسکریپت فقط شناسه مالک درخواست را اضافه و داده‌های قبلی را نگاشت می‌کند.
-- عمداً سیاست‌های فعلی RLS را در این مرحله تغییر نمی‌دهد تا برنامه قطع نشود.

begin;

alter table public.pr_requests
  add column if not exists created_by uuid
  references auth.users(id);

-- انتساب درخواست‌های قدیمی بر اساس نام ثبت‌کننده موجود در payload
-- فقط برای داده‌های قبلی؛ پس از این مرحله مالک هر درخواست از auth.uid() می‌آید.
update public.pr_requests r
set created_by = p.user_id
from (
  select user_id, full_name
  from public.user_profiles
) p
where r.created_by is null
  and r.payload ->> 'by' = p.full_name;

-- درخواست‌های جدیدی که مستقیماً درج شوند، به حساب واردشده منتسب می‌شوند.
alter table public.pr_requests
  alter column created_by set default auth.uid();

create index if not exists idx_pr_requests_created_by
  on public.pr_requests(created_by);

-- گزارش کنترل: تعداد کل، منتسب‌شده و بدون مالک
select
  count(*) as total_requests,
  count(created_by) as attributed_requests,
  count(*) filter (where created_by is null) as unattributed_requests
from public.pr_requests;

commit;
