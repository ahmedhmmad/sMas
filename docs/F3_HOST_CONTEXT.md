# Gate F3 — سياق الـhost (Subdomain → Tenant/School Context)

**الحالة:** ✅ منفذ (2026-10-01) — بانتظار المراجعة · **Migration:** M30 `tenant_host_context` · **الاختبارات:** pgTAP 1395 (30: 49) · pytest 213 (F3: 87) · Vitest 77 · Playwright 21

---

## 1. القرارات المعتمدة (2026-10-01)

> **الـsubdomain يحدد سياق المدرسة للواجهة، لكنه لا يمنح أي صلاحية بحد ذاته** (PLAN §3.2) — و **tenant + school المستخرجان من الـsubdomain هما مصدر السياق، لا قيمة يختارها العميل في الجسم** (قرار F3↔D4).

| # | القرار |
|---|---|
| 1 | **شكل الـhost:** `{school}.{tenant}.{base}` ← سياق مدرسة · `{tenant}.{base}` ← سياق Tenant · `admin.{base}` ← المنصة. `admin` و`api` و`www` محجوزة **كـtenant label** (لا يُمنع `admin` كـslug مدرسة) |
| 2 | **M30 `platform_tenants.host_label`** بدل تعديل `tenant_code`: `tenant_code` معرّف أعمال (`_` وأحرف كبيرة)، `host_label` معرّف DNS: `^[a-z0-9][a-z0-9-]{0,62}$`، فريد على مستوى المنصة، محجوزات مرفوضة، لا يكتبه العميل، يُحدَّد في `bootstrap_tenant` |
| 3 | **`Origin` مصدر سياق الدخول في FastAPI** — **مصدر context فقط، ليس مصدر authority ولا إثبات هوية:** `Origin → أين يُبحث · JWT/auth → من المستخدم · DB/RLS → ما يصل إليه`. تزويره من عميل غير المتصفح ليس ثغرة لأنه لا يُستعمل تفويضاً. غائب أو خارج الأصل الأساسي ← **الفشل العام** بلا كشف وجود. **لا fallback من الجسم.** Flutter لاحقاً يحتاج مساراً مستقلاً — ليس في F3 |
| 4 | **CORS مرسَّخ:** `API_CORS_ORIGIN_BASE` (`scheme://base[:port]`)؛ الأصل مسموح ⟺ يحلله **محلل F3 نفسه** إلى أحد الأشكال الثلاثة — لا regex موازٍ، لا `*`، لا wildcard غير مرسَّخ |
| 5 | **لا بحث عام عن اسم المدرسة:** صفحة الدخول تعرض المعرّف المشتق من الـhost؛ الاسم لاحقاً بقرار مستقل (سطح enumeration) |
| + | **لا context drift:** حقول `tenant`/`school` **أُزيلت من الـschemas نهائياً** و`extra="forbid"` — جسم يحملها يُرفض `422` ولا يُتجاهَل |

---

## 2. ما بُني

```text
Browser (host: school-a.dev.example) ──Origin──► FastAPI: host_context.parse ─► (tenant label, school slug)
                                                        │  «أين يُبحث» فقط
                                                        ▼
                                  app.login_context(label, slug) ─► الحساب أو لا شيء (NULL واحد)
                                                        ▼
                               جلسة Supabase Auth (هوية الحساب وحده) ─► RLS تقرر ما يصل إليه
```

### 2.1 قاعدة البيانات — M30 `tenant_host_context`

| العنصر | |
|---|---|
| `platform_tenants.host_label` | `NOT NULL`؛ `platform_tenants_host_label_chk` (النمط المعتمد)، `_reserved` (`admin`, `api`, `www`)، `_uq`؛ اشتقاق أولي للصفوف القائمة `lower(replace(tenant_code,'_','-'))` (تصادم أو محجوز يُفشل الـmigration صراحةً)؛ **لا GRANT** — SELECT الجدول القائم يشمله، لا INSERT/UPDATE لأي دور عميل |
| `app.login_context(label, slug)` | **المحلّل الوحيد لسياق الدخول:** Tenant نشط بهذا الـlabel، و**إن سمّى الـhost مدرسةً** فمدرسة نشطة فيه بهذا الـslug — وإلا لا شيء. داخلي (لا EXECUTE لأحد) |
| دوال الدخول | `resolve_student_login`، `login_account`، `otp_issue`، `otp_verify`، `password_login_account`، `password_login_result` — **البحث بـ`host_label`** عبر `login_context` (لا `tenant_code`)؛ الموظف وولي الأمر يقبلان مدرسة السياق أيضاً (اختيارية). النصوص كما في M24/M26/M27 عدا المحلّل؛ الامتيازات كما كانت (`service_role` وحده) |
| `app.bootstrap_tenant(id, code, host_label, name, admin, display)` | توقيع جديد: النص M22 نفسه + `host_label` في الإدخال والـidempotency؛ allowlist M20 حُدِّث |

