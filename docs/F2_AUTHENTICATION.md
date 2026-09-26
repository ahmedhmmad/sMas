# Gate F2 — المصادقة

**الحالة:** D1/M24 🔒 (CI `3f4ae05`) · D2/M25 🔒 (CI `62c76b1`) · D3 ✅ **منفذ — M26** (§4.2) بانتظار المراجعة · D4 ⚠️ دلالات A/B/C (§5)
**الترتيب المعتمد:** M24 → D1 → D2 → D3 Spike → D3 → D4 → E2E لكل الأدوار

---

## 1. القرارات (2026-09-26)

| # | القرار | الحالة |
|---|---|---|
| **D1** | Student Auth identity = **A**: `auth.users.id = student_id` (UUID يولده العميل، مفتاح الـSaga)؛ بريد Auth `student_id@students.smas.invalid` لا يراه الطالب؛ الدخول بـOfficial/Temporary ID يُحَل في FastAPI داخل نطاق الهوية؛ Temporary ← Official لا يغيّر هوية Auth؛ لا اعتماد على `temporary_id` لإنشاء الحساب. دالة lookup ضيقة قبل JWT لا تكشف tenant/school/بيانات الطالب ولا تختلف بين موجود وغير موجود، مع rate limiting — **M24** | ✅ |
| **D2** | **= B** (§3.2) — First-login password change = **DB/RLS boundary**: أثناء `pending` ترجع `current_tenant_id()` و`current_profile_id()` NULL؛ التغيير عبر Supabase Auth بجلسة المستخدم؛ **انتقال حالة موثوق** — لا عمليتان منفصلتان تسمحان بحالة غير متسقة | ✅ B — M25 |
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
| N1 | **حالة الطالب:** `active` وحدها تدخل؛ `withdrawn` لا تدخل — **سلوك مقصود (معتمد 2026-09-26)** |
| N2 | حد المحاولات في ذاكرة العملية؛ تعدد نسخ الخدمة يحتاج مخزناً مشتركاً — مع البنية/الإنتاج |
| N3 | الـseed (E5) صار على شكل D1: حساب الطالب = معرّفه، بريده اصطناعي، ويدخل بالـOfficial ID |
| N4 | ~~حتى D2: كلمة المرور الأولية تعمل فوراً~~ — **أُغلق في M25**: الحساب pending حتى التغيير والتفعيل |

---

## 3. D2 — first-login password change

> **الاقتراح الأول أدناه (trigger على `auth.users`) مرفوض بنتائج V9 (§3.1). المعتمد والمنفذ: الخيار B (§3.2).**

### 3.0 الاقتراح الأول (مرفوض)

> **الهدف الأمني:** لا مسار يجعل الحساب مفتوحاً قبل استيفاء شرط first-login. الذرية ليست هدفاً بأي ثمن: إن لم يعطِ `auth.users` إشارة موثوقة تميّز تغيير first-login عن إعادة ضبط المدير أو إعادة الكلمة نفسها، فالبديل: `pending → تغيير عبر Supabase Auth → تفعيل متحكَّم به → active`، وأي فشل في التفعيل يُبقي الحساب مغلقاً ويقبل إعادة المحاولة.
>
> **مخاوف معلنة على الاقتراح أدناه:** hash جديد لا يعني كلمة جديدة (الكلمة نفسها تُنتج hash آخر)؛ وإعادة ضبط المدير تغيّر `encrypted_password` أيضاً فقد تفتح الحساب. V9 يختبر الحالات الثماني قبل أي قرار.

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

### 3.1 نتائج V9 (2026-09-26) — `spikes/v9/`

Spike محلي (ليس migration): نموذج الآلية المقترحة **بحذافيرها** + سجل لكل إطلاق + بوابة الجذر المؤقتة؛ الحالات عبر Supabase Auth الحقيقي (`run_v9.py`، `run_v9b.py`)؛ أُزيل كله بـ`db reset`.

