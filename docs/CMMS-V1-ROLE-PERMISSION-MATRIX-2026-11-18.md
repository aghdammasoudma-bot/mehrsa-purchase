# CMMS V1 — ماتریس مجوزها و کنترل دسترسی RPC
تاریخ ممیزی: 2026-11-18  
مبنای بررسی: کاتالوگ واقعی PostgreSQL، ACL توابع، بدنه 24 تابع `cmms_private`، نقش‌های seed شده و wrapperهای public. این سند تحلیل کد موجود است؛ به معنی فعال بودن عملیات نوشتن نیست.

## 1) نقش‌های فعال در دیتابیس

| نقش | وضعیت نقش | پروفایل کاربر | دامنه |
|---|---|---|---|
| `technical_supervisor` | فعال | فعال | سراسری (location_id=NULL) |
| `technical_expert` | فعال | فعال | سراسری |
| `technician` | فعال | فعال | سراسری |
| `responsible_manager` | فعال | فعال | سراسری |

**نقص پیکربندی:** در تابع ثبت خرابی نقش `reporter` مجاز شمرده شده، اما در seed فعلی چنین نقشی وجود ندارد. بنابراین تا زمان تصمیم‌گیری و افزودن کنترل‌شده نقش reporter، گزارش خرابی فقط برای technician، technical_expert و technical_supervisor قابل استفاده است. مسئول نهایی (responsible_manager) مجوز ثبت خرابی ندارد.

## 2) ماتریس عملیات

راهنما: ✓ مجاز طبق کنترل‌های موجود در تابع خصوصی؛ ✓* فقط با شرط مالکیت/تخصیص/مرحله؛ — رد می‌شود؛ S فقط سرویس زمان‌بندی‌شده/مالک دیتابیس.

| عملیات / تابع خصوصی | سرپرست فنی | کارشناس فنی | تکنسین | مسئول نهایی | شرط مهم / نتیجه ممیزی |
|---|:---:|:---:|:---:|:---:|---|
| ثبت تجهیز `cmms_create_asset` | ✓ | ✓ | — | — | نقش سراسری فعال |
| ویرایش تجهیز `cmms_update_asset` | ✓ | ✓ | — | — | دسترسی مکانی به تجهیز |
| ایجاد محل `cmms_create_location` | ✓ | — | — | — | فقط سرپرست فنی |
| تغییر وضعیت تجهیز `cmms_change_asset_status` | ✓ | ✓ | — | — | دلیل تغییر اجباری |
| گزارش خرابی `cmms_report_failure` | ✓ | ✓ | ✓ | — | دسترسی به محل؛ نقش reporter در seed موجود نیست |
| بررسی/تعیین تکلیف خرابی `cmms_triage_failure` | ✓ | ✓ | — | — | دسترسی به محل |
| ایجاد دستورکار `cmms_create_work_order` | ✓ | ✓ | — | — | وضعیت اولیه triage |
| تأیید مرحله سرپرست `cmms_decide_work_order` | ✓ | — | — | — | فقط stage=technical_supervisor و وضعیت pending_supervisor_approval |
| تأیید نهایی `cmms_decide_work_order` | — | — | — | ✓ | فقط stage=responsible_manager؛ باید فردی متفاوت از تأییدکننده سرپرست باشد |
| آزادسازی برای اجرا `cmms_release_work_order` | ✓ | ✓ | — | — | دسترسی به محل و وضعیت مجاز |
| تخصیص دستورکار `cmms_assign_work_order` | ✓ | ✓ | — | — | مقصد باید تکنسین یا کارشناس فعال باشد |
| لغو دستورکار `cmms_cancel_work_order` | ✓ | ✓ | — | — | علت لغو اجباری |
| ثبت اقدام تعمیراتی `cmms_record_work_order_action` | ✓ | ✓ | ✓* | — | تکنسین باید تخصیص فعال مرتبط داشته باشد؛ کارشناس/سرپرست طبق دسترسی محل |
| تغییر وضعیت پیشرفت `cmms_set_work_order_progress` | ✓ | ✓ | ✓* | — | تکنسین فقط در محدوده تخصیص/وضعیت مجاز |
| ثبت نتیجه تست `cmms_submit_work_order_test` | ✓ | ✓ | ✓* | — | تکنسین تخصیص‌یافته یا نقش فنی مجاز؛ کنترل مرحله تست |
| تخصیص مجدد `cmms_reassign_work_order` | ✓ | ✓ | — | — | تخصیص‌دهنده فنی؛ مقصد تکنسین/کارشناس فعال؛ علت اجباری |
| اتصال درخواست خرید `cmms_link_purchase_request` | ✓ | ✓ | — | — | دسترسی به محل؛ اعتبار درخواست خرید باید کنترل شود |
| ایجاد برنامه PM `cmms_create_pm_plan` | ✓ | ✓ | — | — | دسترسی به محل تجهیز؛ چک‌لیست اجباری |
| فعال/غیرفعال‌سازی PM `cmms_set_pm_plan_active` | ✓ | ✓ | — | — | دسترسی به محل تجهیز |
| ویرایش برنامه PM `cmms_update_pm_plan` | ✓ | ✓ | — | — | دسترسی به محل تجهیز |
| تخصیص وظیفه PM `cmms_assign_pm_task` | ✓ | ✓ | — | — | مقصد technician یا technical_expert فعال |
| شروع وظیفه PM `cmms_start_pm_task` | — | ✓* | ✓* | — | باید کاربر تخصیص‌یافته باشد؛ role فعال technician/expert |
| تکمیل وظیفه PM `cmms_complete_pm_task` | ✓ | ✓ | ✓* | — | تکنسین تخصیص‌یافته یا expert/supervisor در محل؛ نتیجه چک‌لیست اجباری |
| ثبت قرائت کنتور `cmms_record_meter_reading` | ✓ | ✓ | ✓ | — | دسترسی به محل؛ کنترل بیشتر درباره تخصیص/دامنه کنتور نیازمند تست است |
| تولید وظایف سررسیدشده PM `cmms_generate_due_pm_tasks` | S | S | S | S | تابع داخلی زمان‌بندی؛ به کاربر نهایی expose نشود |