**تفسير «سياق تشغيلي غير صالح» (قرار تنفيذي):** الـhost الذي يسمّي مدرسة **مؤرشفة أو غير موجودة** لا يجد **أي** حساب (موظف، ولي أمر، طالب) — السياق يُحَل كاملاً أو لا يُحَل؛ و host الـTenant نفسه يبقى صالحاً للموظف. الرد الخارجي نفسه لكل الحالات.

### 2.2 FastAPI

| العنصر | |
|---|---|
| `app/host_context.py` | `parse_host(hostname, base)` و`OriginBase.parse/context(origin)` — Origin صارم (`scheme://host[:port]`، أحرف صغيرة، بلا مسار/مستخدم/نقطة ختامية)، المخطط والمنفذ يطابقان الأصل الأساسي (المنفذ الافتراضي مُطبَّع) |
| `config.origin_base()` | `API_CORS_ORIGIN_BASE` **إلزامي**؛ `*` وwildcard وأصل بمسار أو IP أو أحرف كبيرة ← `ValueError` عند الإقلاع. يحل محل `API_CORS_ORIGINS` |
| `deps.login_context` | سياق Tenant أو مدرسة من `Origin` وحده، وإلا `None` (غائب، خارج الأصل، المنصة) |
| مسارات الدخول | `StudentLogin {identifier, password}`؛ `OtpRequest {kind, contact}`؛ `OtpVerify {+code}`؛ `PasswordLogin {+password}` — `extra="forbid"`. الطالب يشترط سياق مدرسة. بلا سياق: OTP request ← `202 sent` بلا رسالة، والبقية ← `401 invalid_credentials`. مفتاح حد المحاولات بالـlabel |
| `HostCORSMiddleware` | `is_allowed_origin` = `OriginBase.context(origin) is not None` |

### 2.3 الواجهة

| العنصر | |
|---|---|
| `src/context/hostContext.ts` | `parseHost(hostname, base)` — القواعد نفسها |
| `src/context/appContext.ts` | `getHostContext()` من `window.location.hostname` + `VITE_BASE_DOMAIN`؛ `getTenantContext()`/`getSchoolContext()` **باقيتان** للعرض (`{label}`/`{slug}`، `null` حيث لا ينطبق). لا يُرسل السياق إلى الخادم |
| `App` | host غير معروف ← `UnknownHost` ثابتة: **لا مزود جلسة ولا موجّه ولا طلب** |
| `Login` | host المدرسة: الموظف/ولي الأمر/الطالب؛ host الـTenant: الموظف (ورابط دخول الإدارة)؛ host المنصة: `/login` ← `/login/admin` |
| `ContextLabel` | عرض معرّفات الـhost (الـTenant، المدرسة، أو «إدارة المنصة») في الدخول والإطار والرئيسية |
| `loginFlows` | **لا tenant ولا school في أي جسم** |
| **أداة سياق التطوير (W2) — أُزيلت** | `src/devtools/`، `VITE_DEV_CONTEXT`، فحص الحزمة — السياق من الـhost وحده في كل بناء (التطوير: `*.localhost`) |
| `build-guard.ts` | `vite build` يشترط `VITE_BASE_DOMAIN` اسم DNS صالحاً — وإلا يفشل البناء (لا «عنوان غير معروف» في كل مكان بعد النشر) |

### 2.4 CI والإعداد

`Web — production build` ببيئة `VITE_BASE_DOMAIN=smas.example` (بلا `check:prod-bundle`)؛ E2E على `*.localhost` (`API_CORS_ORIGIN_BASE=http://localhost:4173`، `VITE_BASE_DOMAIN=localhost`)؛ `.env.example`.

---

## 3. الإثبات

### 3.1 قاعدة واحدة، ثلاث نقاط فرض — `docs/contracts/host_context_vectors.json`