| # | الحالة | النتيجة | الحكم على الآلية المقترحة |
|---|---|---|---|
| 1 | إنشاء طالب ← `pending` | `pending`؛ كتابة الـSaga لكلمة المرور أثناء `issuing` لم تغيّر الحالة | ✅ |
| 2 | الوصول أثناء `pending` | جلسة Auth تصدر، لكن `/me` بلا profile و PostgREST `students` = 0 صفوف | ✅ البوابة في الجذر تعمل |
| 3 | الطالب يغيّر إلى كلمة جديدة | `200`؛ الـtrigger أُطلق ⇒ `active`؛ الوصول بالجلسة نفسها؛ المؤقتة لم تعد تعمل | ✅ |
| 4 | الطالب «يغيّر» إلى المؤقتة نفسها | `422 same_password` — Supabase Auth يرفض قبل أي كتابة؛ لا إطلاق؛ يبقى `pending` | ✅ |
| **5a** | **المدير يضع المؤقتة نفسها أثناء `pending`** | `200`؛ hash جديد ⇒ **`active`**؛ المؤقتة تدخل وتقرأ البيانات | ❌ **يفتح الحساب** |
| **5b** | المدير يضع مؤقتة أخرى أثناء `pending` | **`active`** | ❌ **يفتح الحساب** |
| 5c | إعادة ضبط المدير لحساب `active` (خارج مسار issuing) | يبقى `active`؛ كلمة المدرسة تعمل | ⚠️ إعادة الضبط لا تعيد الإجبار ما لم تمر بمسار متحكَّم به |
| 6a | تغيير مرفوض (`weak_password`) | لا كتابة، يبقى `pending` | ✅ |
| 6b | فشل مُفتعل **داخل** معاملة Supabase Auth بعد الكتابة | `500`؛ يبقى `pending`؛ المؤقتة صالحة والجديدة لا؛ لا أثر للمحاولة | ✅ ذري |
| 7 | حساب `active` + دخول/تعديل بيانات أخرى | لا إطلاق؛ تغيير لاحق للكلمة يبقيه `active` | ✅ |
| 8a | تغييران متزامنان من الطالب | كلاهما `200`، `active`، كلمة واحدة فقط تعمل، المؤقتة لا | ✅ متسق |
| 8b | إعادة ضبط المدرسة (issuing←set←arm) مع تغيير الطالب، 10 مرات | 0 مرة `active` مع كلمة المدرسة | ✅ في المسار المتحكَّم به |

**الإشارة في `auth.users`: لا توجد.** تغيير الطالب وكتابة المدير متطابقان: الأعمدة `[encrypted_password, updated_at]`، `session_user = supabase_auth_admin`، `application_name` فارغ. **الآلية المقترحة (hash ≠ اللقطة) مرفوضة** — 5a/5b يثبتان مخاوف المراجعة: أي كتابة إدارية (Admin API، الـDashboard) تفتح الحساب.

**الإشارة في سجل تدقيق Supabase Auth (`auth.audit_log_entries`) — V9b:**

| | النتيجة |
|---|---|
| b1 | تغيير الطالب يكتب `user_updated_password` بفاعل = **الطالب نفسه**، **في معاملة كتابة كلمة المرور نفسها** (`xid` واحد) |
| b2 | كتابة المدير (الكلمة نفسها أو غيرها) تكتب `user_modified` بفاعل `service_role` — **لا `user_updated_password` أبداً** |
| b3 | الكلمة نفسها ⇒ رفض ولا صف تدقيق |
| b4 | فشل داخل المعاملة ⇒ لا يبقى صف `user_updated_password` (يُلغى معها) |

**الخيارات بعد V9 — للقرار، لا migration قبله:**