## 3) اصول قطعی مجوزدهی

1. تمام عملیات نوشتن نیازمند نشست معتبر است؛ `auth.uid()` باید غیر NULL باشد.
2. کنترل نقش فقط با `cmms_user_roles.is_active=true` و `user_profiles.is_active=true` معتبر است.
3. عملیات تجهیز/دستورکار/PM باید scope مکانی را از محل خود تجهیز محاسبه کند؛ role سراسری مجاز است، نقش محدود به محل فقط همان محل و زیرمجموعه‌های آن.
4. تکنسین حق ایجاد تجهیز، محل، برنامه PM، دستورکار یا تصمیم تأیید ندارد.
5. مسئول نهایی فقط مرحله دوم تأیید دستورکار را انجام می‌دهد؛ نباید بتواند مرحله سرپرست را تأیید کند.
6. تأیید نهایی باید توسط شخصی غیر از تأییدکننده مرحله سرپرست باشد.
7. توابع خصوصی `cmms_private.*` باید owner-only باقی بمانند. هرگز به schema یا تمام توابع آن GRANT عمومی نده.
8. کلاینت فقط به wrapperهای public باریک و بررسی‌شده دسترسی EXECUTE می‌گیرد.
9. `cmms_generate_due_pm_tasks` فقط برای مالک دیتابیس/زمان‌بند مجاز است و wrapper عمومی/مجوز authenticated نمی‌گیرد.
10. هیچ جدول عملیاتی نباید از طریق INSERT/UPDATE/DELETE مستقیم کلاینت قابل نوشتن شود؛ نوشتن فقط از مسیر RPC کنترل‌شده.

## 4) مانع فعلی زنجیره RPC

- wrapperهای public فعلی `SECURITY INVOKER` هستند.
- پیاده‌سازی‌های متناظر در `cmms_private` از نوع `SECURITY DEFINER` هستند اما ACL آنها owner-only است.
- در نتیجه wrapper فعلی نمی‌تواند private routine را با مجوز authenticated اجرا کند.
- اعطای EXECUTE صرفاً به wrapper عمومی کافی نیست؛ فراخوانی تابع خصوصی همچنان با مجوز caller انجام می‌شود.
- راهکار پیشنهادی برای بررسی در staging: تبدیل فقط wrapperهای public تأییدشده به `SECURITY DEFINER` با `SET search_path = ''` و ارجاع کاملاً qualified به تابع private، حفظ کنترل نقش در private routine، سپس GRANT دقیق امضای همان wrapper به authenticated. توابع private owner-only می‌مانند.

## 5) موارد باز و ریسک‌ها

| مورد | ریسک | اقدام لازم |
|---|---|---|
| نقش reporter در کد هست ولی seed نشده | ابهام در مجوز گزارش خرابی | تصمیم محصولی؛ یا حذف reporter از allow-list یا seed نقش با کاربر/دامنه مشخص |
| `cmms_record_meter_reading` | کنترل تخصیص در ممیزی اولیه احراز نشده | بازبینی کامل بدنه و تست منفی |
| اتصال درخواست خرید | ممکن است ID درخواست نامعتبر/غیرقابل مشاهده باشد | اعتبارسنجی وجود درخواست و دسترسی کاربر به ماژول خرید |
| PM scheduler | سطح دسترسی privileged | فقط cron/owner؛ عدم exposure در PostgREST |
| role scope | نقش‌های فعلی سراسری هستند | قبل از تقسیم مسئولیت مکانی، seedها و تست inheritance بازبینی شوند |
| نبود staging branch | نمی‌توان migration را ایمن اعتبارسنجی کرد | ایجاد staging فقط پس از بررسی هزینه و تأیید مالک |

## 6) تست‌های پذیرش المطلوبة قبل از فعال‌سازی

