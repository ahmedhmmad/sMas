# CLAUDE.md — دليل التنفيذ وتتبع التقدم

**المشروع:** نظام إدارة المدارس متعدد المستأجرين (Multi-Tenant SMS)
**تاريخ الإنشاء:** 2026-09-22
**آخر تحديث:** 2026-09-23
**المرحلة الحالية:** المرحلة 1 — الأساس (Foundation) / **Gate C — Foundation Migrations** (M01–M05 ✅؛ التالي M06 `permission_catalog_tables`)

---

## 0. كيف تعمل داخل هذا المستودع

### المراجع وترتيب الأولوية عند التعارض

| # | المرجع | الدور |
|---|---|---|
| 1 | `docs/PLAN_v3.md` §7.16–7.18 + §10 Implementation Lock | القرارات النهائية المقفلة — لا يُعاد فتحها |
| 2 | `docs/PLAN_v3.md` §0 و§3 | قواعد العمل والقواعد الإلزامية للكود |
| 3 | `docs/ERD_CORE_v1.md` | النموذج المنطقي المعتمد للـFoundation |
| 3 | `docs/AUTHORIZATION_MATRIX_v1.md` | نموذج التفويض المعتمد — كتالوج Permissions وقواعد Scope والتفويض والاختبارات |
| 3 | `docs/DATA_DICTIONARY_v1.md` | الأعمدة والقيود والفهارس — المرجع الملزم قبل أي migration |
| 3 | `docs/ROLE_PERMISSION_SEED_v1.md` | **المصدر الرسمي لكتالوج الصلاحيات** (73) وخريطة الأدوار |
| 3 | `docs/RLS_MODEL_v1.md` | نص الدوال المساعدة وكل السياسات |
| 3 | `docs/DB_IMPLEMENTATION_SPEC_v1.md` | **مواصفة التنفيذ (Gate B)** — آلية كل invariant، المعاملات، التدقيق، البذر، وخطة M00–M23 |
| 4 | `CLAUDE.md` (هذا الملف) | حالة التنفيذ الفعلية + تتبع المهام |
| 5 | أي نص أقدم في `docs/PLAN_v3.md` | وصف تاريخي فقط |

> **منذ Gate I (2026-09-23) كل وثائق التصميم في `docs/`.** الإشارات المختصرة داخل الوثائق (`PLAN_v3.md` بلا مسار) تعني الملف المجاور في `docs/`.

> لا يجوز إعادة فتح قرار محسوم في §7.16–7.18 أو §10 بسبب بقاء صياغة قديمة في قسم سابق.

### حلقة العمل لكل مهمة

1. اقرأ بند المهمة في هذا الملف + البند المقابل في `PLAN_v3.md`.
2. تحقق أن مهام "الاعتماد المسبق" (Gate) للمرحلة مكتملة.
3. نفّذ **ما في البند فقط** — لا إضافات ولا إعادة هيكلة خارج النطاق.
4. اكتب/حدّث اختبار pgTAP للعزل إن لمست جدولاً جديداً.
5. حدّث الـcheckbox هنا + في `PLAN_v3.md`، واكتب: ✅ ما تم + الملفات المتغيرة.
6. أي قرار جديد → أضفه إلى §6 هنا وإلى سجل القرارات في `PLAN_v3.md` §9.

### توقف واسأل قبل

- تعديل أو حذف migration تم تنفيذها.
- تعطيل RLS على أي جدول ولو مؤقتاً.
- تغيير نموذج الـtenancy أو نظام الصلاحيات.
- إضافة dependency كبيرة أو خدمة مدفوعة.
- أي عملية على بيانات production.

---

## 1. الثوابت غير القابلة للتفاوض (تفحصها في كل مراجعة)

1. التسلسل: `Platform Tenant → Group (اختياري) → School`. العزل يبدأ دائماً من `platform_tenant_id`.
2. كل جدول School-level: `school_id uuid NOT NULL` + RLS مفعّل + index.
3. جداول Identity (`students`, `families`, `guardians`, `staff`) **لا** يوضع لها `school_id`؛ الوصول يثبت عبر `enrollments` / assignments.
4. Platform Admin خارج `profiles` ونظام العضويات تماماً (`system_users` + `platform_admin_assignments`).
5. التفويض = `Membership + Role(s) + Permission(s) + Scope(s) + Resource relationship`.
6. `read` و`export` صلاحيتان منفصلتان لكل نوع بيانات.
7. كل جدول جديد يعلن مستوى ملكيته في Data Dictionary **قبل** كتابة migration.
8. كل جدول جديد له اختبار pgTAP يثبت أن مستخدم مدرسة (أ) لا يقرأ/يعدل بيانات مدرسة (ب).
9. الحذف ناعم (`archived_at`) للطلاب والموظفين وأولياء الأمور؛ لا hard delete للبيانات التشغيلية.
10. المالية: `numeric(12,2)` جنيه مصري، لا حذف، التصحيح بقيد عكسي.
11. الوقت `timestamptz` في DB، والعرض بتوقيت `Africa/Cairo`.
12. الهاتف بصيغة E.164. الأسماء رباعية + `full_name` محسوب.
13. لا نصوص مكتوبة داخل الكود — كل النصوص في ملفات ترجمة (عربي RTL).
14. `service_role` في FastAPI/n8n فقط، ولا يصل للمتصفح أبداً. لا أسرار داخل المستودع.
15. الإعدادات المؤثرة على الحسابات مرتبطة بـ`academic_year_id`؛ تغييرها لا يمس سنوات سابقة.
16. التغييرات الحساسة → `audit_log` (قديم/جديد/مستخدم/وقت/سبب). التطبيق لا يحذف ولا يعدل audit rows.
17. Frontend ليس Security Boundary. الحماية الفعلية = Backend + RLS + DB constraints.
18. لا تعديل migration منفذة؛ كل تغيير schema عبر migration جديدة.

### 1.1 نموذج RLS — الصياغة المعمارية النهائية (2026-09-22)

هذه الصياغة **تتقدم على أي نص أقدم**، بما في ذلك سطر 2026-09-11 في سجل قرارات `PLAN_v3.md` §9.

**سلسلة الهوية والتفويض — مصدر البيانات:**

```text
Auth User
   ↓
Profile
   ↓
Membership
   ├── Roles
   │     └── Permissions
   │
   └── Scopes
         ├── Platform Tenant
         ├── Group
         └── School
```

**سلسلة قرار الوصول — ما تنفذه السياسة فعلياً:**

```text
RLS Policy
   ↓
app.can_access_*()
   +
app.has_permission()
   +
Tenant Isolation
```

