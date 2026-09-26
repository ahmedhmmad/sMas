# Gate F2 — المصادقة

**الحالة:** D1 ✅ منفذ (M24 + FastAPI) — بانتظار المراجعة · D2 ⏳ آلية مقترحة (§3) بانتظار التأكيد · D3 🔬 Spike · D4 ⚠️ دلالات A/B/C (§5)
**الترتيب المعتمد:** M24 → D1 → D2 → D3 Spike → D3 → D4 → E2E لكل الأدوار

---

## 1. القرارات (2026-09-26)

| # | القرار | الحالة |
|---|---|---|
| **D1** | Student Auth identity = **A**: `auth.users.id = student_id` (UUID يولده العميل، مفتاح الـSaga)؛ بريد Auth `student_id@students.smas.invalid` لا يراه الطالب؛ الدخول بـOfficial/Temporary ID يُحَل في FastAPI داخل نطاق الهوية؛ Temporary ← Official لا يغيّر هوية Auth؛ لا اعتماد على `temporary_id` لإنشاء الحساب. دالة lookup ضيقة قبل JWT لا تكشف tenant/school/بيانات الطالب ولا تختلف بين موجود وغير موجود، مع rate limiting — **M24** | ✅ |
| **D2** | First-login password change = **DB/RLS boundary**: أثناء `pending` ترجع `current_tenant_id()` و`current_profile_id()` NULL؛ التغيير عبر Supabase Auth بجلسة المستخدم؛ **انتقال حالة موثوق** — لا عمليتان منفصلتان تسمحان بحالة غير متسقة | ✅ القرار — الآلية §3 |
| **D3** | Tenant users (Guardian/Staff) = **synthetic identity per tenant account** (ii): لا `guardian phone → auth.users.phone` ولا `staff email → auth.users.email` كهوية عالمية؛ الهاتف/البريد الحقيقي في جدول النطاق. **Tenant isolation أهم من native identity.** | ✅ القرار |
| D3 | آلية الجلسة/OTP | 🔬 **Spike إلزامي قبل التنفيذ** (§4) |
| **D4** | سياسة first-login لولي الأمر تُحدَّد **حسب المدرسة المستهدفة أثناء الدخول/الـonboarding**، لا حسب المدرسة التي أنشأت الحساب | ⚠️ دلالات A/B/C قبل التنفيذ (§5) |

---

## 2. D1 — المنفذ

### 2.1 قاعدة البيانات — M24 `student_login`

| العنصر | |
|---|---|
| `app.resolve_student_login(tenant_code, school_slug, identifier) → uuid` | SECURITY DEFINER (`app_owner`)، `search_path` مثبت؛ **EXECUTE لـ`service_role` وحده** (لا `authenticated`، ولا `anon` — لا يصل حتى إلى schema `app`) |
| المدخل | `tenant_code` + `slug` — **الـslug فريد داخل الـTenant فقط** (`schools_tenant_slug_uq`)، فالمدرسة وحدها لا تكفي؛ F3 يحملهما من الـsubdomain |
| المخرج | معرّف الحساب أو NULL — لا شيء غيره |
| NULL واحد لكل فشل | tenant مجهول/موقوف، مدرسة مجهولة/مؤرشفة، مجموعة أخرى، معرّف مجهول، طالب `withdrawn`/`archived`، **تطابق مزدوج** (Official لطالب = Temporary لآخر)، معرّف فارغ/NULL |
| التطبيع | `trim`؛ `tenant_code` و بادئة `TMP-` بأحرف كبيرة، الـslug صغيرة |
| **D1 مفروض في DB** | `provision_student` (CREATE OR REPLACE بنص M22 + فحص): معرّف الحساب ≠ معرّف الطالب ⇒ `22023` قبل أي كتابة |

### 2.2 FastAPI

