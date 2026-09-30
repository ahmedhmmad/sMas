# Gate F1 — تطبيق الويب (الهيكل)

**الحالة:** 🔒 **F1 CLOSED** (2026-09-28، CI `25570ce`) — W1 و W2 مُصلحان · **الكود:** `apps/web/` · **الاختبارات:** Vitest 32 · Playwright 16 · pytest 132 · pgTAP 1346

---

## 1. النطاق المعتمد والقيدان

خطة F1 معتمدة (2026-09-27) بقيدين مسجلين في CLAUDE.md §6 و PLAN §9:

1. **`app.my_permissions()` (M28)** تستخرج effective permission keys داخل DB من الجداول نفسها وبشروط السياق/الحالة نفسها — لا enumeration عبر `has_permission()`، ولا أدوار ولا نطاقات ولا معرّفات، وليست حداً أمنياً.
2. **`school_id` في F1 ليس authorization input:** `getTenantContext()`/`getSchoolContext()` للعرض ولطلبات الدخول فقط؛ لا تضيف أي دالة جلب بيانات السياق كنطاق. F3 يستبدل تنفيذهما بالـsubdomain دون تغيير المستدعين.

```text
Browser ─► سياق التطوير (F1) / subdomain (F3) ─► tenant + school للعرض والدخول فقط
        ─► جلسة Supabase Auth (supabase-js: تخزين، تجديد)
        ─► PostgREST (RLS) للقراءة  |  FastAPI للدخول، الـcapabilities، التصدير، المنصة
        ─► سياق DB + RLS يقرر
```

---

## 2. ما بُني

| البند | التنفيذ |
|---|---|
| **F1.1 Shell** | React 19 + TS + Vite 8 + Tailwind 4؛ `dir="rtl"`، IBM Plex Sans Arabic (محلي، `@fontsource`)؛ شريط جانبي/درج على الهاتف؛ حالات loading / error / not-found / forbidden / unavailable؛ خروج؛ **انتهاء الجلسة**: `SIGNED_OUT` لم يطلبه المستخدم ⇒ رسالة «انتهت الجلسة» |
| **F1.2 السياق** | `src/context/appContext.ts` — التنفيذ الحالي: متغيرات البيئة + اختيار تطوير محلي (يُزال في F3). ⤷ **F3 (2026-10-01):** من `window.location.hostname`؛ أداة التطوير و`check:prod-bundle` أُزيلا؛ CORS من `API_CORS_ORIGIN_BASE` — `docs/F3_HOST_CONTEXT.md` |
| **F1.3 Capabilities** | `GET /me/capabilities` ← `app.my_permissions()`: `{context, permissions}` فقط |
| **F1.4 التنقل** | `src/components/navigation.ts` من المفاتيح: الرئيسية؛ الطلاب (`student.read` — «أبنائي» لولي الأمر، «ملفي» للطالب)؛ الجهات (`tenant.read` في سياق المنصة). **الإخفاء عرض فقط** — كل صفحة تقرأ ما تعيده RLS/FastAPI |
| **F1.5 الدخول** | تبويبات: الموظف (`/auth/password/login`)، ولي الأمر (OTP أو كلمة مرور)، الطالب (`/auth/student/login`)؛ `/login/admin` للمنصة و`tenant_admin` (بريد أصلي)؛ الجلسة تُسلَّم لـ`supabase-js` (`setSession`)؛ **شاشة التغيير الإجباري** (D2، D4 A/C): `updateUser` ← `/auth/activate`. الرسائل رموز الخادم مترجمة؛ الموقوف والمقفل والخاطئ رسالة واحدة (I1). لا يُعرض بريد اصطناعي ولا `token_hash` ولا رابط |
| **F1.6 الشاشات** | الرئيسية (الاسم من الـprofile الذاتي، السياق، بطاقات)؛ الطلاب (PostgREST تحت RLS — بلا مرشّح مدرسة من السياق)؛ تفاصيل الطالب (غير المرئي = غير موجود)؛ التصدير لكل مدرسة مرئية عبر FastAPI (يظهر مع `student.export`)؛ الجهات للمنصة عبر `GET /platform/tenants` (**مُدقَّق N5**) |
| **F1.7 i18n** | `t(key)` + `ar.json`؛ رموز أخطاء الـAPI ← مفاتيح؛ **قاعدة ESLint محلية `smas/no-ui-literals`**: نص بين الوسوم وقيم `placeholder`/`title`/`alt`/`label`/`aria-*` حرفيةً أو تعبيراً — دون `className` والمسارات والمفاتيح و`data-testid` |