متجهات مشتركة (26 host، 17 + 10 origin، 10 أصل أساسي فاسد، 13 label) يقرؤها **Vitest** (`parseHost`) و**pytest** (`parse_host`، `OriginBase`) و**pytest ← DB** (قيد M30 يقبل الـlabels نفسها بالضبط التي يقبلها المحللان). لا «Origin مقبول» يختلف عن «hostname مقبول».

### 3.2 pgTAP `30_host_context` (49)

القيد (أحرف كبيرة، `_`، شرطة بادئة، نقطة، فارغ، 64/63/1 حرفاً، المحجوزات الثلاثة، التفرد، NOT NULL، `tenant_code` لم يتغير، لا GRANT، tenant_admin لا يعدّله) · البحث (الـslug نفسه في Tenantين ← حسابان بلا تصادم؛ `tenant_code` وصيغته الصغيرة ليسا سياقاً؛ host الـTenant بلا طالب؛ مدرسة مؤرشفة/غير موجودة، Tenant موقوف/غير موجود ← لا شيء؛ OTP ونتيجة كلمة المرور في سياق غير صالح لا تمسّان الحساب) · `bootstrap_tenant` (محجوز مرفوض، الـlabel يُخزَّن، idempotent، label آخر ← conflict، صف التدقيق يحمله) · البنية (EXECUTE بلا نسخ قديمة، المالك R2، لا دالة تبحث بـ`tenant_code`، **لا سياسة RLS تقرأ `host_label`**، ولا دالة غير المحلّل و`bootstrap_tenant`، وكل بحث دخول يمر بالمحلّل الوحيد).

الملفات 03–29 حُدِّثت لحقيقة ما بعد M30: `host_label` في fixtures الـTenant، ونداءات الدخول بالـlabel (24، 26، 27)، وتوقيع `bootstrap_tenant` (20، 22).

### 3.3 pytest `test_host_context.py` (87)

| المجموعة | يثبت |
|---|---|
| القواعد | المتجهات (hosts، origins محلياً وإنتاجياً)؛ الأصل الأساسي الفاسد يُرفض؛ الأصل إلزامي؛ قيد DB = المحلل |
| CORS | الأشكال الثلاثة مسموحة (preflight + بسيط، `Vary: Origin`)؛ الشبيهات مرفوضة: `evil-localhost`، `localhost.evil.com`، `school-a.dev.localhost.evil.com`، الأصل العاري، `api`، مخطط/منفذ آخر، ثلاثة labels، `*`، `null` |
| لا context drift | 4 مسارات × 3 أشكال (`school`، `tenant`، `school_id`+`tenant_id`) ← `422 extra_forbidden`؛ الـschemas بلا حقول سياق و`additionalProperties: false` |
| مصدر السياق | عقد `login_context` (المدرسة، الـTenant، المنصة ← None، الغياب ← None)؛ الطالب من host مدرسته فقط — host الـTenant، المنصة، بلا Origin، أصل أجنبي، **`Host` بلا Origin**، منفذ آخر ← الرد العام |
| بلا سياق | OTP ← `202` بلا رسالة؛ verify وكلمة المرور ← `401` |
| الـslug نفسه | Tenant B بمدرسة `school-a` وموظف **بالبريد نفسه**: كل host يصل إلى حسابه وحده (`sub` مختلف)، وكلمة مرور أحدهما على host الآخر ← الرد العام |
| سياق غير صالح | مدرسة مؤرشفة، مدرسة غير موجودة، Tenant غير موجود، Tenant موقوف ← **الرد نفسه تماماً ككلمة مرور خاطئة**؛ host الـTenant يبقى صالحاً؛ OTP بسياق مؤرشف لا يرسل |
| ليس تفويضاً | سكرتير SA يدخل من host المدرسة SB: `sub` نفسه، و`/schools/SB/students` ← 404، و SA ← 200، و capabilities — **مطابقة تماماً** للدخول من host الـTenant؛ طلبات البيانات بأي Origin ← الرد نفسه بايتاً ببايت |
| حارس بنيوي | `headers.get(` في `deps.py` و`security.py` فقط؛ `login_context` في مساري الدخول وحدهما؛ `.context(` في `deps.py` و CORS فقط |

وحُدِّثت اختبارات الدخول القائمة (D1–D4، E2E الخلفية، F1) إلى `Origin` بدل الجسم — بلا تغيير في ما تثبته.

### 3.4 Vitest (77)

