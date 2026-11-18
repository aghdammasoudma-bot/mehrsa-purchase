# ممیزی تابع‌به‌تابع امنیت و منطق CMMS V1
تاریخ: 2026-11-18  
محیط بررسی: Production فقط خواندنی؛ هیچ DDL، DML، GRANT، REVOKE یا تغییر تنظیمات اجرا نشد.  
شاخه ثبت مستندات: `feature/cmms-v1`

## خلاصه اجرایی

- کاتالوگ فعلی شامل **27 تابع در `cmms_private`** است: 23 تابع عملیات کسب‌وکار، 3 helper و 1 scheduler.
- در `public` تعداد 31 تابع CMMS دیده شد: 23 wrapper عملیات کسب‌وکار و 8 تابع trigger.
- تمام 27 تابع خصوصی `SECURITY DEFINER` با `search_path = ''` و مالک `postgres` هستند.
- 23 wrapper عمومی عملیات کسب‌وکار `SECURITY INVOKER`، با مالک `postgres` و ACL فقط مالک هستند؛ بنابراین کلاینت authenticated فعلاً نمی‌تواند عملیات نوشتن را فراخوانی کند.
- سه helper خصوصی در ACL فعلی نیاز به تفکیک دارند: دو helper نقش برای اجرای policyها به authenticated مجوز دارند؛ اما `cmms_user_has_active_role(uuid,text[])` نیز authenticated را مجاز می‌کند، در حالی که هیچ policy CMMS از آن استفاده نمی‌کند. این helper شناسه هر کاربر دلخواه را می‌پذیرد و می‌تواند به oracle برای تشخیص نقش کاربر دیگر تبدیل شود. باید در migration آزمایشی، EXECUTE آن از authenticated سلب شود.
- draft موجود برای wrapperهای عمومی، برخلاف برداشت اولیه، الگوی قابل‌قبولی دارد: wrapper باریک، SECURITY DEFINER، search_path خالی، REVOKE از PUBLIC/anon و GRANT دقیق به authenticated. این الگو فقط پس از تست کامل در Staging قابل استفاده است؛ به Production اعمال نشده است.

## 1. موجودی کاتالوگ و زنجیره دسترسی

| بخش | تعداد | وضعیت مشاهده‌شده |
|---|---:|---|
| توابع خصوصی `cmms_private` | 27 | SECURITY DEFINER، search_path خالی، مالک postgres |
| wrapperهای عمومی عملیات | 23 | SECURITY INVOKER، ACL فقط مالک |
| توابع trigger در public | 8 | ACL فقط مالک؛ فراخوانی از طریق trigger |
| جدول‌های CMMS در public | 15 | RLS فعال؛ policyهای مشاهده‌شده فقط SELECT |

ACL خصوصی: دو helper `cmms_has_any_role` و `cmms_has_role_at_location` برای authenticated قابل اجرا هستند؛ helper سوم `cmms_user_has_active_role` نیز در ACL فعلی authenticated را دارد. سایر توابع خصوصی، از جمله 23 عملیات و scheduler، owner-only هستند. هیچ‌کدام از wrapperهای عمومی عملیات برای anon یا authenticated قابل اجرا نیستند.

**نکته exposure:** ابزار کاتالوگ مقدار قابل اتکایی برای تنظیم `pgrst.db_schemas` برنگرداند؛ بنابراین از این ممیزی نمی‌توان نتیجه گرفت `cmms_private` در فهرست exposed schemas هست یا نیست. پیش از هر hardening باید در Dashboard تأیید شود که `cmms_private` در Exposed schemas وجود ندارد. این یک شرط انتشار است، نه فرض.

## 2. بررسی تابع‌به‌تابع — 23 عملیات کسب‌وکار