**إضافات الخلفية (معتمدة):** M28؛ `/me/capabilities`؛ `/platform/tenants` (صف تدقيق لكل جهة مقروءة)؛ CORS من `API_CORS_ORIGINS` (**`*` مرفوض**)؛ `API_OTP_SENDER=file:<path>` للـE2E (خارج `apps/web`، بلا مسار HTTP، مرفوض عند `API_ENVIRONMENT=production`)؛ `API_LOGIN_ATTEMPTS`/`API_LOGIN_WINDOW_SECONDS` إعداد لا ثابت.

---

## 3. الإثبات

### 3.1 Build + Vitest (29)

| الملف | يثبت |
|---|---|
| `guards.test.ts` | كل مفتاح مستعمل موجود في الفهرس؛ لا رسالة فارغة؛ **قيد 2**: قائمة الملفات التي تقرأ السياق مغلقة، ولا ملف يجلب بيانات يقرؤه، وعميل الـAPI لا يضيف tenant/school؛ قاعدة النصوص بـ`RuleTester` (صالح/غير صالح) |
| `ui.test.tsx` | التنقل لكل نوع حساب (منصة، موظف بـ/بلا `student.read`، ولي أمر، طالب، بلا سياق)؛ الحارس (مجهول ⇒ الدخول، pending ⇒ التغيير من أي مسار، unavailable، not-found داخل الإطار)؛ نماذج الموظف والطالب، OTP (إرسال ← الرمز ← تحقق)، كلمة مرور ولي الأمر، 401/429 مترجمة؛ التغيير الإجباري (عدم التطابق قبل أي نداء، رمز الخادم، النجاح) |
| `auth.test.tsx` | `INITIAL_SESSION` يحمّل المفاتيح؛ `SIGNED_OUT` غير مطلوب ⇒ expired؛ الخروج الطوعي ليس expiry؛ جلسة بلا سياق لموظف ⇒ unavailable |

### 3.2 Playwright — المتصفح (16)

| الحساب | الواجهة | المسموح | الممنوع (ومنه الرابط اليدوي) |
|---|---|---|---|
| Platform Admin | الجهات | جدول الجهات (API مُدقَّق) | `/students` ⇒ فارغ |
| tenant_admin | الطلاب + تصدير SA/SB/SS | تصدير | `/platform/tenants` ⇒ forbidden |
| group_manager | الطلاب (SA، SB) + تصدير | تصدير SA | طالب SS بالرابط ⇒ not found |
| school_admin | الطلاب (SA) + تصدير SA | تفاصيل طالب SA | طالب SB بالرابط ⇒ not found |
| secretary / teacher / accountant / counselor | الطلاب (SA)، بلا تصدير | القائمة | `/platform/tenants` ⇒ forbidden |
| bus_supervisor | بلا «الطلاب» | الرئيسية | `/students` ⇒ فارغ |
| ولي الأمر A | OTP ← تغيير إجباري ← «أبنائي» | ابنه وحده؛ ثم الدخول بكلمة المرور | طالب SS ⇒ not found |
| ولي الأمر B | OTP ← مفتوح فوراً | ابنه وحده | طالب الـseed ⇒ not found |
| ولي الأمر C | لا رسالة OTP؛ الكلمة المؤقتة ← تغيير | ابنه وحده | طالب SB ⇒ not found |
| الطالب | المعرّف ← التغيير (من أي مسار) ← «ملفي» | صفه وحده | طالب الـseed ⇒ not found؛ لا `smas.invalid`/`token_hash` في الصفحة |

+ كلمة مرور خاطئة (رسالة عامة)، الخروج يعيد للدخول ويحمي المسارات، و**تغيير سياق المدرسة في المتصفح**: العرض يتغير والبيانات والتصدير لا.