- unauthenticated: همه RPCهای نوشتن باید رد شوند.
- reporter (در صورت عدم seed): ثبت خرابی رد شود.
- technician: گزارش خرابی، شروع/ثبت اقدام/تکمیل فقط برای دستورکار یا PM تخصیص‌یافته؛ ایجاد تجهیز/محل/دستورکار/PM و تأیید رد شود.
- technical_expert: عملیات فنی مجاز در scope؛ تأیید مرحله سرپرست و مدیر رد شود.
- technical_supervisor: ایجاد/ویرایش اطلاعات پایه، مدیریت کار و فقط تأیید مرحله اول.
- responsible_manager: فقط تأیید مرحله دوم؛ تأیید مرحله اول و اجرای تعمیرات رد شود.
- same-user approval: یک نفر نتواند هر دو مرحله را انجام دهد.
- cross-location: نقش محدود به یک محل نتواند در محل غیرمجاز عملیات کند.
- retired asset / inactive role / inactive profile: عملیات مرتبط رد شود.
- workflow status: هر انتقال خارج از state machine رد شود.
- history/audit: رویدادها append-only و غیرقابل دستکاری مستقیم باقی بمانند.

## 7) وضعیت اجرا

این ماتریس و migration پیشنهادی صرفاً artifact شاخه توسعه‌اند. هیچ GRANT، ALTER FUNCTION، DDL، DML یا migration روی پروژه production اجرا نشده است. Supabase project در حال حاضر هیچ development branch گزارش نکرد؛ بنابراین migration هنوز روی staging اجرا نشده است.


## 8) تأیید تکمیلی ACL و مالکیت توابع

ممیزی تکمیلی کاتالوگ PostgreSQL نشان داد مالک تمام 23 wrapper عمومی کسب‌وکار و تمام توابع خصوصی بررسی‌شده `postgres` است. تمام توابع خصوصی `SECURITY DEFINER` با `search_path=""` تنظیم شده‌اند. فقط دو helper نقش (`cmms_has_any_role` و `cmms_has_role_at_location`) برای `authenticated` قابل اجرا هستند؛ سایر توابع خصوصی، از جمله همه write routineها و scheduler، برای authenticated و anon غیرقابل اجرا هستند. تمام 23 wrapper عمومی فعلی `SECURITY INVOKER` هستند و برای authenticated/anon مجوز EXECUTE ندارند.

این یافته مالکیت wrapper را برای طرح پیشنهادی definer تأیید می‌کند؛ با این حال هنوز تست runtime و تست منفی نقش‌ها انجام نشده است. شمار wrapperهای تجاری در migration و تست ACL برابر 23 است.


## 9) اصلاح تعداد کاتالوگ و ممیزی تابع‌به‌تابع — 2026-11-18

ممیزی تکمیلی کاتالوگ تعداد واقعی توابع را روشن کرد: **27 تابع خصوصی** در `cmms_private` (23 عملیات، 3 helper و 1 scheduler) و 31 تابع در `public` (23 wrapper عملیاتی و 8 trigger function). اشاره قبلی به 24 تابع خصوصی نادرست بود و با عدد واقعی جایگزین می‌شود.

گزارش کامل کنترل‌های هر 23 عملیات، helperها، scheduler، ریسک‌ها و gateهای P0/P1 در فایل زیر ثبت شد:
`docs/CMMS-V1-FUNCTION-BY-FUNCTION-SECURITY-AUDIT-2026-11-18.md`

نکته مهم ACL: `cmms_user_has_active_role(uuid,text[])` در ACL فعلی برای authenticated قابل اجراست، درحالی‌که هیچ policy CMMS به آن ارجاع نمی‌دهد و تابع شناسه هر کاربر دلخواه را می‌پذیرد. draft آزمایشی اکنون REVOKE دقیق این تابع از PUBLIC/anon/authenticated را اضافه می‌کند؛ این تغییر هنوز روی هیچ دیتابیسی اجرا نشده است.

موارد مهم منطق کسب‌وکار برای رفع قبل از فعال‌سازی:
- اعتبارسنجی غیرمنفی بودن `quantity` و `meter_reading` در ثبت اقدام؛
- جلوگیری از قرائت کنتور روی تجهیز بازنشسته و تعیین قاعده قرائت نزولی؛
- جلوگیری از ایجاد/ویرایش PM روی تجهیز بازنشسته و تولید task برای آن؛
- interlock بازنشستگی تجهیز با دستورکار/PM فعال؛
- بررسی دسترسی و ارتباط درخواست خرید پیش از link؛
- بررسی وضعیت تجهیز هنگام triage خرابی؛
- تصمیم‌گیری درباره چند assignment فعال و lifecycle وظایف PM.

`cmms_private` در حال حاضر برای authenticated USAGE دارد. مقدار exposed schemas از کاتالوگ قابل تأیید نبود؛ پیش از هر migration باید از Dashboard تأیید شود که این schema در Data API exposed schemas قرار ندارد.