**شرط الجذر — قرار O1 (2026-09-22):**

`profiles.auth_user_id` فريد **عالمياً** (`UNIQUE (auth_user_id)`). نفس Auth User لا يملك profile في Tenantين.

هذا ليس تفصيلاً في جدول، بل **شرط صحة للطبقة كلها**: به تصبح `app.current_tenant_id()` دالة حتمية تُرجع صفاً واحداً دون سياق خارجي ولا Tenant claim في الـJWT. لو سُمح بـprofileين لنفس الحساب، لصارت الدالة غير حتمية وانهار Tenant Isolation من جذره. الشخص العامل في Tenantين يحتاج **حسابي دخول منفصلين**.

```text
UNIQUE (auth_user_id)
   ↓
Profile واحد لكل Auth User
   ↓
app.current_tenant_id() حتمية
   ↓
Tenant Isolation مضمون من الجذر
   ↓
app.can_access_*() + app.has_permission() تبني عليه
```

**القواعد الملزمة:**

1. RLS **لا** يعتمد على `memberships` ولا على `app.user_school_ids()` وحدهما.
2. كل سياسة تمر عبر طبقة التفويض الموحدة: `app.can_access_tenant()` / `app.can_access_group()` / `app.can_access_school()` + `app.has_permission()`.
3. قرار الوصول = **Tenant Isolation + Scope + Permission** مجتمعة؛ لا يكفي أي منها منفرداً.
4. `memberships` مصدر بيانات لعلاقة المستخدم وأدواره ونطاقاته — وليست بحد ذاتها نموذج RLS كامل.
5. **الخطأ الذي يمنعه هذا النموذج:** المستخدم صاحب العضوية في مدرسة واحدة **لا** يحصل تلقائياً على وصول لبقية مدارس الـTenant لمجرد تطابق `platform_tenant_id`. تطابق Tenant شرط ضروري لا كافٍ.
6. لا تُكتب policy تستعلم من `memberships` أو `app.user_school_ids()` مباشرة. `user_school_ids()` تحسين أداء اختياري خلف الطبقة الموحدة فقط.
7. هذه القواعد تُختبر صراحةً في **E2** (عضو مدرسة أ داخل نفس Tenant لا يصل إلى مدرسة ب).
8. عقد الدوال ملزم كما في `AUTHORIZATION_MATRIX_v1.md` §12، ومنطق التقييم موحد كما في §11 — **لا يُعاد تعريفه في كل policy أو endpoint**.
9. قواعد منع تجاوز العزل الـ15 في Matrix §15 هي قائمة فحص إلزامية لكل مراجعة كود تمس التفويض.
10. **دلالتان لا تُخلطان (تصحيح F1، Gate B):** عزل Tenant المجرد = `platform_tenant_id = (select app.current_tenant_id())`؛ أما `app.can_access_tenant()` فتعني **امتلاك نطاق Tenant**. الخلط بينهما سمح لـ`school_admin` بمنح نفسه نطاق Tenant كاملاً.
11. **جداول الهوية بلا `school_id` تُرى بالعلاقة لا بالـTenant:** `profiles`, `memberships`, `staff`, `guardians`, `families`, `audit_log` لكيانات الهوية. تطابق Tenant + صلاحية = تسريب داخل الـTenant (F2، F3، F10).
12. **`GRANT` العمود موحّد لكل مستخدمي `authenticated`** ولا يميّز بالصلاحية. العمود المحكوم بصلاحية مستقلة (`.archive`, `.activate`, `.close`) يُغيَّر بدالة انتقال حالة، لا بـGRANT.
13. **حدّ الأمان لانتقالات الحالة (قرار 2026-09-23):**
    > **State-transition authorization and invariant validation are enforced inside the controlled PostgreSQL operation that performs the transition. FastAPI orchestrates and invokes the operation but is not the sole security boundary. Direct table writes remain protected by RLS.**
    **المالك (R2):** كل دالة `SECURITY DEFINER` في `app` **تُنشأ تحت `set local role app_owner`** (فتولد ملكاً له بلا `EXECUTE` لأحد) وتقرأ الفاعل عبر `app.auth_uid()` — لا `auth.uid()` مباشرة. السياسات وحدها تستعمل `auth.uid()` (`RLS_MODEL_v1.md` §4.5).
    الدوال المتحكَّم بها **قائمة مغلقة** من أربع فئات فقط (إنشاء الهوية، انتقالات الحالة، العمليات الذرية المركبة، تجاوز RLS بعد تحقق صريح)، وكل منها يستوفي المتطلبات السبعة في `DB_IMPLEMENTATION_SPEC_v1.md` §5.0.2. CRUD العادي = جدول مباشر + RLS. لا `p_actor_id` إطلاقاً — الفاعل دائماً `auth.uid()`.

### ممنوعات صريحة (من ERD §9)

- ❌ `school_id` على كل جدول بلا تمييز
- ❌ الاعتماد على الدور داخل JWT كحقيقة نهائية
- ❌ إخفاء الأزرار في React كآلية حماية
- ❌ `service_role` من المتصفح
- ❌ وصول تلقائي شامل لـPlatform Admin
- ❌ تثبيت عدد الفصول/المراحل/الشعب في الكود

---

## 2. حالة المستودع

**الحالة:** المستودع على GitHub: `ahmedhmmad/sMas` (`main`). CI أخضر. M01 مطبّقة ومختبرة.

```
/docs                 7 وثائق التصميم                     ✅
/supabase             config.toml + tests/00_smoke          ✅ (migrations في Gate C)
/spikes/m00           تحقق V1–V8 — ليست migrations          ✅
/scripts              check-secrets.mjs                    ✅
/.github/workflows    ci.yml                               ✅
/apps/web             React + TS + Vite + Tailwind (RTL)   ⬜ Gate F
/services/api         FastAPI                              ⬜ Gate F
/apps/mobile          Flutter                              ⬜ المرحلة 12
/n8n                                                       ⬜ المرحلة 5
```

**بيئة التشغيل المحلية — Podman (قرار 2026-09-23):**

```bash
export DOCKER_HOST=npipe:////./pipe/podman-machine-default   # لكل جلسة؛ السياق الافتراضي لم يُغيَّر
node scripts/podman-relay.mjs &                             # 127.0.0.1:{54321,54322} ← VM IP
npx supabase start -x studio,imgproxy,mailpit,edge-runtime,logflare,vector,supavisor,realtime,storage-api,postgres-meta
```

لا إعادة تشغيل للـVM ولا مساس بحاويات المشاريع الأخرى على Podman.