| المسار / الملف | |
|---|---|
| `POST /students` (`students.py`) | Saga §5.4: Admin API (`id = student_id`، بريد D1، كلمة مرور عشوائية؛ استئناف إن وُجد) ← `provision_student` **بـJWT المستدعي** ← فشل ⇒ حذف تعويضي (فقط إن أُنشئ في هذه المحاولة) ← كلمة المرور الأولية = المعرّف (Official أو Temporary المولَّد داخل المعاملة) |
| `POST /auth/student/login` (`student_login.py`) | (tenant، مدرسة، معرّف، كلمة مرور) ← `resolve_student_login` تحت `service_role` ← Supabase Auth password grant ← الجلسة كما يصدرها Supabase Auth: `access_token`, `refresh_token`, `expires_in`, `token_type` فقط. **لا JWT يُصنع في FastAPI** |
| فشل موحّد | `401 invalid_credentials` لكل الأسباب؛ وعند فشل البحث يُستدعى Supabase Auth ببريد عشوائي (زمن متقارب) |
| حد المحاولات | 10 / 5 دقائق لكل (tenant، مدرسة، معرّف) ولكل عنوان ⇒ `429` بالشرط نفسه للموجود وغير الموجود |
| `auth_admin.py` | **الملف الوحيد الذي يقرأ `SUPABASE_SECRET_KEY`** (Admin API) — مفتاح Auth لا دور قاعدة بيانات |
| مواضع `service_role` (دور DB) | موضعان مسمّيان: `audit.py` (F4) و`student_login.py` (D1) — يحرسهما اختبار |

### 2.3 الاختبارات

**pgTAP `24_student_login` — 26/26:** الحل بالـOfficial والـTemporary، مدرسة أخرى في المجموعة نفسها (نطاق واحد)، المعرّف نفسه في نطاق/Tenant آخر، الـslug نفسه في Tenant آخر، 11 سبب فشل ⇒ نتيجة واحدة، الامتيازات والملكية والنوع. **`22_provisioning`** (54): D1 مرفوض قبل الكتابة؛ حالات الـconflict وإعادة استعمال الحساب أُعيدت صياغتها على D1.

**pytest `test_student_login` — 20** (المجموع 68/68):

| | |
|---|---|
| Saga | هوية D1 (`id`، البريد)، idempotency، **تعويض** عند رفض DB (المعلم)، شعبة خارج النطاق، معرّف أقصر من حد كلمة المرور يُرفض قبل أي كتابة |
| الدخول | Temporary ID، Official ID، طالب الـseed؛ `/me` بعد الدخول = الطالب في الـTenant الصحيح؛ Temporary ← Official يبقي هوية Auth ويدخل بالمعرّف الجديد |
| الفشل الموحّد | كلمة مرور خاطئة، معرّف/مدرسة/tenant مجهول، البريد الاصطناعي كمعرّف، نطاق هوية آخر — `401` متطابق |
| الحد | 11 محاولة ⇒ `429` للموجود وغير الموجود بالعدد نفسه |

**الضوابط السلبية (كلها تُفشل الاختبارات):** (a) خطأ مميز لمعرّف غير موجود ← 6؛ (b) بلا حذف تعويضي ← 2؛ (c) بلا حد محاولات ← 2؛ (d) الـSaga تمرر معرّف حساب مختلفاً ← 6 (DB ترفض — D1 مفروض في قاعدة البيانات لا في FastAPI وحده).

### 2.4 ملاحظات

| # | |
|---|---|
| N1 | **حالة الطالب:** `active` وحدها تدخل؛ `withdrawn` لا تدخل — افتراض محافظ للمراجعة |
| N2 | حد المحاولات في ذاكرة العملية؛ تعدد نسخ الخدمة يحتاج مخزناً مشتركاً — مع البنية/الإنتاج |
| N3 | الـseed (E5) صار على شكل D1: حساب الطالب = معرّفه، بريده اصطناعي، ويدخل بالـOfficial ID |
| N4 | حتى D2: كلمة المرور الأولية (= المعرّف) تعمل فوراً بلا إجبار تغيير — D2 يغلق ذلك |

---

## 3. D2 — الآلية المقترحة (بانتظار التأكيد قبل التنفيذ)

**المشكلة:** تغيير كلمة المرور يتم في Supabase Auth (HTTP) خارج أي معاملة لنا؛ رفع `pending` بعده خطوة ثانية قد تفشل.