| | الآلية | الإشارة | الذرية | ما يعتمد عليه |
|---|---|---|---|---|
| **B (مقترح)** | **تفعيل متحكَّم به**: بعد التغيير يستدعي العميل FastAPI ← دالة DB: `pending` + يوجد `user_updated_password` بفاعل = الحساب نفسه **بعد لحظة الـarm** ⇒ `active` | سجل Auth | خطوتان — **fail-closed**: فشل التفعيل يبقيه مغلقاً ويُعاد (الدخول التالي يعيد المحاولة) | صيغة سجل Auth وكتابته في قاعدة البيانات؛ **قراءة فقط** من schema `auth` |
| A | trigger على `auth.audit_log_entries` (`user_updated_password` بفاعل = الحساب) ⇒ `active` | سجل Auth | ذري (b1، b4) | الاعتماد نفسه + **trigger على جدول يملكه Supabase Auth** |
| C | تفعيل متحكَّم به بشرط «الكلمة ≠ المعرّف» (`crypt` في DB) | مقارنة الكلمة | خطوتان | يُهزم بكتابة إدارية لكلمة مؤقتة أخرى (نظير 5b) — **أضعف** |

**لماذا B:** يحقق الهدف الأمني (لا مسار يفتح الحساب قبل شرط first-login) بإشارة مُثبتة تميّز الطالب عن المدير، دون trigger على جداول Supabase Auth؛ والخطوتان fail-closed وقابلتان للإعادة. **في A وB معاً:** إن توقفت كتابة سجل Auth في قاعدة البيانات (إعداد لدى المزود أو تغيّر صيغته في ترقية) فلا تفعيل ⇒ الحسابات تبقى مغلقة (آمن لا مفتوح) — يُحرس باختبار CI يفشل عند تغيّر الصيغة، ويُتحقق من إعداد هدف الإنتاج.

**ما لا تحله أي آلية:** إعادة ضبط خارج المسار المتحكَّم به (Dashboard/Admin API مباشرة) لحساب `active` لا تعيد الإجبار (5c). الإجبار بعد إعادة الضبط = مسار إعادة ضبط متحكَّم به (issuing ← الكلمة ← arm ← pending)، وإعادة الضبط الخارجية عملية مشغّل تُضبط إجرائياً.

### 3.2 المعتمد والمنفذ — الخيار B (M25)

**القرار (2026-09-26):** **D2 = B (2026-09-26):** `pending → تغيير الكلمة عبر Supabase Auth → FastAPI → app.activate_first_login() → active`؛ أي فشل ⇒ يبقى pending (fail closed). الدالة تتحقق من الشروط كلها: pending؛ الحساب = auth.uid()؛ حدث `user_updated_password` في سجل Supabase Auth بفاعل = الحساب نفسه بعد لحظة إصدار الكلمة المؤقتة (EXISTS لا «آخر صف»)؛ `user_modified` لا يُقبل؛ idempotent؛ مُدقَّق كـ`activate_first_login`؛ لا مسار بلا auth.uid(). لا trigger على `auth.users` ولا `auth.audit_log_entries`. عقد V9b اختبار CI كـ**Supabase Auth integration assumption**. Admin reset → force change = مسار متحكَّم به مستقل (5c)

**قاعدة البيانات — M25 `first_login_credential`:**

| العنصر | |
|---|---|
| `auth_identities` | `credential_state` (`active`\|`pending`، افتراضي `active`)، `credential_issued_at`، `credential_activated_at`؛ 3 قيود مسمّاة (DD §2.0)؛ بلا سياسة عميل ولا منح (G10)؛ T7 يدقّق كل انتقال |
| بوابة الجذر | `current_profile_id()`/`current_tenant_id()` = NULL ما لم يكن `credential_state = 'active'` — نمط M21b؛ PostgREST مغلق أيضاً |
| `provision_student` | الحساب يولد `pending` (نص M24 + سطر) |
| `app.arm_first_login(uid)` | بعد كتابة الكلمة المؤقتة عبر Admin API، بـJWT المستدعي (`student.create` + الطالب في نطاقه): لحظة الإصدار = `auth.users.updated_at` — **ساعة Supabase Auth نفسها** التي تختم سجل التدقيق (لا انحراف ساعات بين خادمين)؛ مرة واحدة (إعادة الإصدار مسار 5c) |
| `app.activate_first_login()` | بلا معاملات؛ الشروط التسعة؛ `EXISTS` على كل الصفوف المؤهلة؛ يعيد `active` أو `pending` |
| قراءة schema `auth` | **استثناء R2 موسّع بقرار:** دالتان ملك `postgres` (`search_path` فارغ، EXECUTE لـ`app_owner` وحده) تعيدان لحظة وقيمة منطقية فقط — `app_owner` لا يصل إلى `auth` و`postgres` لا يملك grant option عليه |