`hostContext.test.ts` (المتجهات + السياق من host الصفحة)؛ `hostUi.test.tsx` (host غير معروف: صفحة ثابتة **ولا `fetch`**؛ المنصة: دخول الإدارة وحده بلا «عودة»؛ الـTenant: الموظف وحده + المعرّف؛ المدرسة: الثلاثة + المعرّفات)؛ `guards.test.ts` (قارئو السياق قائمة مغلقة؛ أجسام الدخول بلا tenant/school؛ **لا بقايا أداة التطوير**)؛ `buildGuard.test.ts` (بلا نطاق/نطاق فاسد ← فشل البناء).

### 3.5 Playwright (21) — hosts حقيقية تحت `*.localhost`

كل الأدوار على hosts صحيحة (المنصة `admin`، `tenant_admin` و`group_manager` على host الـTenant، الموظفون على `school-a.dev`)؛ ولي الأمر A/B/C على hosts مدارس أبنائهم (C على `standalone.dev` لا يتلقى رمزاً)؛ الطالب على `school-a.dev`. و`host.spec.ts`: host غير معروف (أربعة أشكال) ← صفحة ثابتة **وصفر طلبات** إلى FastAPI/Supabase؛ المنصة ← دخول الإدارة وحده؛ الـTenant ← الموظف وحده؛ المدرسة ← الثلاثة؛ **سكرتير SA على host المدرسة SB ← العرض SB والبيانات SA نفسها، لا طالب SB**؛ الـTenant من الـhost (label آخر ← الرد العام)؛ الجلسة لكل host.

### 3.6 الضوابط السلبية

| الطبقة | العطب المؤقت | النتيجة |
|---|---|---|
| DB | `login_context` بلا شرط المدرسة | 4 تفشل (مؤرشفة، غير موجودة، OTP، نتيجة كلمة المرور) |
| DB | البحث بـ`tenant_code` | 10 تفشل |
| DB | تجاهل إيقاف الـTenant | 2 تفشل |
| API | الـschemas تقبل حقولاً زائدة | 13 تفشل (drift + الـschemas) |
| API | CORS `"localhost" in origin` | 9 تفشل |
| API | `Host` بديلاً عن Origin الغائب | 1 تفشل |
| API | host المنصة سياق دخول | 1 تفشل (عقد `login_context`) |
| API | عدم فحص المحجوزات / لاحقة غير مرسَّخة | 7 / 4 تفشل |
| Web | لاحقة غير مرسَّخة / المحجوزات | 1 / 6 تفشل |
| Web | بلا بوابة الـhost غير المعروف | 1 تفشل |
| Web | كل النماذج على host الـTenant | 1 تفشل |
| Web | tenant في جسم الدخول | 1 تفشل |
| Web | تجاوز من التخزين المحلي | 1 تفشل |

**دفاع بطبقتين (ملاحظة صادقة):** حذف فحص «الطالب من host مدرسة فقط» في FastAPI لا يُفشل أي اختبار — لأن DB لا تجد طالباً بلا مدرسة سياق (pgTAP `st.no_school`)؛ السلوك الخارجي واحد. الفحص في FastAPI خط أول يمنع نداء DB بلا معنى.

---

## 4. ملاحظات

- **النمط المعتمد لـ`host_label` يقبل شرطة ختامية** (`tenant-`) — ليست label DNS صالحاً (RFC 1123)؛ وكذلك `schools_slug_chk` القائم. لم يُغيَّر (النمط معتمد نصاً)؛ إن أُريد تشديده فقرار مستقل وmigration جديدة.
- **`schools.slug` قابل للتعديل** من المدرسة (سجل §4.6 منذ M20) — تغييره يغيّر host المدرسة؛ لا شيء في F3 يعتمد على ثباته غير الروابط.
- الجلسة لكل host (تخزين المتصفح لكل أصل) — الانتقال بين hosts يبدأ بلا جلسة.
- التطوير: `npm run dev` ثم `http://school-a.dev.localhost:5173` (Chromium/Edge يحلّان `*.localhost`)؛ الـAPI: `API_CORS_ORIGIN_BASE=http://localhost:5173`.

**خارج F3 (بقرار):** نقطة عامة لاسم المدرسة؛ النطاقات المخصصة لكل Tenant؛ DNS/TLS/CDN والنشر؛ سياق Flutter؛ **أي استعمال للسياق في التفويض (ممنوع)**.