**الحل المقترح: الانتقال يحدث داخل معاملة Supabase Auth نفسها.**

```text
الحالة (auth_identities — بلا سياسة عميل، G10):  issuing → pending → active

1. الإنشاء/إعادة الضبط (معاملة DB):             credential_state = 'issuing'       ← السياق NULL فوراً (fail closed)
2. Admin API يضع كلمة المرور المؤقتة
3. arm (معاملة DB):                               'pending' + لقطة encrypted_password
4. المستخدم يغيّر كلمته بجلسته (Supabase Auth)
     └─ trigger AFTER UPDATE OF encrypted_password ON auth.users
        (في معاملة Supabase Auth نفسها):          الـhash ≠ اللقطة ⇒ 'active'        ← ذري مع التغيير
```

- `current_profile_id()` / `current_tenant_id()` ترجعان NULL ما لم تكن الحالة `active` — نمط M21b في الجذر؛ سياق المنصة لا يتأثر.
- **سباق:** تغيير المستخدم أثناء `issuing` لا يرفع الحالة؛ الـarm اللاحق يلتقط الكلمة المؤقتة ⇒ تبقى `pending`. فشل بين 2 و3 ⇒ تبقى `issuing` (مغلقة) وإعادة المحاولة تكمل.
- Supabase Auth يرفض الكلمة نفسها (`same_password`) ⇒ لا «تغيير» شكلي.
- **ما يحتاج تأكيدك:** أول **trigger على `auth.users`** (جدول يملكه Supabase Auth) — يُثبت أولاً كتحقق V9 بنمط M00 أن تغيير كلمة المرور عبر Supabase Auth يطلقه في معاملته.
- **من يبدأ `issuing`:** الطالب (كلمة مرور أولية = المعرّف). الموظف وولي الأمر: حسب D4 (نمط «كلمة مرور مؤقتة من المدرسة») — الافتراضي `active` حتى يُحسم.

---

## 4. D3 — Spike (قبل أي تنفيذ)

الدورة الكاملة: `real phone → tenant-scoped account → OTP → Supabase Auth session → JWT → FastAPI / PostgREST → auth.uid() → tenant/profile context → RLS`، ومعايير النجاح الثمانية:

1. الهاتف نفسه ينشئ حساباً في Tenant A وفي Tenant B
2. Tenant A لا يعرف أن الهاتف موجود في Tenant B
3. OTP لـA لا يعمل على B
4. جلسة A لا تصل إلى بيانات B
5. إلغاء/قفل الحساب يعمل
6. الدخول بكلمة المرور يعمل للحساب نفسه عند الحاجة
7. لا `service_role` في المتصفح
8. لا JWT تقبله قاعدة البيانات خارج Supabase Auth ومفاتيح التوقيع المعتمدة

---

## 5. D4 — دلالات A/B/C كما في PLAN

**النص الوحيد الذي يعرّف الأنماط** (`PLAN_v3.md` المرحلة 9، السطر 412):

> «عند أول دخول، تدعم المدرسة ثلاثة أنماط قابلة للإعداد: إجبار إنشاء كلمة مرور بعد OTP، السماح بـOTP فقط مع كلمة مرور اختيارية، أو كلمة مرور مؤقتة من المدرسة مع إجبار تغييرها.»

و§7.8 وسجل 2026-09-17 يسميانها «A/B/C» **دون ربط الحروف بالأنماط**؛ و`ROLE_PERMISSION_SEED` §4 يضع الإعداد تحت `security.manage` على مستوى المدرسة.

| الترتيب في النص | النمط | الحرف |
|---|---|---|
| 1 | OTP ← إجبار إنشاء كلمة مرور | A؟ |
| 2 | OTP فقط، كلمة مرور اختيارية | B؟ |
| 3 | كلمة مرور مؤقتة من المدرسة ← إجبار التغيير | C؟ |

**الحروف استنتاج من الترتيب لا نص** — تحتاج تأكيداً. غير معرَّف أيضاً في PLAN: ما يحدث في الدخول التالي بعد أول دخول (النمط 2: هل يبقى OTP فقط؟)، والنمط الافتراضي لمدرسة لم تضبطه.