**`db reset` على Podman قد يستغرق عدة دقائق** — لا تُفسَّر المدة كتعليق. على Windows لا يُنهي `timeout` برنامج `supabase.exe` الأصلي؛ شغّله في الخلفية وانتظر إشعار انتهائه.

---

## 3. خطة التنفيذ — المرحلة 1 (Foundation)

ترتيب إلزامي مستمد من `ERD_CORE_v1.md` §10. لا تقفز خطوة.

### Gate A — التوثيق قبل أي SQL

- [x] **A1. Data Dictionary** — `docs/DATA_DICTIONARY_v1.md`: 28 جدول Foundation (بعد A4 و C3)، الأعمدة والأنواع وNULL/DEFAULT ومستوى الملكية وكل FK/Unique/Check + الفهارس + قائمة الـtriggers اللازمة. القرارات O1–O3 محسومة (§5 هناك).
- [x] **A2. Authorization Matrix** — `AUTHORIZATION_MATRIX_v1.md`: سلسلة التفويض، أنواع Scope، كتالوج Permissions للـFoundation، فصل `read`/`export` وفصل الإدخال عن الاعتماد، مسارا Guardian/Teacher، قواعد التفويض والتضييق، و15 قاعدة منع تجاوز عزل + قائمة اختبارات pgTAP مطلوبة.
      ✅ بنود §17 أُغلقت في A2.1–A2.3 و C3؛ المتبقي مؤجل بقصد (§3.2).
- [x] **A3. RLS Model** — `docs/RLS_MODEL_v1.md`: الطبقات السبع، الدوال السبع بنصها، سياسات كل جداول Foundation (USING/WITH CHECK)، مسارات `students` الثلاثة، سياسات Platform Admin، حل تعارض `FORCE RLS` مع الـrecursion، وحدود RLS وما يُنفَّذ خارجها، و30 اختبار pgTAP.
      ⚠️ N1 أُغلق في A4؛ N2–N6 موزعة على Gates. **Gate B كشف 8 ثغرات في A3 نفسه وصححها** — §3.6.
- [x] **A4. مراجعة A1–A3 مقابل ERD** — كشفت 5 بنود، أُغلقت كلها:

| # | البند | النتيجة |
|---|---|---|
| 1 | O1 لم يُنعكس في ERD §4.5 | ✅ `auth_user_id UNIQUE` عالمياً + شرح لماذا لا يكفي القيد المركّب |
| 2 | N1 `student_profile_id` غائب عن ERD §4.15 | ✅ أُضيف `NOT NULL UNIQUE` + FK مركّب |
| 3 | مزامنة الكتالوج | ✅ §4.8 كان مزامناً؛ **الفجوة الفعلية** كانت `tenant.create` (K4) الناقص من §4.1 — المصفوفة كانت 72 والـseed 73 |
| 4 | N2 غير موثق كـintegrity constraint | ✅ ERD §5 بند 19 مع حالة الرفض |
| 5 | Student Identity Scope | ✅ جدول `identity_scopes` صريح |

#### 3.5 قرارات A4 (2026-09-22)

**Student Identity Scope — جدول `identity_scopes` صريح:**

```text
Student Identity Scope
   ├── Group                (مدرسة أو أكثر)
   └── Standalone School    (مدرسة بلا مجموعة)
```

| البند | الأثر |
|---|---|
| `students.identity_scope_id` | **NOT NULL** — يحل محل `group_id` |
| `students.group_id` | **حُذف** — مشتق من `identity_scopes`؛ إبقاؤه يخلق مصدرَي حقيقة بلا قيد يزامنهما |
| التفرد | `UNIQUE (identity_scope_id, official_id) WHERE official_id IS NOT NULL` — **قيد إعلاني واحد يغطي الحالتين** |
| **trigger T2** | **أُلغي** — لم يعد له موجب |
| منع النطاق المزدوج | عمود محسوب `schools.is_standalone` + FK مركّب؛ مدرسة داخل Group **لا تستطيع** امتلاك نطاق خاص |
| `students.school_id` | ما زال **غير موجود** — نطاق الهوية ليس المدرسة التشغيلية |

**`student_profile_id` = NOT NULL** — علاقة 1:1 إلزامية من لحظة الإنشاء.

⚠️ **تبعة تشغيلية على المرحلة 4:** ترتيب الإنشاء يصبح `auth.users → profiles → students` في transaction واحدة، ويلزم معرّف Auth اصطناعي مشتق من Official/Temporary ID لأن الطالب بلا بريد. يُحسم شكله في **Gate F2**.

⚠️ **ثغرة INSERT سُدَّت في نموذج RLS:** `student.create` وحدها كانت تسمح بإنشاء طالب في أي نطاق هوية داخل Tenant. أُضيفت `app.can_access_identity_scope()` إلى `WITH CHECK` (`RLS_MODEL_v1.md` §8.4).

- [x] **A5. اعتماد نهائي** — A1–A4 = **Foundation Design Baseline** (2026-09-23).

- [x] **A2.1 + A2.2. Role/Permission Seed وتجميد المفاتيح** — `docs/ROLE_PERMISSION_SEED_v1.md`: خريطة 10 أدوار × 73 مفتاحاً، قواعد تسمية مجمَّدة، مفاتيح محجوزة للوحدات المؤجلة، و5 بنود دين تقني.
- [x] **A2.3. تحديث المصفوفة** — تطبيق K1–K4 على `AUTHORIZATION_MATRIX_v1.md` §4 و§5 و§6 و§17.

#### 3.1 قرارات تجميد مفاتيح الصلاحيات (K1–K3)

| # | القرار | السبب |
|---|---|---|
| **K1** | `grade.manage` → **`grade_level.manage`**؛ البادئة `grade.*` محجوزة للدرجات (م6) | كانت البادئة تحمل معنيين: الصفوف في §4.8 والدرجات في §7/§10 — غموض يجعل أي سياسة RLS عليها خطأ أمنياً صامتاً |
| **K2** | إضافة `term.read`, `stage.read`, `grade_level.read`, `section.read` | البنية الأكاديمية كانت `.manage` فقط، فلا يقرأ المعلم/السكرتارية الشعب إلا بتصعيد صلاحية |
| **K3** | حذف `tenant.manage`؛ و`tenant.suspend` لا تُمنح لأي دور Tenant | الأول متداخل مع `tenant.update`؛ والثاني عملية مشغِّل منصة (§10 بند 2) |

**الكتالوج مجمَّد عند 73 مفتاحاً.** أي مفتاح جديد يحتاج قراراً في `PLAN_v3.md` §9.