**FastAPI:** الـSaga تستدعي `arm_first_login` بعد كتابة الكلمة الأولية (فشلها ⇒ الحساب مغلق وإعادة الطلب تكمل)؛ `POST /auth/activate` بجلسة الطالب ← `200 {"state":"active"}` أو `409 password_change_required`.

**الاختبارات:**

| | |
|---|---|
| pgTAP `25_first_login` — 36 | القيود بأسمائها؛ البوابة (NULL + RLS صفر)؛ arm (الصلاحية، النطاق، اللحظة من `auth.users`، مرة واحدة)؛ activate: service_role بلا EXECUTE، بلا JWT، حساب منصة، بلا حدث، **لم يُصدَر**، **حدث قبل الإصدار**، `user_modified` بـservice_role، `user_updated_password` بفاعل آخر، **`user_modified` بفاعل الحساب نفسه**، حدث حساب آخر؛ النجاح وسط صفوف غير صالحة قبله وبعده؛ تدقيق `activate_first_login:tenant_user`؛ idempotent؛ ملكية الدوال ومنحها |
| pytest `test_first_login` — 8 | حساب جديد pending ومغلق عبر FastAPI **و PostgREST**؛ التفعيل قبل التغيير 409؛ تغيير ← تفعيل ← السياق يفتح وصفه وحده، المؤقتة انتهت؛ **V9 5a** (المدير يضع المؤقتة أثناء pending) لا يفتح؛ same/weak password لا يفتحان؛ فشل arm ⇒ مغلق حتى مع تغيير صالح؛ الموظفون لا يتأثرون |
| pytest `test_auth_contract` — 5 | **عقد V9b (Supabase Auth integration assumption):** تغيير المستخدم ⇒ `user_updated_password` بفاعله؛ كتابة المدير ⇒ `user_modified` بـservice_role فقط؛ same/weak ⇒ لا إشارة؛ الحدث بعد لحظة الإصدار |

**الضوابط السلبية — كلها تُفشل الاختبارات:** الإشارة بأي `action` ← pgTAP 2 + pytest 4؛ بلا شرط الزمن ← pgTAP 2؛ بأي فاعل ← pgTAP 5؛ بلا بوابة الجذر ← pytest 1؛ الـSaga بلا arm ← pytest 1.

**ملاحظات:**

| # | |
|---|---|
| N5 | **Performance observation (معتمدة):** البحث في `auth.audit_log_entries` بلا فهرس على `payload` — مسح مرة لكل تفعيل لا لكل طلب. عند اختيار بيئة الإنتاج وبيانات حقيقية يُقاس زمن `activate_first_login()` وحجم الجدول؛ إن أثّر فيُبحث عن تحسين لا يعدّل جداول Supabase بطريقة غير مدعومة. لا فهرس الآن بافتراض |
| N6 | طالب الـseed (E5) `pending` كأي طالب — **معتمد**: الـseed يمثّل lifecycle الطالب الحقيقي؛ اختبارات E5/E2E التي تحتاج طالباً مصادَقاً تُتم first-login أولاً |
| N7 | إن توقفت كتابة سجل Supabase Auth في قاعدة البيانات أو تغيّرت صيغته: لا تفعيل ⇒ الحسابات تبقى مغلقة، و`test_auth_contract` يفشل في CI — يُتحقق من إعداد هدف الإنتاج |
| N8 | Admin reset → force change: خارج D2 (قرار 5c) — مسار متحكَّم به بحالة صريحة إن طُلب |

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

### 4.1 نتائج الـSpike (2026-09-26) — `spikes/d3/` ✅ المعايير الثمانية