الـfixtures تُنشأ بالمسارات الحقيقية لكل تشغيل (`services/api/tests/web_e2e_fixtures.py`)، والمدارس بأسمائها (SA، SB، SS) لا بعددها.

### 3.3 الضوابط السلبية — كلها تُفشل الاختبارات

| الكسر | يفشل |
|---|---|
| نص حرفي في مكوّن | lint |
| صفحة الطلاب تقرأ سياق المدرسة في الاستعلام | 2 حارسان (قيد 2) |
| مفتاح غير موجود في الفهرس | حارس الفهرس |
| القائمة تُظهر «الطلاب» بلا `student.read` | E2E: bus_supervisor |
| التصدير يظهر بلا `student.export` | E2E: الأدوار الأربعة للقراءة |
| M28: تجاهل حالة الدور/العضوية، أو السياق، أو إسناد المنصة | pgTAP 28 (4 + 3 + 1) |

---

## 4. التشغيل

```bash
npx supabase db reset                      # seed E5 مطلوب
cd apps/web && npm ci
npm run lint && npm run typecheck && npm test && npm run build
E2E_BROWSER_CHANNEL=msedge npx playwright test   # محلياً بمتصفح النظام؛ CI يثبّت Chromium
npm run dev                                # VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY / VITE_API_URL
```

---

## 5. ملاحظات للمراجعة

| # | |
|---|---|
| W1 | ✅ **مُصلح (M29، 2026-09-28):** الجداول الثلاثة (`platform_tenants`، `groups`، `schools`) ضمن N5 بنص RLS §11 — لا قراءة مباشرة لـPlatform Admin؛ المسار الوحيد `app.platform_read_tenants()` تقرأ وتدقّق في عبارة واحدة (fail closed)؛ `/platform/tenants[/{id}]` يستدعيها. pgTAP 29 (15) + ضابطان سلبيان (بلا تدقيق ← 4؛ إعادة سياسة القراءة ← «لا قراءة مباشرة») |
| W2 | ✅ **مُصلح (2026-09-28): الأداة dev-only فعلياً** — وحدة مستقلة (`src/devtools/`) تُحمَّل كسولاً خلف شرط يُطوى عند البناء؛ بناء production الافتراضي يخلو منها (يفحصه `npm run check:prod-bundle` في CI)، و`VITE_DEV_CONTEXT=1` يُفشل `vite build` ما لم يُصرَّح بـ`SMAS_BUILD_TARGET=development` (بناء E2E). ضابط سلبي: بناء التطوير يحويها فيفشل الفحص؛ اختبار للحارس |
| W3 | ولي الأمر والطالب لا يريان صف المدرسة (§6 بند 8) — لا تحتاجه شاشات F1 |
| W4 | تنزيل Chromium الخاص بـPlaywright فشل محلياً (شبكة) — E2E المحلي بـEdge عبر `E2E_BROWSER_CHANNEL`؛ CI يثبّت Chromium |
| W5 | ✅ **CI/runtime requirement: Node 22** (`vitest` 5 و`jsdom` 30 تتطلبانه) |
| W7 | ✅ **سباق تنقل كشفه E2E (2026-09-28):** بعد الدخول كان تنقلان متتاليان (الحارس + `navigate('/')`) يعيدان تركيب صفحة تغيير الكلمة فيمحوان ما كُتب؛ أُزيل التنقل الصريح بعد الدخول وبعد التغيير — الحارس وحده يوجّه حسب الحالة. E2E 16/16 مرتين متتاليتين |
| W6 | الاعتماديات مثبتة بإصدارات محددة؛ TypeScript على 5.9 (لا 7 الأصلي) لتوافق `typescript-eslint`؛ npm 10 المحلي يتعطل في حل peers لـvitest (خطأ داخلي) — التثبيت بـnpm 11، و`npm ci` يعمل بالقفل |

**خارج F1 (بقرار):** F3، design system، accessibility audit متقدم، PWA/offline، Flutter، notifications، business modules، school settings UI، 5c، deployment/CDN، لغات أخرى.