**قائمة بذر `roles` — 10 أدوار:** `tenant_admin`, `group_manager`, `school_admin`, `secretary`, `accountant`, `teacher`, `counselor`, `bus_supervisor`, `guardian`, `student`.
اتحاد `PLAN_v3.md` §2 و`AUTHORIZATION_MATRIX_v1.md` §5. `platform_admin` **ليس** منها — يُبذَر في `platform_admin_roles` (§10 بند 2).

#### 3.3 Platform Admin Authorization — قرار C3 (2026-09-22)

`platform_admin_roles → platform_admin_role_permissions → permissions`. Platform Admin يستعمل **نفس كتالوج الصلاحيات**، عبر assignments مستقلة عن Tenant Roles.

```text
Platform Admin → Role → Permission + Platform-level scope
```

**وليس** `is_platform_admin = true → full access`.

| البند | الأثر الملزم على A3 |
|---|---|
| `app.is_platform_admin()` | اختبار **هوية فقط** — لا يمنح وحده أي صلاحية تشغيلية |
| `app.has_permission()` / `app.has_platform_permission()` | **سياقان منفصلان (G10، 2026-09-23):** الأولى لسياق Tenant حصراً، والثانية لسياق Platform حصراً؛ السياق يُحدَّد أولاً من `auth_identities`. لا `OR` بين المسارين على مستوى الصلاحية |
| `app.can_access_group/school()` | **لا تُرجع true لـPlatform Admin** — نطاقه platform-level منفصل عن نطاقات مستخدمي Tenant |
| البيانات الحساسة | لا وصول تلقائي؛ يلزم امتلاك الـPermission + Audit |

#### 3.4 بنود A3 المعلّقة — N1 و N2 يسدّان قبل Gate D

| # | البند | الخطورة | يُسدّ في |
|---|---|---|---|
| ~~**N1**~~ | ~~`students.student_profile_id` غير موجود~~ | ✅ **مغلق في A4** — `NOT NULL UNIQUE` | — |
| **N2** | trigger **T8**: `grant.permission ⊆ actor.permissions` | **تصعيد صلاحية فعلي**: `school_admin` يملك `role.assign` يستطيع إسناد دور `tenant_admin` لنفسه. RLS لا تستطيع فرض هذا الشق من Matrix §13 | Gate D5 |
| **N3** | التحقق العملي من `BYPASSRLS` لمالك الدوال | `FORCE RLS` + `SECURITY DEFINER` بلا BYPASSRLS = recursion | Gate D1 |
| **N4** | `GRANT` على مستوى الأعمدة (`profiles`, `sensitive_read`) | RLS تعمل على الصف لا العمود | Gate D3 |
| **N5** | تسجيل قراءات Platform Admin الحساسة | RLS لا تسجل القراءات | Gate F4 |
| **N6** | فصل `.archive` عن `.update` على مستوى العمود | كما N4 | Gate D3 |

**حدود RLS — تُقرأ قبل أي ادعاء بأن الجدول محمي** (`RLS_MODEL_v1.md` §12.2): فصل `export` عن `read`، وقراءة الحقول الحساسة، ومنع تعديل عمود بعينه، وتسجيل القراءات — **لا يُنفَّذ أي منها بـRLS**. الاكتفاء بـRLS في هذه الأربعة هو مصدر الثغرات المتوقع.

#### 3.2 بند A2 المؤجل بقصد

`Exact permission catalog for all modules` — كتالوج Foundation مثبَّت، وبقية الوحدات (`attendance.*`, `grade.*`, `admission.*`, `fee.*`, `report.*`) **محجوزة الأسماء** في `ROLE_PERMISSION_SEED_v1.md` §2.2 وتُضاف في migration مرحلتها. هذا يعطي A3 أسماء نهائية دون فتح صلاحيات وحدات غير منفذة.

#### 3.6 ثغرات A3 التي كشفها Gate B وصُحِّحت (2026-09-23)

خروج عن قواعد معتمدة (Matrix §11، §13؛ §1.1 بند 5) — **ليست قرارات جديدة**. التصحيح في `RLS_MODEL_v1.md` مباشرةً.

| # | الخطورة | الثغرة |
|---|---|---|
| **F1** | 🔴 | `can_access_tenant` = «عضو» لا «نطاق Tenant» → `school_admin` يمنح نفسه نطاق Tenant؛ `group_manager` ينشئ مدارس في أي مجموعة |
| **F2** | 🔴 | `profiles` مرئية لكل من يملك `profile.read` — **كل الأدوار العشرة** — فولي الأمر يقرأ كل profiles الـTenant |
| **F3** | 🟠 | `memberships` مرئية عبر المجموعات داخل الـTenant |
| **F4** | 🔴 | إسناد دور لعضوية خارج نطاق الفاعل → تصعيد **غيره** |
| **F5** | 🔴 | T8 يُلتف عليه: دور مخصص فارغ للذات ثم ملؤه عبر `role_permissions` |
| **F6** | 🔴 | 9 جداول من 28 بلا أي سياسة |
| **F10** | 🟠 | المحاسب يرى تدقيق كل الطلاب في الـTenant (صفوف الهوية بلا `school_id`) |
| **F11** | 🔴 | Platform Admin يرى بيانات الطلاب كاملة عبر `audit_log` — التفاف على C3 |

وتصحيحان تقنيان: `UNIQUE` بلا `NULLS NOT DISTINCT` في `membership_scopes` لم يكن يمنع التكرار (D8)؛ و`GRANT` الأعمدة لا يطبّق `sensitive_read` ولا يفصل `.archive` عن `.update` (N4/N6).

#### 3.7 قرارات Gate B — G1–G10

التفاصيل والبدائل وأثر الرفض: `DB_IMPLEMENTATION_SPEC_v1.md` §11.

| # | القرار | الحالة |
|---|---|---|
| G1 | لا تعديل ذاتي لـ`profiles`؛ سحب `profile.update` من 7 أدوار في الـseed | ✅ معتمد — طُبِّق |
| G2 | DELETE على `membership_roles`, `membership_scopes`, `role_permissions` — وإلا لا يمكن سحب الصلاحيات | ✅ معتمد |
| G3 | FKs إعلانية تفرض أن مدرسة التسجيل داخل نطاق هوية الطالب — وإلا قرار A4 شكلي | ✅ معتمد |
| G4 | صفوف الهوية تُنشأ فقط بدوال إنشاء مغلقة | ✅ معتمد |
| G5 | لا أعمدة حساسة في Foundation؛ الحساس جداول مستقلة من المرحلة 4 | ✅ معتمد |
| G6 | لا تداخل زمني بين تسجيلات الطالب | ✅ معتمد |
| G7 | T8 مُعفى في سياق service | ✅ معتمد |
| G8 | فجوات الكتالوج المجمَّد تُحَل بمفاتيح قائمة، دون فتحه | ✅ معتمد |
| G9 | T9 ينشئ نطاق الهوية تلقائياً | ✅ معتمد |
| G10 | `auth_identities` لحصرية الهوية **+ فصل صريح للسياقين**: `has_permission()` لـTenant و`has_platform_permission()` لـPlatform | ✅ معتمد — طُبِّق في RLS §2 |