| تابع خصوصی | کنترل‌های موجود در بدنه | یافته / اقدام لازم پیش از فعال‌سازی |
|---|---|---|
| `cmms_assign_pm_task` | نشست معتبر؛ وضعیت task؛ نقش expert/supervisor در محل؛ نقش فعال assignee؛ قفل ردیف | helper assignee فقط نقش‌های سراسری با `location_id IS NULL` را می‌پذیرد. با نقش‌های فعلی سراسری سازگار است؛ برای نقش‌های مکانی باید helper دارای location اضافه شود. interlock وضعیت تجهیز بازنشسته بررسی نمی‌شود. |
| `cmms_assign_work_order` | نشست؛ وضعیت مجاز؛ نقش فنی در محل؛ assignee فعال؛ ثبت assignment و تغییر وضعیت | helper assignee فقط نقش سراسری را می‌سنجد. امکان چند assignment فعال برای افراد متفاوت از روی unique index فعلی مجاز است؛ باید مشخص شود این رفتار عمدی است یا فقط یک مسئول فعال باید وجود داشته باشد. |
| `cmms_cancel_work_order` | نشست؛ دلیل اجباری؛ قفل WO؛ نقش expert/supervisor؛ لغو و بستن assignmentهای فعال | کنترل‌های اصلی مناسب‌اند؛ انتقال وضعیت نهایی به trigger محافظ وضعیت وابسته است و باید runtime تست شود. |
| `cmms_change_asset_status` | نشست؛ allow-list وضعیت؛ دلیل اجباری؛ قفل تجهیز؛ نقش expert/supervisor | امکان بازنشسته‌کردن تجهیز بدون بررسی دستورکار باز یا PM فعال وجود دارد. نیازمند تصمیم عملیاتی و interlock قبل از فعال‌سازی. |
| `cmms_complete_pm_task` | نشست؛ checklist غیرخالی؛ وضعیت باز؛ assignee یا expert/supervisor؛ ثبت تکمیل | helper نقش assignee فقط نقش سراسری را می‌سنجد. supervisor/expert می‌تواند task تخصیص‌یافته به شخص دیگر را نیز تکمیل کند؛ این اختیار باید صریحاً تأیید شود. |
| `cmms_create_asset` | نشست؛ supervisor/expert؛ کد و نام؛ محل فعال؛ وجود category | criticality با CHECK دیتابیس محدود است. فعال‌بودن category در بدنه بررسی نمی‌شود؛ باید category غیرفعال از انتخاب/ثبت منع شود. |
| `cmms_create_location` | نشست؛ فقط supervisor؛ کد و نام؛ parent فعال | discipline با CHECK دیتابیس محدود و trigger چرخه سلسله‌مراتب را کنترل می‌کند. کنترل یکتایی کد بر constraint متکی است. |
| `cmms_create_pm_plan` | نشست؛ عنوان؛ فرکانس مثبت؛ checklist؛ اعتبارسنجی calendar/meter؛ نقش در محل تجهیز | وجود تجهیز بررسی می‌شود اما retired بودن تجهیز رد نمی‌شود. ایجاد PM روی تجهیز بازنشسته باید مسدود شود. |
| `cmms_create_work_order` | نشست؛ عنوان؛ نوع و اولویت؛ زمان‌بندی؛ مدت غیرمنفی؛ تجهیز غیر retired؛ نقش فنی در محل | کنترل‌های پایه مناسب‌اند؛ تست transition و triggerها همچنان لازم است. |
| `cmms_decide_work_order` | نشست؛ stage/decision مجاز؛ دلیل رد؛ قفل WO؛ نقش متناسب؛ ترتیب دو مرحله؛ مدیر متفاوت از سرپرست | trigger approval علاوه بر این، creator/assignee را از تأیید منع و تست موفق/تصمیم بازگشت به سرویس را الزام می‌کند. هر دو لایه باید با تست منفی تأیید شوند. |
| `cmms_link_purchase_request` | نشست؛ WO باز؛ نقش expert/supervisor؛ وجود شناسه در `pr_requests` | فقط وجود درخواست خرید بررسی می‌شود؛ مجوز مشاهده/دسترسی درخواست برای کاربر یا ارتباط درخواست با همان واحد/محل احراز نمی‌شود. نیازمند تصمیم محصولی و کنترل مجازبودن ارتباط. |
| `cmms_reassign_work_order` | نشست؛ علت اجباری؛ assignment فعال؛ assignee جدید متفاوت و فعال؛ WO باز؛ نقش فنی؛ ثبت و خاتمه assignment قبلی | helper assignee فقط نقش سراسری را می‌سنجد. unique index از assignment فعال تکراری برای همان شخص جلوگیری می‌کند. |
| `cmms_record_meter_reading` | نشست؛ کد/واحد؛ مقدار غیرمنفی؛ وجود تجهیز؛ نقش technician/expert/supervisor در محل | تجهیز retired رد نمی‌شود؛ مقدار قرائت نسبت به قرائت قبلی monotonic نیست و الزام تطبیق با meter تعریف‌شده در PM plan وجود ندارد. باید قواعد کنتور مشخص و اعمال شوند. |
| `cmms_record_work_order_action` | نشست؛ شرح؛ WO فعال؛ assignment فعال یا نقش فنی در محل؛ ثبت action | نوع action با CHECK دیتابیس محدود و duration غیرمنفی است؛ اما برای `quantity` و `meter_reading` قید غیرمنفی مشاهده نشد. اعتبارسنجی در تابع و constraint لازم است. |
| `cmms_release_work_order` | نشست؛ فقط وضعیت triage؛ نقش expert/supervisor در محل | منطق پایه روشن است؛ باید با مسیر triage و trigger وضعیت در تست یکپارچه بررسی شود. |
| `cmms_report_failure` | نشست؛ شرح اجباری؛ تجهیز غیر retired؛ نقش reporter/technician/expert/supervisor در محل | priority با CHECK دیتابیس محدود است. نقش reporter در seed فعلی وجود ندارد. attachment pathها از نظر bucket/path/مالکیت بررسی نمی‌شوند. |
| `cmms_set_pm_plan_active` | نشست؛ وجود PM plan؛ نقش expert/supervisor در محل | غیرفعال‌کردن plan بدون بررسی taskهای باز انجام می‌شود؛ رفتار taskهای موجود باید تعیین و تست شود. |
| `cmms_set_work_order_progress` | نشست؛ وضعیت بعدی allow-list؛ قفل WO؛ assignment یا نقش expert/supervisor؛ transition مشخص | helper assignee فقط نقش سراسری را می‌سنجد. transitionها باید در تست runtime با trigger وضعیت تطبیق داده شوند. |
| `cmms_start_pm_task` | نشست؛ وضعیت task؛ فقط assignee؛ نقش فعال technician/expert | helper نقش فقط نقش سراسری را می‌سنجد. کنترل مکانی مستقل ندارد اما شرط تخصیص و نقش فعال دارد. |
| `cmms_submit_work_order_test` | نشست؛ نتیجه تست مجاز؛ وضعیت testing؛ assignee یا نقش فنی؛ تصمیم بازگشت به سرویس در نتیجه passed | مسیر اصلی مناسب است؛ attachment pathها و طول/کیفیت توضیح تست کنترل نمی‌شوند. تست منفی برای return-to-service الزامی است. |
| `cmms_triage_failure` | نشست؛ تصمیم convert/reject؛ دلیل رد؛ قفل گزارش؛ نقش expert/supervisor؛ تبدیل یا رد | پس از ثبت گزارش، بازنشسته‌شدن تجهیز پیش از triage دوباره بررسی نمی‌شود. باید در زمان تبدیل، وضعیت فعلی تجهیز بررسی شود. |
| `cmms_update_asset` | نشست؛ فیلدهای اصلی؛ قفل تجهیز؛ نقش در محل قدیم و جدید؛ محل فعال؛ وجود category | category غیرفعال رد نمی‌شود؛ criticality به CHECK متکی است. attachment list قابلیت جایگزینی دارد اما pathها اعتبارسنجی نمی‌شوند. |
| `cmms_update_pm_plan` | نشست؛ عنوان؛ فرکانس؛ checklist؛ قفل plan؛ نقش در محل؛ اعتبارسنجی calendar/meter | بازنشسته‌بودن تجهیز متصل به plan بررسی نمی‌شود. interlock و سازگاری با taskهای باز باید تست شود. |