محلي (ليس migration)، على seed E5 + Tenant ثانٍ؛ أُزيل بـ`db reset`. «الخادم» وحدة Python تمثّل FastAPI؛ المرسل مرسل اختبار.

**آلية الجلسة المُثبتة — لا JWT يُصنع خارج Supabase Auth:**

```text
(tenant، هاتف) ──resolve──► حساب ولي الأمر في ذلك الـTenant (أو لا شيء — الاستجابة نفسها)
      │ OTP: رمز 6 أرقام، hash + salt، صلاحية 5 دقائق، محاولات، استهلاك مرة واحدة
      ▼
Admin generate_link (type=magiclink، لا يُرسل بريداً — البريد اصطناعي `<guardian_id>@guardians.smas.invalid`)
      ▼ hashed_token (يبقى في الخادم)
POST /auth/v1/verify {type: magiclink, token_hash}   ← Supabase Auth يصدر الجلسة
      ▼
access_token (ES256، kid من JWKS، sub = الحساب، amr = otp) + refresh_token ← للعميل حقول الجلسة فقط
```

| # | المعيار | النتيجة |
|---|---|---|
| 1 | الهاتف نفسه ⇒ حساب في A وحساب في B | ✅ الإنشاءان `200`؛ `auth.users.phone` فارغ في الاثنين (الهاتف في `guardians` فقط)؛ حسابان مختلفان |
| 2 | A لا يعرف وجود الهاتف في B | ✅ طلب OTP في A لهاتف موجود في B فقط = الاستجابة نفسها (`sent`)، **ولا رسالة تُرسل**؛ الإنشاء في B لم يُمنع قط (لا `phone_exists`) |
| 3 | رمز A لا يعمل على B | ✅ مرفوض في B (قبل طلب B وبعده)؛ مقبول في A ⇒ جلسة `sub` = حساب A؛ الرمز لمرة واحدة؛ رمز B ⇒ حساب B |
| 4 | جلسة A لا تصل إلى B | ✅ `/me` A = DEV، B = Tenant B؛ A يرى صفه في `guardians` وحده وابنه فقط (1)، وصف/profiles B = `[]`؛ B لا يرى طلاباً ولا صف A |
| 5 | القفل/الإلغاء | ✅ 5 رموز خاطئة ⇒ `failed_login_count = 5` و`locked_until` (أعمدة Foundation موجودة في `guardians`)؛ المقفل: لا رسالة ولا قبول حتى لرمز صالح سابق. **حظر Supabase Auth** (`ban_duration`) ⇒ لا جلسة، والتجديد `400`. **profile موقوف** ⇒ جلسة تصدر لكن السياق NULL و0 صفوف |
| 6 | كلمة المرور للحساب نفسه | ✅ ولي الأمر يضع كلمته بجلسته ⇒ دخول (tenant، هاتف، كلمة) يعطي جلسة DEV؛ الكلمة نفسها على B ⇒ فشل؛ هاتف B فقط على A ⇒ فشل |
| 7 | لا `service_role` في المتصفح | ✅ ما يعود للعميل = `access_token, refresh_token, expires_in, token_type` فقط؛ لا `hashed_token` ولا `action_link` ولا `email_otp` ولا مفتاح ولا البريد الاصطناعي |
| 8 | لا JWT خارج Supabase Auth | ✅ `ES256` و`kid` ضمن JWKS؛ FastAPI يقبله؛ **رمز مزوّر بمفتاح آخر وبنفس `kid`** ⇒ FastAPI `401` و PostgREST `401`؛ HS256 ⇒ `401` في الاثنين؛ الـSpike لا يوقّع إلا هذين الرمزين المزوّرين |
| + | التجديد، إعادة الاستعمال | `refresh_token` ⇒ `200` بالـ`sub` نفسه؛ رابط الجلسة لمرة واحدة (`200` ثم `403`) |

**ما يحتاجه التنفيذ (مستخلص من الـSpike — للمراجعة قبل البدء):**