### Gate B — مواصفة التنفيذ (Database Implementation Specification)

**الوثيقة:** `docs/DB_IMPLEMENTATION_SPEC_v1.md`. **الهدف:** migrations تُكتب دون أي قرار معماري أثناء الكتابة.

- [x] **B1.** مطابقة ERD — أُضيف `platform_admin_role_permissions` و`identity_scopes` كقسمين
- [x] **B2.** مطابقة Data Dictionary — 11 عدم اتساق، منها قيد تفرد **لا يعمل** (D8)
- [x] **B3.** القيود والفهارس — سجل 46 invariant بآلية كل منها؛ **T1 و T3 و T4 تحولت إلى قيود إعلانية**
- [x] **B4.** الملكية والتفويض — 8 ثغرات في A3 صُحِّحت (§3.6)؛ تغطية RLS 28/28؛ سجل صلاحيات الأعمدة
- [x] **B5.** المعاملات — دوال الإنشاء والانتقال (قائمة مغلقة)؛ Saga إنشاء حساب الطالب
- [x] **B6.** الزمن — اصطلاحان للتواريخ؛ الحالة ↔ `effective_to`
- [x] **B7.** التدقيق — النطاق، المحتوى، الثبات، الرؤية
- [x] **B8.** البذر — مرجعية في migration لا seed؛ كشف الانحراف
- [x] **B9.** مخطط الاعتماديات — بلا دوائر
- [x] **B10.** خطة M00–M23 مع ملف pgTAP لكل مجموعة
- [x] **اعتماد G1، G2، G3، G10** (2026-09-23)
- [x] **اعتماد G4–G9** (2026-09-23) — ✅ **Gate B مغلق**

### Gate I — البنية التحتية و M00 (كان Gate B سابقاً)

**شرط الإغلاق:** لا يكفي أن يعمل Supabase أو يخضرّ CI. يُغلق Gate I فقط حين تكون **نتائج V1–V8 موثقة فعلياً** في `docs/M00_RESULTS.md`.