## 3. بررسی helperها و scheduler

| تابع | رفتار مشاهده‌شده | تصمیم امنیتی |
|---|---|---|
| `cmms_has_any_role(text[])` | نقش فعال کاربر جاری و پروفایل فعال را بررسی می‌کند | برای policyها لازم است؛ دسترسی authenticated فقط در صورت نیاز policy حفظ شود؛ anon نباید اجرا کند. |
| `cmms_has_role_at_location(text[],uuid)` | نقش فعال کاربر جاری، پروفایل فعال، نقش سراسری یا نقش در محل/ancestor را بررسی می‌کند | برای policyها و کنترل مکانی لازم است؛ تست hierarchy و cross-location ضروری است. |
| `cmms_user_has_active_role(uuid,text[])` | شناسه کاربر دلخواه می‌گیرد؛ نقش فعال سراسری و پروفایل فعال را بررسی می‌کند | در Staging، EXECUTE برای authenticated/anon سلب و owner-only نگه داشته شد؛ توابع SECURITY DEFINER داخلی می‌توانند آن را به‌عنوان مالک فراخوانی کنند. |
| `cmms_generate_due_pm_tasks()` | scheduler؛ قفل planها با SKIP LOCKED؛ ایجاد taskهای calendar/meter؛ سقف 100 تکرار برای هر plan | در P1 Staging، planهای متصل به asset بازنشسته فیلتر شدند. ACL فقط برای owner/service_role باقی مانده و هیچ wrapper عمومی ندارد؛ اجرای زمان‌بندی‌شده واقعی هنوز تست نشده است. |