| # | البند |
|---|---|
| I1 | **migration:** جدول تحديات OTP (hash + salt، صلاحية، محاولات، استهلاك) بلا وصول عميل؛ دالة `resolve` ضيقة قبل JWT بنمط M24 (tenant + هاتف ⇒ حساب أو NULL، `service_role` وحده)؛ **تستبعد profile غير النشط** (5c: الجلسة كانت تصدر ثم يُغلق السياق — الأفضل ألا تصدر) |
| I2 | الربط بالحساب: `provision_account` القائم (M22) + حساب Auth بالبريد الاصطناعي — `auth.users.id = guardian_id`؟ (نظير D1؛ للقرار) |
| I3 | القفل: أعمدة `guardians.failed_login_count/locked_until/last_login_at` موجودة؛ تحديثها عبر دالة متحكَّم بها لا CRUD |
| I4 | **حدود معدّل Supabase Auth لكل IP:** كل استدعاءات `/verify` و password grant تخرج من خادم FastAPI ⇒ تتركز على IP واحد (محلياً `token_verifications = 30`/5 دقائق). **يمس D1 أيضاً.** محلياً لم يظهر الحد؛ **شرط إعداد في هدف الإنتاج** (الحدود أو تمرير IP العميل) |
| I5 | `generate_link` لا يخضع لحد إرسال البريد (≥ 12 رابطاً مع `email_sent = 2`/ساعة)، ويُسجَّل في سجل Supabase Auth كـ`user_recovery_requested` + `login` — **لا `user_updated_password`** ⇒ لا تداخل مع تفعيل D2 |
| I6 | الموظف بالبريد: الآلية نفسها (البريد الحقيقي في `staff`، الهوية اصطناعية) — لم يُختبر منفصلاً |
| I7 | قناة الإرسال (WhatsApp/SMS) خارج الـSpike — واجهة مرسل فقط (D4 / المرحلة 5) |

### 4.2 المعتمد والمنفذ — M26 + FastAPI

**القرار (2026-09-26):** **D3 — Tenant accounts synthetic identity (معتمد بعد الـSpike):** ولي الأمر (هاتف) والموظف (بريد): الهاتف/البريد الحقيقي في `guardians`/`staff`، وحساب Auth اصطناعي؛ الجلسة يصدرها Supabase Auth عبر Admin `generate_link` (magiclink) ثم `/verify` في الخادم — FastAPI لا يصدر JWT، والبريد الاصطناعي والـtoken_hash ورابط الجلسة والأسرار لا تصل إلى العميل. **I1:** الحساب الموقوف لا يبدأ مصادقة أصلاً (لا OTP ولا جلسة) بالرد الخارجي نفسه. **I2:** `auth.users.id = guardian_id` / `staff_id` — قاعدة موحدة مع D1: **Domain entity ID = Supabase Auth user ID**. **I4:** حدود معدّل Supabase Auth لكل IP = Production configuration dependency، لا مانع لـD3. **I6:** مسار الموظف مختبر قبل إغلاق D3. **I7:** قناة WhatsApp/SMS — المرحلة 5؛ مرسل محلي في D3

```text
tenant + (هاتف | بريد) ──otp_issue──► رمز (bcrypt في login_challenges) ──► مرسل (محلي في D3)
                        ──otp_verify──► account_id ──► Admin generate_link ──► /verify ──► جلسة Supabase Auth
                                                                                         auth.uid() = guardian_id / staff_id ──► RLS
```

**قاعدة البيانات — M26 `tenant_account_login`:**