- [x] **I1. Monorepo** — git (`main`)، الهيكل حسب `PLAN_v3.md` §3.4، نقل الوثائق إلى `docs/`، `.gitattributes` (LF)، `.gitignore`، `.env.example`، فحص أسرار بلا dependency (`scripts/check-secrets.mjs`) مُختبَر بضابط سلبي.
- [x] **I2. Supabase Local** — الحزمة الكاملة تعمل على Podman. Podman ينشر المنافذ بـDNAT داخل الـVM فلا تصل إلى `127.0.0.1` على Windows؛ الحل `node scripts/podman-relay.mjs` (يُشغَّل قبل `supabase start`) — بلا تغيير في إعدادات Podman.
- [x] **I3. CI** — `.github/workflows/ci.yml`: أسرار ← Supabase ← `db reset` ← pgTAP. أخضر. (`scripts/watch-ci.mjs` أداة محلية لمتابعة CI بلا `gh` — خارج المستودع بقرار 2026-09-24، ولا token لأجلها.)
- [x] **I4. M00** — ✅ **58/58 على الحزمة الكاملة**. V2 بإعداد R2 (17/17)، V8 بمسار الـSaga الحقيقي (13/13).
- [x] **I5. توثيق النتائج** — `docs/M00_RESULTS.md`.
- [x] **I6. البدائل** — V2 فشل (المالك المخصص لا يصل إلى `auth.uid()`) ← البديل المحدد (`postgres` مالكاً) ← المواصفة حُدِّثت ← V1 يثبت أنه يعمل.
- [x] **قرار R2** (2026-09-23) — المالك المخصص `app_owner` عبر `app.auth_uid()`؛ V2 17/17؛ `postgres` احتياط فقط. schema `app` يبقى ملك `postgres`.
- [x] **M01** — `supabase/migrations/20260923123034_setup.sql` + `supabase/tests/01_setup.test.sql`: ✅ 24/24، تُطبَّق مرتين متتاليتين (`db reset`) دون خطأ. الاختبار كشف أن `ALTER DEFAULT PRIVILEGES IN SCHEMA` بلا أثر ← صُحِّح إلى `FOR ROLE app_owner`.
- [x] **I3 الأخضر** — `github.com/ahmedhmmad/sMas`؛ أول commit `23ced0b`؛ CI أخضر من المحاولة الأولى (https://github.com/ahmedhmmad/sMas/actions/runs/35927163791).

**🔒 Gate I مغلق (2026-09-24).**

**مؤجل إلى Gate F:** Lint/formatting للويب والـAPI — لا يوجد كود بعد يُطبَّق عليه.

**الترتيب:** A → B → I → C → D → E → F. Gate I بعد B لأن M00 يحتاج Supabase محلياً، وقبل C لأن migrations تحتاجه.

### Gate C — Foundation Migrations (بالترتيب، كل مجموعة migration مستقلة)

> **الترتيب الملزم والتفصيلي: `DB_IMPLEMENTATION_SPEC_v1.md` §B10 (M01–M23).** البنود C/D أدناه تجميع للتتبع فقط؛ عند أي اختلاف يُرجَّح B10.

**تقدم B10:**

| # | Migration | pgTAP | ملاحظة التنفيذ |
|---|---|---|---|
| M01 | `setup` | ✅ 21/21 | `IN SCHEMA` بلا أثر ← `FOR ROLE app_owner` |
| M02 | `app_trigger_functions` | ✅ 26/26 | إصلاح قطع `lpad` في `temporary_id`؛ T5 يغطي `TRUNCATE` |
| M03 | `identity_root` | ✅ 28/28 | RLS يُفعَّل عند إنشاء كل جدول (لا في M13)؛ دالتا الهوية نُقلتا من M12 |
| M04 | `tenancy` | ✅ 32/32 | أُضيف FK Tenant لـ`identity_scopes.school_id` (فجوة في DD §2.16.1) |
| M05 | `platform_admin_identity` | ✅ 27/27 | لا `created_by`/`updated_by` في جداول المنصة (كانت ستبقى فارغة دائماً)؛ دوال السياق نُقلت من M12 |
| M06 | `permission_catalog_tables` | ⬜ | التالي |

- [ ] **C1.** `schema app` + الأنواع/الـenums المشتركة.
- [ ] **C2.** Tenancy: `platform_tenants`, `groups`, `schools` (+ قيد: `schools.group_id` من نفس Tenant).
- [ ] **C3.** Platform Admin: `system_users`, `platform_admin_roles`, `platform_admin_assignments`, `platform_admin_role_permissions` (بعد `permissions`).
- [ ] **C4.** Identity: `profiles` (+ **`UNIQUE (auth_user_id)` عالمياً** — O1؛ + `auth_identities` إن اعتُمد G10).
- [ ] **C5.** AuthZ: `roles`, `permissions`, `role_permissions`, `memberships`, `membership_roles`, `membership_scopes` (+ CHECK على `scope_type` مقابل `group_id`/`school_id`).
      **البذر يتبع `docs/ROLE_PERMISSION_SEED_v1.md` §8.1 حرفياً:** 73 permission ← 10 roles (`platform_tenant_id IS NULL`, `is_system = true`) ← خريطة `role_permissions` من §4.
- [ ] **C6.** Academic: `academic_years` (سنة active واحدة/مدرسة)، `terms` (داخل حدود السنة)، `stages`, `grade_levels`, `sections`.
- [ ] **C7.** People: `staff`, `staff_school_assignments`, `families`, **`identity_scopes`**, `students`, `guardians`, `student_guardians`.
- [ ] **C8.** `enrollments` (+ enrollment نشط واحد لكل student+school+year).
- [ ] **C9.** `audit_log` + trigger عام؛ منع DELETE/UPDATE من التطبيق.
- [ ] **C10.** Indexing baseline حسب `ERD_CORE_v1.md` §8 — لا indexes عشوائية.

### Gate D — RLS

- [ ] **D1.** Helpers — **النص الكامل في `docs/RLS_MODEL_v1.md` §1–§3**. مالكها دور يحمل `BYPASSRLS` (يُتحقَّق عملياً لا يُفترض — §4.2 هناك):
      `app.current_profile_id()`, `app.current_tenant_id()`, `app.is_platform_admin()`,
      `app.has_permission(text)`, `app.can_access_tenant(uuid)`, `app.can_access_group(uuid)`, `app.can_access_school(uuid)`.
      `app.user_school_ids()` اختياري كتحسين أداء خلف الطبقة الموحدة فقط، لا كمصدر صلاحية.
      المرجع الملزم: §1.1 أعلاه.
- [ ] **D2.** ENABLE + FORCE RLS على كل جداول Foundation — **قبل** كتابة السياسات، ليظهر أي recursion فوراً (`RLS_MODEL_v1.md` §14).
- [ ] **D3.** Policies لجداول Tenant-level / Group-level / School-level — كل policy = `app.can_access_*()` + `app.has_permission()`؛ ممنوع الاستعلام المباشر من `memberships` أو الاكتفاء بتطابق `platform_tenant_id`.
- [ ] **D4.** Policies لهوية الطالب — ثلاثة مسارات (`student_in_scope` / `student_linked_to_guardian` / `student_is_self`)، `RLS_MODEL_v1.md` §8.
- [ ] **D5.** Policies لـ`profiles`/`memberships` + **trigger T8** (`grant.permission ⊆ actor.permissions`) — `RLS_MODEL_v1.md` §10.2.
- [ ] **D6.** سياسات Platform Admin: `is_platform_admin() AND has_permission(...)` — لا استثناء boolean (`RLS_MODEL_v1.md` §11).
- [ ] **D7.** سياسة `audit_log` + GRANT على مستوى الأعمدة (`RLS_MODEL_v1.md` §13, §12.2).

### Gate E — الاختبارات والبيانات

- [ ] **E1.** قالب اختبار pgTAP للعزل بين مدرستين.
- [ ] **E2.** اختبارات عزل: Tenant / Group / School / Guardian / Teacher.
      **المرجع الملزم:** قائمة الاختبارات الـ15 في `AUTHORIZATION_MATRIX_v1.md` §16 — تُنفَّذ كلها، لا انتقاء منها.
      **أبرزها:** عضو مدرسة (أ) لا يصل إلى مدرسة (ب) **داخل نفس Tenant** (§1.1 بند 5)؛ `Permission بلا Scope` لا يمنح وصولاً والعكس؛ `read` لا يمنح `export`؛ `current_tenant_id()` تُرجع Tenant واحداً بالضبط (O1).
- [ ] **E3.** اختبارات القيود: enrollment uniqueness، academic year active، official ID، guardian phone، الأكواد.
- [ ] **E4.** اختبارات audit trigger (التسجيل + منع الحذف/التعديل).
- [ ] **E5.** Seed: Tenant واحد + Group بمدرستين + مدرسة مستقلة، ومستخدمون من كل الأدوار.
- [ ] **E6.** سياسة النسخ الاحتياطي + اختبار استرجاع موثّق (شرط قبل أي بيانات حقيقية).

### Gate F — التطبيقات (هيكل فقط)

- [ ] **F1.** تطبيق الويب: Vite + TS + Tailwind RTL، خط عربي (IBM Plex Sans Arabic / Cairo)، i18n، تنقل حسب الدور.
- [ ] **F2.** المصادقة: Supabase Auth + JWT للموظفين؛ حساب الطالب المستقل؛ حساب ولي الأمر OTP/كلمة مرور حسب إعداد المدرسة.
- [ ] **F3.** تحديد المدرسة من الـsubdomain (سياق واجهة فقط — لا يمنح أي صلاحية).
- [ ] **F4.** هيكل FastAPI: التحقق من Supabase JWT، استخراج Tenant/Scope/Role، طبقة تفويض مشتركة.

### معايير إنجاز المرحلة 1

- [ ] اختبارات العزل خضراء: مستخدم مدرسة (أ) لا يقرأ ولا يعدل بيانات مدرسة (ب).
- [ ] تسجيل الدخول يعمل والقائمة تتغير حسب الدور.
- [ ] CI أخضر.
- [ ] مراجعة ERD + migrations قبل الانتقال إلى المرحلة 2.

---

## 4. المراحل التالية — تتبع عام

| # | المرحلة | تعتمد على | الحالة |
|---|---|---|---|
| 1 | الأساس (Foundation) | — | 🔄 جارية |
| 2 | إعداد المدرسة | 1 | ⬜ |
| 3 | الموظفون والتكليفات | 2 | ⬜ |
| 4 | القبول والتسجيل والطلاب | 2 | ⬜ |
| 5 | الحضور وإشعارات واتساب | 3، 4 | ⬜ |
| 🎯 | **تشغيل فعلي أول (مدرسة التجربة)** | 1–5 | ⬜ |
| 6 | التقييم والدرجات والشهادات | 3، 4 | ⬜ |
| 🎯 | **تشغيل فعلي ثانٍ (نتائج الفصل)** | 6 | ⬜ |
| 7 | المالية والنقل | 4 | ⬜ |
| 8 | شؤون الموظفين والرواتب | 3، 5، 7 | ⬜ |
| 9 | بوابة ولي الأمر والطالب والتواصل | 5، 6، 7 | ⬜ |
| 10 | التقارير ولوحات المعلومات | 5، 6، 7 | ⬜ |
| 11 | الجدول الدراسي | 3 | ⬜ |
| 12 | تطبيق الموبايل (Flutter) | 5، 6، 9 | ⬜ |
| 13 | الجاهزية التجارية | الكل | ⬜ |

تفاصيل بنود كل مرحلة في `PLAN_v3.md` §5. لا تفتح مرحلة قبل استيفاء معايير إنجاز سابقتها.

---

## 5. قيود v1 — لا تنفّذ خلافها

- الحضور **يومي فقط**؛ لا حضور بالحصة، ولا ربط بين الجدول والحضور.
- حساب المدرسة يسجل ويعدل حضور الطلاب — وليس المعلم.
- لا Overall Average، لا Ranking، لا Extra Credit، لا Resit/Reassessment.
- قرار الترفيع يتم أثناء Enrollment للسنة التالية، لا تلقائياً من متوسط.
- الواجبات: إنشاء وإرسال فقط؛ لا تسليم ولا تصحيح إلكتروني.
- ولي الأمر: عرض داخل التطبيق فقط بلا تحميل/طباعة؛ الرسائل للقراءة فقط.
- لا غرامات تأخير؛ فقط حالة "متأخر".
- عدد الفصول الدراسية والمراحل والشعب configurable دائماً.

---

## 6. الأسئلة المفتوحة (لا تفترض إجابة — نفّذ configurable أو توقف واسأل)

| # | البند | يؤثر على المرحلة | الحالة |
|---|---|---|---|
| 1 | تفاصيل تقارير الجهات الكافلة | 7، 10 | مفتوح |
| 2 | تفاصيل الرواتب: البدلات والخصومات وسياسات الغياب | 8 | مفتوح |
| 3 | قوالب الشهادات الفعلية (المدرسة والروضة) | 6 | مفتوح |
| 4 | مزود OCR سحابي أم محلي (دقة/خصوصية/تكلفة) | 4 | مفتوح |
| 5 | تفاصيل الاشتراكات والباقات والفوترة | 13 | مفتوح |

**محسوم ولا يُعاد فتحه:** tenancy، RLS ownership، حساب الطالب، حساب ولي الأمر، الحضور اليومي، قواعد النتائج في v1.

### قرارات جديدة تظهر أثناء التنفيذ

| التاريخ | القرار | السياق |
|---|---|---|
| 2026-09-22 | حسم نموذج RLS: طبقة تفويض موحدة `app.can_access_*()` + `app.has_permission()`، و`memberships` مصدر بيانات لا نموذج RLS. التفاصيل في §1.1 | أُضيف إلى `PLAN_v3.md` §9، وعُدّل §10 بند 6، ووُسم سطر 2026-09-11 كـsuperseded جزئياً |
| 2026-09-22 | الحقول المحصورة بقيم تُنفَّذ `text + CHECK` مسمّى، لا PostgreSQL `ENUM` | تعديل قيمة ENUM يصطدم بقاعدة "لا تعديل على migration منفذة" (§3.3 بند 19). التفاصيل: `DATA_DICTIONARY_v1.md` §0.2 |
| 2026-09-22 | سلامة الـTenant تُفرض بـFK مركّب `(id, platform_tenant_id)` لا بـtriggers | القيد يصبح مفروضاً من المحرك لا من الكود؛ يقلّص قائمة الـtriggers إلى 7 فقط. التفاصيل: `DATA_DICTIONARY_v1.md` §0.6 و§4 |
| 2026-09-22 | `audit_log.id` هو `bigint IDENTITY` وليس uuid، وبلا FK على `actor_id`/`entity_id` | ترتيب زمني طبيعي وحجم أصغر؛ وFK على الكيانات يخلق تبعية عكسية تكسر السجل عند الأرشفة |
| 2026-09-22 | **O1** — `profiles.auth_user_id` فريد عالمياً؛ نفس Auth User لا يعبر Tenantين | شرط حتمية `app.current_tenant_id()` وصحة §1.1. التفاصيل: §1.1 + `DATA_DICTIONARY_v1.md` §2.7 |
| 2026-09-22 | **O2** — `students.gender` و`birth_date` قابلان لـNULL؛ OCR ليس شرطاً ولا مصدراً نهائياً | اكتمال البيانات قاعدة أعمال في المرحلة 4 لا قيد صف. يلزم معالجة NULL صراحةً في قواعد التوزيع والتقارير |
| 2026-09-22 | **O3** — `temporary_id` بصيغة `TMP-{YEAR}-{SEQUENCE}`، توليد ذري، بلا إعادة استخدام | `nextval()` غير تعاملي فلا يُعيد رقماً بعد rollback؛ الفجوات مقبولة. التفاصيل: `DATA_DICTIONARY_v1.md` §2.17.1 |

> كل صف يُضاف هنا يُنسخ أيضاً إلى سجل القرارات في `PLAN_v3.md` §9.

---

## 7. سجل التقدم

| التاريخ | ما تم إنجازه | الملفات |
|---|---|---|
| 2026-09-22 | إنشاء `CLAUDE.md` لتتبع تنفيذ الخطة | `CLAUDE.md` |
| 2026-09-22 | تثبيت الصياغة المعمارية النهائية لنموذج RLS (§1.1)، وتقييد D1/D3/E2/A3 بها، ووسم الصياغة القديمة في سجل القرارات كـsuperseded | `CLAUDE.md`, `PLAN_v3.md` |
| 2026-09-22 | ✅ **A1** — Data Dictionary v1: 26 جدول Foundation بالأعمدة والقيود والفهارس، 7 triggers لازمة | `docs/DATA_DICTIONARY_v1.md`, `CLAUDE.md`, `PLAN_v3.md` |
| 2026-09-22 | ✅ حسم O1–O3 وترقية O1 إلى شرط جذر في §1.1 و§10 بند 3 | `docs/DATA_DICTIONARY_v1.md`, `CLAUDE.md`, `PLAN_v3.md` |
| 2026-09-22 | ✅ **A2** — اعتماد `AUTHORIZATION_MATRIX_v1.md` كمرجع التفويض، وربطه بـ§1.1 وC5 وE2، وتصحيح قائمة أدوار البذر إلى 10 أدوار | `AUTHORIZATION_MATRIX_v1.md` (مرجع), `docs/DATA_DICTIONARY_v1.md`, `CLAUDE.md` |
| 2026-09-22 | ✅ **A2.1–A2.3** — خريطة Role → Permission كاملة، تجميد الكتالوج عند 73 مفتاحاً (K1–K3)، وكشف فجوة `platform_admin_role_permissions` | `docs/ROLE_PERMISSION_SEED_v1.md`, `AUTHORIZATION_MATRIX_v1.md`, `docs/DATA_DICTIONARY_v1.md`, `CLAUDE.md` |
| 2026-09-22 | ✅ **C3** — اعتماد `platform_admin_roles → platform_admin_role_permissions → permissions`؛ `is_platform_admin()` اختبار هوية فقط، و`has_permission()` توحّد المسارين. الكتالوج 73 مفتاحاً بعد K4 (`tenant.create`) | `docs/ROLE_PERMISSION_SEED_v1.md`, `AUTHORIZATION_MATRIX_v1.md`, `docs/DATA_DICTIONARY_v1.md`, `CLAUDE.md` |
| 2026-09-22 | ✅ **A3** — RLS Model: 7 دوال، سياسات كل الجداول، حل تعارض FORCE RLS/recursion، 30 اختبار pgTAP، و6 بنود معلّقة | `docs/RLS_MODEL_v1.md`, `CLAUDE.md` |
| 2026-09-23 | ✅ **A5** — اعتماد A1–A4 كـFoundation Design Baseline | — |
| 2026-09-24 | ✅ **M05** — `system_users` (G10 من جهة المنصة)، `platform_admin_roles`، `platform_admin_assignments`؛ دوال `current_security_context` و`current_system_user_id` و`is_platform_admin`؛ 137/137 | `supabase/migrations/20260923224912_platform_admin_identity.sql`, `supabase/tests/05_platform_admin_identity.test.sql`, `docs/DATA_DICTIONARY_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | ✅ **M04** — `groups`، `schools` (`is_standalone`، `scope_owner_id`)، `identity_scopes`، T9؛ I1–I9 و G3 مُثبتة؛ 110/110 | `supabase/migrations/20260923224347_tenancy.sql`, `supabase/tests/04_tenancy.test.sql`, `docs/DATA_DICTIONARY_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | ✅ **M03** — `auth_identities` (G10)، `platform_tenants`، `profiles` (O1)، `app.current_profile_id/current_tenant_id`؛ RLS مفعّل ومفروض عند الإنشاء؛ 78/78 | `supabase/migrations/20260923223756_identity_root.sql`, `supabase/tests/03_identity_root.test.sql`, `docs/DATA_DICTIONARY_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | ✅ **M02** — T5 (يغطي `TRUNCATE` بـtrigger جملة)، T6 (ختم عام يتجاهل قيم العميل)، `temporary_id` (إصلاح قطع `lpad` بعد 999,999)؛ 50/50 | `supabase/migrations/20260923223202_app_trigger_functions.sql`, `supabase/tests/02_app_trigger_functions.test.sql`, `docs/DATA_DICTIONARY_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | 🔒 **Gate I مغلق** — أول commit `23ced0b` إلى `github.com/ahmedhmmad/sMas`؛ CI أخضر (https://github.com/ahmedhmmad/sMas/actions/runs/35927163791) | `.github/workflows/ci.yml`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-23 | **M00 أخضر 58/58 على الحزمة الكاملة** (Podman + `scripts/podman-relay.mjs`)؛ R2 مُطبَّق؛ **M01** ✅ 24/24 — وكشف اختباره أن `IN SCHEMA` بلا أثر فصُحِّح إلى `FOR ROLE app_owner` | `supabase/migrations/20260923123034_setup.sql`, `supabase/tests/01_setup.test.sql`, `scripts/podman-relay.mjs`, `docs/M00_RESULTS.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `docs/RLS_MODEL_v1.md`, `CLAUDE.md` |
| 2026-09-23 | **Gate I:** I1 ✅ (monorepo، git، فحص أسرار مُختبَر)؛ M00 نُفِّذ ووُثِّق — V1، V3–V7 ✅، V2 بديل مُفعَّل، V8 جزء DB ✅؛ اكتشاف V3c (`EXECUTE` لـ`anon` افتراضياً في schema جديد) أُضيف إلى M01؛ Supabase الكامل محجوب بيئياً | `docs/M00_RESULTS.md`, `spikes/m00/*`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md`, `.github/workflows/ci.yml`, `scripts/check-secrets.mjs`, ملفات الجذر |
| 2026-09-23 | ✅ **Gate B مغلق** — اعتماد G4–G9؛ قرار حدّ الأمان لانتقالات الحالة داخل PostgreSQL مع عقد الدوال المتحكَّم بها (§5.0 في المواصفة) | `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md`, `PLAN_v3.md` + الوثائق التي حملت علامات G |
| 2026-09-23 | ✅ اعتماد G1، G2، G3، G10؛ تطبيق G1 على الـseed؛ G10 بفصل السياقين (`has_platform_permission`)؛ تصحيح `provision_student` ليشمل الـenrollment؛ M00 مقيَّد بثمانية تحققات | `docs/RLS_MODEL_v1.md`, `docs/ROLE_PERMISSION_SEED_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `AUTHORIZATION_MATRIX_v1.md`, `CLAUDE.md`, `PLAN_v3.md` |
| 2026-09-23 | ✅ **Gate B (B1–B10)** — مواصفة التنفيذ؛ 8 ثغرات A3 مصححة؛ T1/T3/T4 إعلانية؛ خطة M00–M23؛ G1–G10 بانتظار الاعتماد؛ Gate البنية التحتية أُعيدت تسميته Gate I | `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `docs/RLS_MODEL_v1.md`, `docs/DATA_DICTIONARY_v1.md`, `ERD_CORE_v1.md`, `CLAUDE.md`, `PLAN_v3.md` |
| 2026-09-22 | ✅ **A4** — مراجعة مقابل ERD: تصحيح O1 وN1 في ERD، توثيق N2 كـintegrity constraint، مزامنة `tenant.create`، واعتماد `identity_scopes` + `student_profile_id NOT NULL` | `ERD_CORE_v1.md`, `docs/DATA_DICTIONARY_v1.md`, `docs/RLS_MODEL_v1.md`, `AUTHORIZATION_MATRIX_v1.md`, `CLAUDE.md`, `PLAN_v3.md` |