## 4. ریسک‌های اولویت‌دار

### P0 — پیش از هر مجوزدهی RPC
1. تأیید شود `cmms_private` در exposed schemas مربوط به Data API نیست.
2. `cmms_user_has_active_role(uuid,text[])` از دسترسی مستقیم authenticated خارج شود؛ این تابع برای policyها لازم نیست.
3. الگوی تأییدشده در Staging: public wrapperها SECURITY INVOKER بمانند؛ فقط امضای دقیق wrapper و private SECURITY DEFINER implementation متناظر به authenticated EXECUTE بگیرند؛ search_path خالی و ارجاع schema-qualified حفظ شود.
4. helperهای policy فقط در حد نیاز RLS/Storage مجوز داشته باشند؛ `cmms_user_has_active_role` و trigger-only functions owner-only بمانند؛ scheduler فقط owner/service_role و بدون wrapper عمومی باشد. هیچ GRANT روی کل schema یا همه توابع داده نشود.
5. تست منفی نقش‌ها، creator/assignee approval، cross-location و انتقال‌های workflow در Staging اجرا شود.

### P1 — منطق کسب‌وکار پیش از فعال‌سازی عملیات
- محدودکردن `quantity` و `meter_reading` در ثبت اقدام تعمیراتی به مقادیر مجاز (حداقل غیرمنفی).
- منع ثبت قرائت کنتور برای تجهیز retired و تعیین قاعده قرائت نزولی/تغییر کنتور.
- منع ایجاد/ویرایش PM برای تجهیز retired و جلوگیری از تولید task برای آن.
- تعیین رفتار PM taskهای باز هنگام غیرفعال‌کردن plan.
- تعیین interlock بازنشستگی تجهیز در حضور WO/PM فعال.
- اعتبارسنجی attachment pathها با bucket و مسیر متعلق به همان رکورد/کاربر.
- تعیین قاعده دسترسی و ارتباط CMMS به درخواست خرید؛ وجود شناسه به‌تنهایی کافی نیست.
- جلوگیری از triage تبدیل خرابی به WO در صورتی که تجهیز پس از گزارش بازنشسته شده باشد.
- تصمیم درباره امکان چند assignee فعال برای یک WO و تکمیل assignment history برای PM task.