| العنصر | |
|---|---|
| `staff` | أعمدة القفل (نظير `guardians`) + `staff_tenant_email_uq` — tenant + بريد ⇒ حساب واحد |
| `login_challenges` (الجدول 30) | bcrypt؛ صلاحية 5 دقائق؛ 5 محاولات؛ إصدار جديد يُبطل السابق؛ **بلا وصول عميل ولا T7** |
| `login_account` (داخلية) | tenant + هاتف/بريد ⇒ حساب **نشط**: الكيان `active`، الـprofile `active`، الـTenant `active` (**I1**) |
| `otp_issue` / `otp_verify` | الرمز لـFastAPI ليرسله / معرّف الحساب أو NULL؛ نجاح OTP يفك القفل (PLAN §7.8) |
| `password_login_account` / `password_login_result` | قبل الـgrant (لا مقفل) / بعده (5 إخفاقات ⇒ 15 دقيقة) |
| `provision_account` | **I2 مفروض في DB**: معرّف الحساب = معرّف ولي الأمر/الموظف (`22023`) |

**FastAPI:** `POST /accounts` (Saga: Admin API ← `provision_account` بـJWT المستدعي ← تعويض)؛ `POST /auth/otp/request` (`202` دائماً)؛ `POST /auth/otp/verify` و`POST /auth/password/login` (الجلسة أو `401 invalid_credentials`)؛ `otp_sender.py` (مرسل محلي؛ بلا قناة ⇒ `503`)؛ `auth_admin.issue_session` (الـtoken_hash لا يغادره). مواضع دور `service_role`: `audit.py`، `student_login.py`، `account_login.py`.

**الـseed (E5) على I2:** الموظفون وولي الأمر معرّف الحساب = معرّف الكيان، بريد Auth اصطناعي، والبريد الحقيقي في `staff.email`.

**الاختبارات:** pgTAP `26_account_login` — 46؛ pytest `test_account_login` — 16 (المجموع 97/97):

| | ولي الأمر | الموظف (I6) |
|---|---|---|
| حساب اصطناعي بمعرّف الكيان، بلا هاتف في `auth.users` | ✅ | ✅ |
| OTP ⇒ جلسة Supabase (ES256، kid في JWKS)، `auth.uid()` = الكيان، السياق DEV | ✅ | ✅ (بريد بأحرف مختلفة) |
| الهاتف/البريد نفسه في Tenant آخر = حساب آخر؛ رمز A لا يعمل على B؛ جلسة B لا ترى DEV | ✅ | ✅ |
| لا كشف: هاتف في B فقط / مجهول ⇒ الرد نفسه ولا رسالة | ✅ | (المحلّل نفسه) |
| I1: الموقوف لا رمز ولا جلسة ولا كلمة مرور — حتى برمز صدر قبل الإيقاف | ✅ | ✅ |
| كلمة المرور، رفضها على B، القفل بعد 5، فكه بـOTP | ✅ | ✅ |
| الرمز لمرة واحدة؛ حقول الجلسة وحدها للعميل؛ حد الطلبات متساوٍ للموجود وغير الموجود | ✅ | ✅ |

**الضوابط السلبية — كلها تُفشل الاختبارات:** verify بلا فحص الرمز ← 6؛ إرسال لحساب غير موجود ← 4؛ تسريب `hashed_token` ← 3؛ المحلّل بلا حالة الـprofile ← pgTAP 4 + pytest 2؛ المحلّل بلا الـTenant ← pgTAP 16 + pytest 10.

**للمراجعة:**

| # | |
|---|---|
| R1 | **افتراضيات:** صلاحية الرمز 5 د؛ 5 محاولات للتحدي؛ 5 إخفاقات كلمة مرور ⇒ قفل 15 د؛ الموظف يدخل بحالة `active` فقط (`on_leave` لا) |
| R2 | **تنبيه ولي الأمر والمدرسة عند القفل** (PLAN §7.8) غير منفذ — يحتاج القناة (المرحلة 5) |
| R3 | **`tenant_admin` المُقلَع** (`bootstrap_tenant`) بلا كيان `staff` ⇒ خارج D3: هويته بريد حقيقي — قرار مستقل |
| R4 | `login_challenges` بلا T7 — استثناء صريح من B7 (لا hashes في `audit_log`)؛ النتائج تُدقَّق على الكيان |
| R5 | حد المحاولات في ذاكرة العملية (كـD1)؛ وI4 (حدود Supabase Auth لكل IP) شرط إنتاج |

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