## 5. ارزیابی draft زنجیره RPC

فایل قدیمی `supabase/drafts/cmms_v1_rpc_wrapper_hardening_STAGING_ONLY.sql` حاوی الگوی قدیمی SECURITY DEFINER برای wrapperهای عمومی است و **منسوخ/غیرقابل اجرا** محسوب می‌شود. الگوی جایگزین در migration release-candidate ثبت شده است:
- public wrapperها SECURITY INVOKER هستند؛
- هر wrapper فقط private implementation متناظر را صدا می‌زند؛
- فقط امضای دقیق public wrapper و private routine لازم به authenticated EXECUTE می‌گیرند؛
- `search_path = ''` و نام‌های schema-qualified حفظ شده‌اند؛
- `cmms_user_has_active_role`، trigger-only functions و scheduler از RPC عمومی قابل فراخوانی نیستند.

این الگو در Staging compile و ACL-check شده است. فعال‌سازی آن در Production همچنان به backup/restore، تأیید عدم exposure بودن `cmms_private`، و تست واقعی Auth/API نیاز دارد.

## 6. وضعیت اجرا و محدودیت‌ها

- Production همچنان فقط با SELECT/catalog ممیزی شده؛ هیچ بکاپ، restore، DDL، DML، GRANT، REVOKE، policy، trigger، function، storage یا scheduler در Production تغییر نکرد.
- Migration نسخه‌دار `20261118090000_cmms_v1_release_candidate.sql` در Staging با version `20261118064059` اعمال شد.
- تست‌های runtime SQL-level با هویت‌های synthetic در Staging انجام شد: خرید-link، RLS و cross-location، جریان کامل WO با دو تأییدکننده متفاوت، جلوگیری از self-approval، PM scheduler idempotency، retirement interlocks، P1 مقدارهای نامعتبر و Storage RLS.
- تست واقعی مرورگر/Auth JWT/Storage HTTP، full purchase-module regression و اجرای cron هنوز انجام نشده است.
- `main` و deployment عملیاتی تغییر نکردند.
- این سند به‌تنهایی مجوز فعال‌سازی CMMS نیست.


## 7. Staging findings that supersede earlier P1 observations

The following P1 findings from the initial static review have since been addressed in the release-candidate migration and partially exercised in Staging:
- Retired-asset meter readings, PM-plan creation/update and failure-to-work-order conversion are blocked.
- PM task generation skips retired assets.
- Asset retirement is blocked while non-terminal work orders or active PM plans exist.
- Action duration, quantity and meter values reject negative, NaN and Infinity inputs.
- Purchase-link SECURITY DEFINER implementation reproduces the live `pr_requests` SELECT-policy role check, rejects unknown/closed requests and is idempotent on duplicate links.
- Storage object policies now bind the path to a real record and explicitly qualify the outer `storage.objects.name`; the first Staging test found and corrected an outer-column shadowing defect.
- Runtime tests confirmed location isolation, creator self-approval denial, full two-person approval and the PM completion/retirement path.

Still open:
- Meter rollover/reset/replacement semantics and whether readings must be monotonic.
- Behavior for open PM tasks when a plan is deactivated.
- Actual file-byte validation, malware scanning and MIME spoof resistance.
- Full real-Auth API/Storage tests and scheduler cron recovery/monitoring.
- Full purchase module regression because Staging uses minimal compatibility stubs rather than the live purchase schema/data.
