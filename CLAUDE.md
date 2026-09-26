# CLAUDE.md — دليل التنفيذ وتتبع التقدم

**المشروع:** نظام إدارة المدارس متعدد المستأجرين (Multi-Tenant SMS)
**تاريخ الإنشاء:** 2026-09-22
**آخر تحديث:** 2026-09-23
**المرحلة الحالية:** المرحلة 1 — الأساس (Foundation) / **Gate C — Foundation Migrations** (**Gate C 🔒 مكتمل: M01–M23**؛ **Gate E 🔒 مغلق تقنياً: E1–E6** — Production Backup Policy TBD؛ Gate F: **F4 🔒**؛ F2: **D1/M24 🔒**؛ **D2 = B منفذ (M25)** بانتظار المراجعة)

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
12a. **تعدد علاقات الـprofile (قرار 2026-09-24):** A profile may have multiple legitimate relationships/roles within the same Tenant, including student, employee, and guardian. No database invariant prohibits these combinations. Authorization remains determined independently by role, permission, and scope.
    `Profile` يمثل الشخص/الحساب داخل الـTenant لا نوع المستخدم؛ لا `CHECK` ولا trigger من نوع «student ⇒ لا يكون موظفاً». ولا تُنشأ هوية ثانية لنفس الشخص لأن له دوراً آخر.
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
/services/api         FastAPI — هيكل F4 (JWT، authenticator)  ✅ F4
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

**الاختبارات: `npx supabase db reset --no-seed` ثم `npx supabase test db`** (B8 §8.3 — لا اعتماد على الـseed). `db reset` بلا العلم يطبق `seed.sql` للتطوير (كلمة مرور حسابات التطوير: `DevOnly-Seed-2026`، محلية فقط).

**`db reset` على Podman قد يستغرق عدة دقائق** — لا تُفسَّر المدة كتعليق. على Windows لا يُنهي `timeout` برنامج `supabase.exe` الأصلي؛ شغّله في الخلفية وانتظر إشعار انتهائه.

---

## 3. خطة التنفيذ — المرحلة 1 (Foundation)

ترتيب إلزامي مستمد من `ERD_CORE_v1.md` §10. لا تقفز خطوة.

### Gate A — التوثيق قبل أي SQL

- [x] **A1. Data Dictionary** — `docs/DATA_DICTIONARY_v1.md`: 28 جدول Foundation (بعد A4 و C3) — **29 بعد G10** (`auth_identities`)، الأعمدة والأنواع وNULL/DEFAULT ومستوى الملكية وكل FK/Unique/Check + الفهارس + قائمة الـtriggers اللازمة. القرارات O1–O3 محسومة (§5 هناك).
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
- [x] **B4.** الملكية والتفويض — 8 ثغرات في A3 صُحِّحت (§3.6)؛ تغطية RLS: enforcement 29/29، سياسات التطبيق 28 (`auth_identities` مستثنى بتصميمه — M13)؛ سجل صلاحيات الأعمدة
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
| M06 | `permission_catalog_tables` | ✅ 26/26 | `has_platform_permission()` نُقلت من M12؛ `permissions` بلا `*_by` (يكتبه migrations فقط) |
| M07 | `memberships` | ✅ 46/46 | `has_permission()` و`can_access_*` نُقلت من M12؛ **F1 مُثبت**: عضو المدرسة/المجموعة لا يملك نطاق Tenant |
| M08 | `academic_structure` | ✅ 30/30 | T4 بديله الإعلاني يعمل؛ `EXCLUDE` عبر `btree_gist` في schema `extensions` يعمل على `uuid` |
| M09 | `people` | ✅ 61/61 | صيغة `full_name` في DD §0.4 غير قابلة للتنفيذ (`concat_ws` STABLE) ← بديل IMMUTABLE بنفس الناتج |
| M10 | `enrollments` | ✅ 26/26 | I38 محتوى في G6 (لا يُعزل باسمه)؛ قيود G3 DEFERRABLE INITIALLY IMMEDIATE |
| M11 | `audit` | ✅ 44/44 | T7 على 28 جدولاً؛ الفاعل مستقل عن `created_by`؛ `source` غير المعروف يصبح `api`؛ **متطلب M21:** إعادة `app.audit_action/reason` بعد الكتابة |
| M12 | `authz_helpers` | ✅ 61/61 | 10 دوال بنص RLS_MODEL حرفياً؛ كل دالة مختبرة بقائمة كاملة لكل فاعل؛ تعمل تحت FORCE RLS. كشفت H1 (محسوم أدناه) |
| M12b | `authz_helpers_current_scope` | ✅ 14/14 (445/445) | **H2** — أحدث تسجيل / ارتباط نشط / تكليف نشط؛ `12_helpers` حُدِّثت توقعاتها (7 قوائم) |
| M13 | `rls_enable` | ✅ 61/61 (506/506) | بوابة تحقق فقط، بلا سياسات: **29** جدولاً بالاسم (28 + `auth_identities`)؛ الـmigration تفشل النشر عند جدول بلا ENABLE/FORCE أو في `app` أو سياسة قبل M14؛ 5 ضوابط سلبية مُثبتة |
| M14 | `policies_tenancy_platform` | ✅ 96/96 (602/602) | أول السياسات (6 جداول، 16 سياسة `TO authenticated`)؛ I1 مسح لكل جدول مملوك لـTenant ببيانات في الـTenantين؛ PA catalog = service فقط؛ EXECUTE يُمنح مع كل طبقة سياسات |
| M15 | `policies_authz` | ✅ 104/104 (706/706) | 17 سياسة على 7 جداول؛ قراران (can_manage على النطاق، `membership_id_of`) بضوابط سلبية؛ E4 و E14/2 تنتظر T8 (M19)؛ حارس دائم: كل دالة ينفذها `authenticated` تستدعيها سياسة |
| M16 | `policies_academic` | ✅ 40/40 (746/746) | 15 سياسة على 5 جداول؛ `academic_years` بمفاتيح الكتالوج (`create`/`update`) لا `.manage` (تعارض RLS §7 مع الكتالوج و§12.1 — رُجِّح الكتالوج بحكم أولوية المراجع)؛ لا دوال ولا EXECUTE جديد |
| M17 | `policies_people_enrollment` | ✅ 97/97 (843/843) | 17 سياسة على 7 جداول؛ H2 داخل RLS عبر دوال M12b وحدها (حارس: لا سياسة تقرأ جدول علاقة مباشرة)؛ قرار: enrollments INSERT و UPDATE تشترطان أيضاً `app.student_in_scope(student_id)` بضابط سلبي؛ R5 TODO حتى `teaching_assignments` (D1) |
| M17b | `staff_assignment_columns` | ✅ (ضمن 17: 102/102؛ 848/848) | `staff_school_assignments.status` و`effective_to` ليسا أعمدة يكتبها العميل؛ الإنهاء وإعادة الفتح عبر دوال انتقال حالة في M21 (auth.uid()، الصلاحية، سلطة النطاق، FOR UPDATE، انتقالات صريحة، تدقيق)؛ INSERT لتكليف جديد مشروع (خيار b) |
| M18 | `policies_audit` | ✅ 24/24 (872/872) | سياستان (Tenant/Platform منفصلتان بحكم G10 بدل OR في §13)؛ H2 في المسار (2)؛ `CASE` لتحويل `entity_id`؛ SELECT لـ`authenticated` مؤجل لـM20 (مُثبت غيابه) |
| M19 | `authz_integrity` | ✅ 31/31 (903/903) | T8 AFTER على الجداول الثلاثة؛ المتطلبات الثلاثة بضوابط إيجابية وضابط سلبي (بلا T8 تنجح كلها)؛ فصل الطبقات RLS/T8 مُثبت؛ سحب الدور والصلاحية مفحوص، سحب النطاق لا |
| M20 | `privileges` | ✅ 65/65 (967/967) | سجل §4.6 حرفياً + M17b + M19؛ `anon` لا شيء؛ لا TRUNCATE/TRIGGER/REFERENCES؛ DELETE على جداول G2 فقط؛ SELECT على `audit_log`؛ امتيازات افتراضية آمنة؛ EXECUTE بفئتين يحل محل حارس M15؛ اختبارات 03/11/14–19 حُدِّثت لحقيقة ما بعد M20 |
| M20b | `privileges_followup` | ✅ (ضمن 20: 67/67) | حذف سياسة INSERT الميتة لـPlatform Admin على `platform_tenants`؛ `families.family_code` غير قابل للتعديل؛ حارس: لا سياسة INSERT على جدول بلا أعمدة INSERT |
| M21 | `state_functions` | ✅ 84/84 (1053/1053) | 15 دالة متحكَّم بها بالمتطلبات السبعة؛ النقل ذري (فشل في المنتصف لا يترك أثراً)؛ سياق التدقيق يُعاد فارغاً بعد كل كتابة (مُثبت)؛ allowlist M20 = 15؛ أداتان داخليتان بلا EXECUTE لأحد |
| M21b | `tenant_suspension` | ✅ 15/15 | الإيقاف في جذر سياق الـTenant: `current_profile_id` و`current_tenant_id` معاً (ضابط سلبي: الثانية وحدها تترك المستخدم يرى مدرسته 0/1/1) |
| M22 | `provisioning_functions` | ✅ 52/52 (1120/1120) | 5 دوال إنشاء بالعقد السباعي؛ H1 مشتق من المدرسة وبلا معامل؛ idempotency بمعرّف العميل؛ الـSaga ذرية (فشل لا يترك profile/identity/student)؛ T8 داخل الإنشاء؛ إعفاء T8 ضيق لـbootstrap (ضابط سلبي: بدونه يُرفض)؛ allowlist = 20 |
| M23 | `reference_data` | ✅ 35/35 (1155/1155) | 73 permission، 10 أدوار، 255 ربطاً، `platform_admin` بتسع؛ مولّدة من الوثيقة نفسها وحارس داخل الـmigration؛ كشف الانحراف مُثبت بضابط سلبي؛ عناوين §4 و§5 المتقادمة صُحِّحت؛ اختبارات 05–22 تستعمل البذر أو أكواداً اختبارية `zt_*` |
| M24 | `student_login` (F2/D1) | ✅ 26/26 | `resolve_student_login` قبل JWT: EXECUTE لـservice_role وحده، NULL واحد لكل فشل، tenant+slug (الـslug فريد داخل الـTenant فقط)؛ D1 مفروض في `provision_student`؛ `22` و seed E5 على شكل D1 |
| M25 | `first_login_credential` (F2/D2-B) | ✅ 36/36 | حالة الحساب في `auth_identities`؛ بوابة الجذر؛ `arm_first_login`/`activate_first_login` بإشارة سجل Supabase Auth؛ **استثناء R2 موسّع** (دالتان ملك postgres لقراءة `auth`)؛ `05` حارس القائمة المغلقة |

**✅ H1 محسوم (2026-09-24) — السماح، بلا Group Scope:**
> **H1 — A secretary may register a new student in a school that belongs to a group. The secretary requires `student.create` with school scope; this does not grant group scope. When the target school belongs to a group, the student's identity scope is derived from the target school's group and is not client-selectable. The student's enrollment is created for the target school in the same controlled provisioning operation.**

الأثر الملزم:
- **M22 `provision_student`:** لا تستقبل `identity_scope_id` من العميل؛ تشتقه من المدرسة الهدف (`schools.scope_owner_id` ← `identity_scopes`). الفحص: `student.create` + `enrollment.create` + `can_access_school(target_school)`. `can_access_identity_scope` **لا تُستعمل** شرطاً للإنشاء.
- **G3** يبقى الحارس الإعلاني: نطاق الطالب = مالك مدرسة التسجيل؛ أي نطاق آخر يُرفض بالـFK حتى لو تجاوز أحد الدالة.
- **M12 لا تُعدَّل:** `can_access_identity_scope` باقية بدلالتها «سلطة على النطاق كله» لسياسة قراءة `identity_scopes` — **نُفذت نهائية في M14** (تصحيح 2026-09-25: «M17» هنا كان خطأ في هذه الملاحظة؛ B10 لم يُسند `identity_scopes` إلى M17 قط، وهو جدول tenancy أُنشئ في M04)؛ السكرتير لا يحتاج رؤية صف النطاق لأن الاشتقاق يتم داخل الدالة.
- **اختبارات M22:** سكرتير SA1 ينشئ طالباً في SA1 (نطاق GA) ✅؛ لا يملك `can_access_group(GA)` بعدها ✅؛ لا يستطيع الإنشاء في SB1 أو SS ❌؛ لا وسيلة لتمرير نطاق آخر.

**✅ H2 محسوم (2026-09-25) — التاريخ يبقى، والصلاحية التشغيلية تنتقل مع الطالب:**
> **H2 — A school is operationally in scope for a student only through the student's current/authorized enrollment in that school. Historical enrollments provide historical access only where a specific permission/policy explicitly permits historical records; they do not grant operational access to the student's current account or guardian account.**

`Historical Enrollment ≠ Current Operational Access`. إدارة الحساب (كلمة المرور، الهاتف، حالة الحساب) للطالب أو ولي الأمر تتبع **العلاقة الحالية المصرّح بها** أو مساراً إدارياً صريحاً مستقلاً — لا العلاقة التاريخية.

| الحالة | المدرسة السابقة |
|---|---|
| للطالب Enrollment حالي فيها | ✅ صلاحياتها المعتادة وفق Scope/Permission |
| غادرها إلى مدرسة أخرى | ❌ لا وصول تشغيلي للطالب |
| تحتاج تاريخ التسجيل القديم | ✅ عبر السجلات التاريخية المسموح بها، لا كإدارة للحساب |
| ولي الأمر مرتبط بطالب غادرها | ❌ لا إدارة لحساب ولي الأمر |
| لولي الأمر طفل آخر ما زال فيها | ✅ بقدر ما تسمح به علاقة ذلك الطفل الحالية |

**التفصيل المعتمد (2026-09-25):**

| البند | القرار |
|---|---|
| `student_in_scope` | **أحدث Enrollment** للطالب (بـ`effective_from`)، أياً كانت حالته، حتى يظهر أحدث منه في مدرسة أخرى — لا `status` وحده |
| `guardian_in_scope` / `family_in_scope` | ارتباط **نشط** + الطالب ضمن النطاق الحالي |
| `staff_in_scope` | التكليف **النشط** فقط |
| الهوية التاريخية للطالب | غير متاحة في Foundation؛ المدرسة السابقة ترى `enrollments` و`audit_log` الخاصة بها فقط؛ يؤجل للمرحلة 4 بلا فتح الكتالوج |

**التطبيق: M12b** (`authz_helpers_current_scope`) — `create or replace` للدوال الثلاث؛ M12 باقية في التاريخ؛ `family_in_scope` و`can_see/can_manage_membership` ترث الدلالة. مثبت في `12b_current_scope`.

**قاعدة اختبار (من M08):** كل تحقق رفض يطابق **اسم القيد** المقصود لا رمز الخطأ وحده (`like 'ERR 23503%<constraint_name>%'`). تكرر ثلاث مرات أن رُفض الإدراج بقيد غير المقصود فنجح التحقق دون أن يثبت شيئاً.

**ترتيب فحص القيود في Postgres — يحدد أي قيد يرفض أولاً:** `NOT NULL`/`CHECK` عند تكوين الصف ← `UNIQUE`/`EXCLUDE` عند إدراج الفهرس ← `FK` في نهاية الجملة. لاختبار FK باسمه يجب ألا يُخرق قبله `CHECK` أو `EXCLUDE` (في M10: طلاب بلا تسجيلات لحالات الرفض، وإلا سبقهم G6 في تسع حالات).

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

- [x] **E1.** قالب اختبار العزل — موثّق في `docs/TRACEABILITY_E1_E4.md` §E1 (النمط المستعمل في 14–22 بقواعده الست).
- [x] **E2.** اختبارات عزل — مصفوفة تتبع لـMatrix §16 (15) و RLS §15 (I/P/R/E/T): كلها ✅ عدا #12/R5 ⏳ D1؛ P3 القناة ➖ F4.
      **المرجع الملزم:** قائمة الاختبارات الـ15 في `AUTHORIZATION_MATRIX_v1.md` §16 — تُنفَّذ كلها، لا انتقاء منها.
      **أبرزها:** عضو مدرسة (أ) لا يصل إلى مدرسة (ب) **داخل نفس Tenant** (§1.1 بند 5)؛ `Permission بلا Scope` لا يمنح وصولاً والعكس؛ `read` لا يمنح `export`؛ `current_tenant_id()` تُرجع Tenant واحداً بالضبط (O1).
- [x] **E3.** القيود INV-I1..I43 — كل رفض مطابق باسم القيد (G1: شُدِّد 74 تحققاً؛ G2: الـFK المركّب للعضوية لم يكن مُختبراً فعلاً — أُصلح).
- [x] **E4.** التدقيق I44–I46 + حقول B7 كلها ✅؛ قراءات/تصدير FastAPI ➖ F4.
- [x] **E5.** `supabase/seed.sql` — Tenant `DEV` + Group GA (SA، SB) + SS مستقلة + مستخدم لكل دور من العشرة + Platform Admin. **يمر بمسار التطبيق نفسه:** دوال الإنشاء (M22) و CRUD تحت RLS بدور `authenticated` ودوال M21 — استثناءان فقط بلا مسار تطبيق: حسابات Auth (Admin API في Production) وإقلاع Platform Admin (G8). يتحقق من نفسه (البنية، دور ونطاق كل مستخدم، لا بيانات مرجعية جديدة، لا صف Tenant بفاعل `system`). مُثبت end-to-end: تسجيل دخول حقيقي + قراءة عبر PostgREST لكل دور. **الاختبارات تعمل على `db reset --no-seed`؛ CI يطبق الـseed خطوةً منفصلة.**
- [x] **E6.** سياسة النسخ الاحتياطي + اختبار استرجاع موثّق (شرط قبل أي بيانات حقيقية).
      🔒 **E6 Technical Database Backup/Restore: CLOSED** — لا يثبت استعادة خادم PostgreSQL كامل إلى خادم جديد.
      ✅ **الاختبار التقني** — `docs/E6_BACKUP_RESTORE.md`: backup كامل (`pg_dump -Fc --create`) ← قاعدة جديدة بخصائص القاعدة من الـdump ← restore بلا migrations ← بصمة 883 سطراً diff 0 (بنية + بيانات + Auth + سجل migrations) ← الحزمة 1157/1157 على النسخة المستعادة؛ 7 ضوابط سلبية؛ خطوتان في CI (`scripts/restore-test.sh`). ⬜ **السياسة:** Production target / RPO / RTO / Retention / Backup frequency / WAL-PITR / Encryption-access — **TBD** حتى اختيار هدف النشر؛ الاستعادة إلى cluster جديد (الأدوار العامة، `app_owner`) لم تُختبر (L1).

### Gate F — التطبيقات (هيكل فقط)

- [ ] **F1.** تطبيق الويب: Vite + TS + Tailwind RTL، خط عربي (IBM Plex Sans Arabic / Cairo)، i18n، تنقل حسب الدور.
- [ ] **F2.** المصادقة: Supabase Auth + JWT للموظفين؛ حساب الطالب المستقل؛ حساب ولي الأمر OTP/كلمة مرور حسب إعداد المدرسة.
      `docs/F2_AUTHENTICATION.md` — الترتيب: M24 → D1 → D2 → D3 Spike → D3 → D4 → E2E. **D1/M24 🔒** (CI `3f4ae05`؛ 24: 26/26، pytest 68/68)؛ **D2 = B** (M25 + `POST /auth/activate`؛ 25: 36، pytest 81/81، 5 ضوابط سلبية)؛ D3 Spike؛ D4 دلالات A/B/C.
- [ ] **F3.** تحديد المدرسة من الـsubdomain (سياق واجهة فقط — لا يمنح أي صلاحية).
- [x] **F4.** هيكل FastAPI: التحقق من Supabase JWT، استخراج Tenant/Scope/Role، طبقة تفويض مشتركة.
      🔒 **مغلق (2026-09-26، CI `addae39`)** (`docs/F4_API_SECURITY.md`): JWT ← FastAPI ← DB (RLS + `app.*`) ← البيانات؛ لا تفويض موازٍ في FastAPI. اتصال `authenticator`؛ P3 بمفتاح التصدير نفسه عبر `has_permission` + `can_access_school`؛ N5 مُدقَّق ذرياً؛ 48/48 pytest + 4 ضوابط سلبية؛ خطوة CI.

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
| 8 | **ولي الأمر والطالب لا يريان صف المدرسة** (يملكان `school.read` بلا نطاق) — ظهر في تحقق E5 end-to-end؛ بوابة ولي الأمر تحتاج اسم مدرسة الابن | 9 | ملاحظة — لا فجوة الآن |
| 7 | **هل يستطيع `group_manager` تعيين `school_admin`؟** الواقع الحالي (البذر + T8): **لا** — `school_admin` يحمل `security.manage`/`security.export` و`group_manager` لا يملكهما. ليس خطأ تقنياً في M23 بل تطبيق صحيح لـT8. إن كان المطلوب أن يعيّنه، فلا يُمنح `security.*` ببساطة (توسيع سلطة) — يلزم تصميم أدق ضمن الكتالوج المجمَّد أو تعديل صريح لنموذج الأدوار | إدارة المجموعات (2–3) | مفتوح — قرار تجاري |
| 6 | **Future enrollment / pre-registration** — القاعدة الحالية (H2، M12b): *Current school = school of the enrollment having the greatest `effective_from`, regardless of status*؛ فتسجيل مستقبلي في SA2 يُنشأ في مارس لبدء سبتمبر ينقل النطاق التشغيلي فوراً من SA1. يلزم تعريف الفترة الانتقالية (current / future enrollment، registration، effective date، operational school) وأثرها على RLS وإدارة الحساب وولي الأمر. **لا حل مؤقت في M12b** | 4 | مفتوح — design item |

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
| 2026-09-26 | **D2 = B (2026-09-26):** `pending → تغيير الكلمة عبر Supabase Auth → FastAPI → app.activate_first_login() → active`؛ أي فشل ⇒ يبقى pending (fail closed). الدالة تتحقق من الشروط كلها: pending؛ الحساب = auth.uid()؛ حدث `user_updated_password` في سجل Supabase Auth بفاعل = الحساب نفسه بعد لحظة إصدار الكلمة المؤقتة (EXISTS لا «آخر صف»)؛ `user_modified` لا يُقبل؛ idempotent؛ مُدقَّق كـ`activate_first_login`؛ لا مسار بلا auth.uid(). لا trigger على `auth.users` ولا `auth.audit_log_entries`. عقد V9b اختبار CI كـ**Supabase Auth integration assumption**. Admin reset → force change = مسار متحكَّم به مستقل (5c) | F2 — V9/V9b؛ الاقتراح الأول (trigger على `encrypted_password`) مرفوض |
| 2026-09-26 | **استثناء R2 — قائمة مغلقة مسمّاة (M25، 2026-09-26):** `app.auth_uid()` + `app.auth_user_updated_at(uid)` + `app.auth_password_changed_by_self_after(uid, ts)` — ملك `postgres`، `search_path` فارغ، EXECUTE لـ`app_owner` وحده، تعيد لحظة/قيمة منطقية لا صفاً؛ لأن `app_owner` لا يصل إلى schema `auth` و`postgres` لا يملك grant option عليه. أي إضافة للقائمة قرار جديد | M25 |
| 2026-09-26 | **D1 — Student Auth identity (A):** `auth.users.id = student_id` (UUID يولده العميل، مفتاح الـSaga)؛ بريد Auth `student_id@students.smas.invalid` لا يراه الطالب؛ الدخول بـOfficial/Temporary ID يُحَل في FastAPI داخل نطاق الهوية؛ Temporary ← Official لا يغيّر هوية Auth؛ دالة lookup ضيقة قبل JWT (M24) لا تكشف tenant/school/بيانات الطالب ولا تختلف بين موجود وغير موجود، مع rate limiting | F2 |
| 2026-09-26 | **D2 — First-login password change = DB/RLS boundary:** أثناء `pending` ترجع `current_tenant_id()` و`current_profile_id()` NULL؛ التغيير عبر Supabase Auth بجلسة المستخدم؛ انتقال الحالة موثوق — لا عمليتان منفصلتان تسمحان بحالة غير متسقة | F2 — الآلية `docs/F2_AUTHENTICATION.md` §3 |
| 2026-09-26 | **D3 — Tenant users synthetic identity (ii):** لا `guardian phone → auth.users.phone` ولا `staff email → auth.users.email` كهوية Auth عالمية؛ الهاتف/البريد الحقيقي في جدول النطاق؛ الشخص نفسه يملك حساباً مستقلاً لكل Tenant دون أن يكشف Tenant وجوده في آخر. **D3 = Synthetic identity per tenant account APPROVED; session/OTP mechanism = SPIKE REQUIRED.** | F2 — `auth.users.phone`/`email` فريدان عالمياً (مُثبت: `phone_exists`) ⇒ الهوية الأصلية تمنع حساب Tenant ثانٍ وتكشف الوجود عبر الـTenants |
| 2026-09-26 | **D4 — Guardian first-login:** سياسة first-login لولي الأمر تُحدَّد حسب المدرسة المستهدفة أثناء الدخول/الـonboarding، لا حسب المدرسة التي أنشأت الحساب؛ دلالات A/B/C تُثبَّت من PLAN قبل التنفيذ | F2 |
| 2026-09-26 | **O1 — Platform Admin audit visibility:** Tenant Admin may see audit records for Platform Admin reads affecting their own tenant, subject to the existing tenant audit visibility policy. No special F4 exception is introduced. | لا تعديل على M18 ولا إعادة فتح Gate C |
| 2026-09-26 | **FastAPI ← قاعدة البيانات عبر `authenticator` (F4):** اتصال بدور `authenticator` (آلية PostgREST)؛ كل طلب معاملة واحدة بـ`role = authenticated` و`request.jwt.claims` = الـpayload الذي تحقق منه FastAPI (ES256 عبر JWKS)؛ RLS ودوال `app.*` تقرر. الخدمة لا تحمل مفتاح `service_role`؛ تبدّل إلى دور `service_role` لإدراج تدقيق القراءة/التصدير وحده في المعاملة نفسها (fail closed). تدقيق التصدير صف لكل طالب | تمرير JWT إلى PostgREST لا يصل إلى `app.*` والتدقيق فيه غير ذري |
| 2026-09-26 | **البذر من القوائم الصريحة (M23)** — قوائم §4 (المطابقة لكتالوج Matrix §4) هي المرجع لا أعداد العناوين؛ `group_manager`/`school_admin` بقاعدتي الطرح؛ الأعداد: 71/62/59/19/11/11/10/2/6/4 | عناوين §4 وجدول §5 كانت متقادمة |
| 2026-09-26 | **bootstrap_tenant (M22):** يُستدعى بـJWT الـPlatform Admin (`has_platform_permission('tenant.create')`) فالفاعل مُتحقَّق منه في DB ومُدقَّق كـ`platform_admin`؛ T8 يُعفى إعفاءً ضيقاً: سياق المنصة + `tenant.create`، على INSERT في `membership_roles`/`membership_scopes` فقط (Platform Admin بلا سياسة RLS عليهما) | T8 كان سيرفض bootstrap (Platform Admin بلا صلاحيات Tenant — G10)؛ وسياق service يُسقط التحقق من الفاعل (§5.0.2) |
| 2026-09-25 | **إيقاف الـTenant (M21b):** `app.current_profile_id()` و`app.current_tenant_id()` تُرجعان NULL حين يكون الـTenant موقوفاً — الجذر موضعان لأن `has_permission`/`can_access_*` تقرأ `current_profile_id` لا `current_tenant_id`؛ سياق المنصة منفصل ولا يتأثر | suspend_tenant كان لا يقطع وصول أحد |
| 2026-09-25 | **متابعات مسجلة (مراجعة M21):** (1) نقل الطالب بين شعب المدرسة نفسها — عملية متحكَّم بها، المرحلة 2/4؛ (2) تعليق profile / membership — تصميم انتقالات مستقل يفرّق بين النطاقين؛ (3) تاريخ النقل مقابل السنة الدراسية — لا قيد (قرار M10) | — |
| 2026-09-25 | **النقل (M21):** فاعل واحد يملك `enrollment.transfer` ونطاقاً على المدرستين معاً (والطالب في نطاقه الحالي — H2) — نطاقه على الاثنتين يقوم مقام موافقتهما؛ عملية ذرية: القديم `transferred` عند d والجديد من d. سير الطلب/الموافقة بين مدرستين (PLAN §7.10) مؤجل للمرحلة 4 بجدوله. `close_enrollment` لا تقبل `transferred` | لا جدول طلبات في Foundation |
| 2026-09-25 | **تكليف الموظف (M21):** إنهاء فقط؛ العودة = تكليف جديد (قرار b)؛ لا إعادة فتح لفترة مغلقة. **حالات الموظف:** `active ↔ on_leave`، `active|on_leave → ended` (يُغلق تكليفاته النشطة في العملية نفسها)، `ended → archived`؛ لا عودة من ended/archived (إعادة التوظيف سجل جديد عبر `provision_staff`) | الموظف المنتهي بلا تكليف نشط لا تصله مدرسة (H2) — الأرشفة بنطاق tenant |
| 2026-09-25 | **Secure-by-default (M20):** ابتداءً من M20، كل migration تنشئ جدولاً جديداً يجب أن تمنح `authenticated` الصلاحيات المطلوبة صراحةً، ولا تعتمد على default grants: جدول جديد ← RLS + FORCE ← منح صريح فقط ← لا صلاحيات كتابة ضمنية. M20 = baseline privilege contract | منح Supabase الافتراضي كان يعطي `anon` و`authenticated` كل شيء على كل جدول جديد |
| 2026-09-25 | **`families.family_code` ثابت (M20b)** — قاعدة الثوابت تتقدم على صف §4.6؛ أي تغيير إداري لاحق قرار مستقل بمسار متحكَّم به | تعارض داخل §4.6 |
| 2026-09-25 | **`roles.status` (M19):** لا UPDATE مباشر لـ`authenticated` (يُسحب من سجل §4.6 في M20)؛ تفعيل/تعطيل الدور المخصص انتقال حالة في M21 يتحقق من: السياق، `role.update`، أن الدور مخصص ومملوك للـTenant، **وعند التفعيل أن صلاحيات الدور ⊆ صلاحيات الفاعل**، `FOR UPDATE`، انتقال صريح، تدقيق. لا مفتاح جديد في الكتالوج | إعادة تفعيل دور يحوي صلاحيات لا يملكها المفعّل تتجاوز T8 (نمط M17b نفسه) |
| 2026-09-25 | **تكليف الموظف (M17، خيار b):** INSERT لتكليف جديد مشروع (توظيف متزامن) بـ`staff.assign` + `can_access_school(target_school)` — حتى لموظف انتهى تكليفه السابق في المدرسة نفسها؛ الوصول نتيجة طبيعية لعلاقة جديدة مصرح بها. إنهاء/إعادة فتح تكليف قائم = انتقال حالة (M21). أي قاعدة «موافقة المدرسة الأخرى» قرار أعمال مستقل لاحق | الموظف يقبل تكليفات نشطة متزامنة، فلا مفهوم «أحدث» كالطالب |
| 2026-09-25 | **`staff_school_assignments.status` و`effective_to` ليسا أعمدة يكتبها العميل؛ الإنهاء وإعادة الفتح عبر دوال انتقال حالة في M21 (auth.uid()، الصلاحية، سلطة النطاق، FOR UPDATE، انتقالات صريحة، تدقيق)** (M17b) | H2: إعادة فتح تكليف منتهٍ بـCRUD كانت تعيد للمدرسة السابقة الوصول التشغيلي لموظف انتقل |
| 2026-09-25 | **enrollments INSERT و UPDATE تشترطان أيضاً `app.student_in_scope(student_id)`** (M17) | تحت H2 التسجيل الأحدث = المدرسة التشغيلية؛ بدونه تنتزع مدرسة أخرى الطالب بإدراج تسجيل لاحق (التفاف على `enrollment.transfer`)، وتعدّل المدرسة السابقة صفها التاريخي. النقل عبر M21 |
| 2026-09-25 | **منح/سحب النطاق يشترط `can_manage_membership`** (M15) | كـ`membership_roles` (F4)؛ وإلا تسري صلاحيات أدوار عضوية لا يديرها الفاعل في مدرسته |
| 2026-09-25 | **T8 يشمل منح النطاق (M19):** **عند منح Scope لعضو، يجب ألا يؤدي المنح إلى تمكين العضو المستهدف من أي Permission داخل ذلك الـScope تتجاوز Permissions المانح الفعلية داخل نفس الـScope.** | `delegation cannot expand authority` — منح النطاق لا يضيف صلاحية لكنه يفعّل صلاحيات أدوار الهدف داخل النطاق |
| 2026-09-25 | **EXECUTE بفئتين (M20):** RLS helpers تستدعيها سياسة؛ controlled functions في allowlist | حارس M15 «كل EXECUTE تستدعيه سياسة» صالح حتى M20 فقط |
| 2026-09-25 | **`app.membership_id_of()`** (M15) | دالة ربط بدل استعلام `memberships` داخل السياسة (§1.1 بند 6)؛ القرار يبقى في `can_see/can_manage_membership` |
| 2026-09-25 | **PA catalog** — `platform_admin_roles` و`platform_admin_role_permissions` بلا سياسة عميل (service فقط) | تعارض RLS §10.6 (`is_platform_admin()` وحدها) مع §11/C3؛ حُسم لصالح C3 و G8 |
| 2026-09-25 | **EXECUTE مع السياسات** — كل migration سياسات تمنح `authenticated` EXECUTE على الدوال التي تستدعيها سياساتها مباشرة؛ `anon` لا شيء؛ M20 يبقى للأعمدة والتدقيق النهائي | بدونه تفشل استعلامات `authenticated` كلها من M14 حتى M20 |
| 2026-09-25 | **H2** — A school is operationally in scope for a student only through the student's current/authorized enrollment in that school. Historical enrollments provide historical access only where a specific permission/policy explicitly permits historical records; they do not grant operational access to the student's current account or guardian account. | `Historical Enrollment ≠ Current Operational Access`؛ الطالب ← أحدث تسجيل، ولي الأمر ← ارتباط نشط، الموظف ← تكليف نشط؛ لا هوية تاريخية في Foundation. منفذ في M12b |
| 2026-09-24 | **H1** — A secretary may register a new student in a school that belongs to a group. The secretary requires `student.create` with school scope; this does not grant group scope. When the target school belongs to a group, the student's identity scope is derived from the target school's group and is not client-selectable. The student's enrollment is created for the target school in the same controlled provisioning operation. | كشفه `12_helpers`: `can_access_identity_scope(GA)` = false لسكرتير SA1. التطبيق في M22 (§5.2 من المواصفة) |
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
| 2026-09-26 | ✅ **F2/D2 = B + M25** — تفعيل متحكَّم به fail-closed بإشارة سجل Supabase Auth؛ بوابة الجذر؛ استثناء R2 موسّع بقرار؛ pgTAP 25: 36؛ pytest 81/81 (عقد V9b + D2)؛ 5 ضوابط سلبية | `supabase/migrations/20260926160000_first_login_credential.sql`, `supabase/tests/{05,20,25}_*.test.sql`, `services/api/**`, `docs/F2_AUTHENTICATION.md`, `docs/DATA_DICTIONARY_v1.md`, `docs/RLS_MODEL_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | 🔬 **V9** — trigger على `encrypted_password` **يفتح الحساب** عند كتابة المدير (5a/5b) ولا إشارة في `auth.users` تميّزه؛ الإشارة الموثوقة في سجل Supabase Auth: `user_updated_password` بفاعل الحساب، في معاملة الكتابة نفسها، ولا يكتبه المدير؛ الخيار B (تفعيل متحكَّم به fail-closed بهذه الإشارة) مقترح — لا migration | `spikes/v9/*`, `docs/F2_AUTHENTICATION.md`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **D1/M24 مغلقان** — CI أخضر (`3f4ae05`)؛ الطالب `withdrawn` لا يدخل (سلوك مقصود)؛ D2: V9 إلزامي بحالاته الثماني، ولا migration قبل مراجعة new/same/admin reset/failed update؛ البديل المحافظ (تفعيل متحكَّم به fail-closed) مفتوح | `CLAUDE.md`, `docs/F2_AUTHENTICATION.md` |
| 2026-09-26 | ✅ **F2/D1 + M24** — هوية الطالب الاصطناعية؛ `resolve_student_login`؛ Saga الإنشاء والدخول بالمعرّف؛ D1 مفروض في DB؛ 24: 26/26، 22: 54، pytest 68/68، 4 ضوابط سلبية؛ قرارات D1–D4 مسجلة | `supabase/migrations/20260926140000_student_login.sql`, `supabase/tests/{22,24}_*.test.sql`, `supabase/seed.sql`, `services/api/**`, `docs/F2_AUTHENTICATION.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `.env.example`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | 🔒 **F4 مغلق** — CI أخضر (`addae39`)؛ O1 قرار مسجل؛ تدقيق التصدير صف لكل طالب معتمد؛ ملاحظة الإنتاج (ES256) باقية | `CLAUDE.md`, `docs/F4_API_SECURITY.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | ✅ **F4** — هيكل FastAPI: تحقق ES256 عبر JWKS، معاملة `authenticated` لكل طلب عبر `authenticator`، P3 و N5 بتدقيق ذري؛ 48/48؛ ملاحظة O1 (tenant_admin يرى قراءات المنصة لـTenant نفسه) | `services/api/**`, `docs/F4_API_SECURITY.md`, `.github/workflows/ci.yml`, `.env.example`, `docs/E6_BACKUP_RESTORE.md`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | 🔒 **E6 التقني و Gate E مغلقان (E1–E6)** — CI أخضر (`c985a0d`، https://github.com/ahmedhmmad/sMas/actions/runs/36200782679)؛ **Production Backup Policy: TBD** (RPO، RTO، retention، frequency، PITR، مكان الحفظ، encryption/access، restore procedure، واستعادة إلى خادم جديد بالكامل بأدواره مثل `app_owner`) — حد نطاق لا فشل؛ لا إعادة فتح لـE1–E5 | `CLAUDE.md`, `docs/E6_BACKUP_RESTORE.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | ✅ **E6 (التقني)** — اختبار الاستعادة من backup كامل: البصمة + الحزمة على النسخة المستعادة + CI؛ كشف ف1 (خصائص القاعدة لا يحملها `pg_dump` بلا `--create` ← `public` بلا CREATE) و ف2 (`07` I12 طابق القيد الخطأ بمصادفة ترتيب الفهارس ← عُزل)؛ السياسة TBD | `scripts/restore-test.sh`, `scripts/db-fingerprint.sql`, `docs/E6_BACKUP_RESTORE.md`, `supabase/tests/07_memberships.test.sql`, `docs/TRACEABILITY_E1_E4.md`, `.github/workflows/ci.yml`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **E5 مغلقة** | `CLAUDE.md` |
| 2026-09-26 | ✅ **E5** — seed التطوير عبر مسار التطبيق، ذاتي التحقق؛ CI: اختبارات بلا seed ثم تطبيق الـseed | `supabase/seed.sql`, `.github/workflows/ci.yml`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **E1–E4 مغلقة** — مصفوفة التتبع مرجع ما تثبته الاختبارات؛ R5 يبقى ⏳ D1 | `CLAUDE.md` |
| 2026-09-26 | ✅ **Gate E — E1–E4 traceability** — مصفوفة تتبع كاملة؛ 4 فجوات أُغلقت باختبارات فقط (G1 مطابقة أسماء القيود، G2 FK العضوية عبر Tenant، G3 read≠export، G4 T3 تغطية SELECT)؛ 1157/1157 | `docs/TRACEABILITY_E1_E4.md`, `supabase/tests/{02..08,10,11,13,17,21,22}_*.test.sql`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **M23 و Gate C مغلقان (M01–M23)** — 1155/1155، CI أخضر (`586b80d`)؛ تصحيح أعداد §4/§5 توثيقي لا تغيير في النموذج؛ ملاحظة تصميم مفتوحة: `group_manager` ← `school_admin` (§6 بند 7) | `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | ✅ **M23** — البيانات المرجعية | `supabase/migrations/20260926002524_reference_data.sql`, `supabase/tests/23_reference_data.test.sql`, `supabase/tests/{05,06,07,11,14..22}_*.test.sql`, `docs/ROLE_PERMISSION_SEED_v1.md`, `docs/*`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **M22 مغلقة** | `CLAUDE.md` |
| 2026-09-26 | ✅ **M22** — دوال الإنشاء + bootstrap_tenant | `supabase/migrations/20260926000152_provisioning_functions.sql`, `supabase/tests/22_provisioning.test.sql`, `supabase/tests/20_column_grants.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **M21b مغلقة** — التصحيح (الجذر في الدالتين) معتمد؛ 1068/1068، CI أخضر (`d1559a0`) | `CLAUDE.md` |
| 2026-09-25 | ✅ **M21b** — إيقاف الـTenant فعّال | `supabase/migrations/20260925231300_tenant_suspension.sql`, `supabase/tests/21b_tenant_suspension.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M21 مغلقة** — 84/84، 1053/1053، CI أخضر (`2c02d36`)؛ الافتراضيات الخمسة والـinvariants معتمدة | `CLAUDE.md` |
| 2026-09-25 | ✅ **M21** — دوال انتقال الحالة | `supabase/migrations/20260925225414_state_functions.sql`, `supabase/tests/21_state_functions.test.sql`, `supabase/tests/20_column_grants.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M20 و M20b مغلقتان** — تفسير «أعمدة الأعمال» معتمد؛ secure-by-default قاعدة تنفيذية؛ `family_code` ثابت؛ حذف السياسة الميتة | `supabase/migrations/20260925222337_privileges_followup.sql`, `supabase/tests/{14,20}_*.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | ✅ **M20** — طبقة الامتيازات الفعلية | `supabase/migrations/20260925205401_privileges.sql`, `supabase/tests/20_column_grants.test.sql`, `supabase/tests/{03,11,14,15,16,17,18,19}_*.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M19 مغلقة** — 31/31، 903/903، CI أخضر (`9a1bcf7`)؛ T8 بلا تعديل؛ قرار `roles.status` → M20/M21 | `CLAUDE.md`, `docs/*` |
| 2026-09-25 | ✅ **M19** — T8: role escalation، permission escalation، منح النطاق؛ 07 و15 عُدّلا (claims سياق service؛ دور ضمن صلاحيات الفاعل) | `supabase/migrations/20260925203528_authz_integrity.sql`, `supabase/tests/19_t8.test.sql`, `supabase/tests/{07,15}_*.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M18 مغلقة** — 24/24، 872/872، CI أخضر (`e56e937`)؛ إبقاء `platform_admin_roles/_role_permissions` في رؤية تدقيق المنصة (قراءة الجدول مباشرة service-only ≠ تدقيق تغييراته بـ`audit.read` — audit completeness)؛ `CASE` معتمد | `CLAUDE.md` |
| 2026-09-25 | ✅ **M18** — رؤية التدقيق F10/F11، E15، E16 | `supabase/migrations/20260925201639_policies_audit.sql`, `supabase/tests/18_audit_visibility.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M17 و M17b مغلقتان** — 102/102، 848/848، CI أخضر (`6d7c925`)؛ خيار (b) لتكليف الموظف؛ R5 TODO (D1)؛ M20 يسحب صراحةً `TRUNCATE`/`TRIGGER`/`REFERENCES` من `anon` و`authenticated` | `CLAUDE.md`, `docs/*` |
| 2026-09-25 | ✅ **M17b** — `staff_school_assignments.status` و`effective_to` ليسا أعمدة يكتبها العميل؛ الإنهاء وإعادة الفتح عبر دوال انتقال حالة في M21 (auth.uid()، الصلاحية، سلطة النطاق، FOR UPDATE، انتقالات صريحة، تدقيق)؛ ضابط سلبي للرفض المباشر | `supabase/migrations/20260925195221_staff_assignment_columns.sql`, `supabase/tests/17_relationship.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-25 | ✅ **M17** — سياسات الأشخاص والتسجيلات؛ R1–R4، E1، E2، E7؛ منع انتزاع الطالب بتسجيل لاحق | `supabase/migrations/20260925193159_policies_people_enrollment.sql`, `supabase/tests/17_relationship.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M16 مغلقة** — 40/40، 746/746، CI أخضر (`e2e2725`)؛ مفاتيح `academic_years` من الكتالوج معتمدة | `CLAUDE.md` |
| 2026-09-25 | ✅ **M16** — سياسات الجداول الأكاديمية؛ فصل الصلاحيات لكل مورد؛ نقل صف إلى مدرسة خارج النطاق مرفوض | `supabase/migrations/20260925190756_policies_academic.sql`, `supabase/tests/16_academic.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M15 مغلقة** — 104/104، 706/706، CI أخضر (`a22cdab`). متطلبات M19 (T8): role escalation، permission escalation عبر `role_permissions`، ومنح النطاق لا يمكّن الهدف فوق صلاحيات المانح داخل النطاق. M20: فحص EXECUTE بفئتين (helpers / controlled allowlist) يحل محل حارس M15 | `CLAUDE.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `docs/PLAN_v3.md` |
| 2026-09-25 | ✅ **M15** — سياسات التفويض؛ منع التصعيد F1–F5 (عدا ما ينتظر T8)؛ اختبارات «قبل السياسات» في 03/07 وقوائم EXECUTE الحرفية في 12/14 استُبدلت بحقيقة ما بعد M15 وحارس دائم | `supabase/migrations/20260925182159_policies_authz.sql`, `supabase/tests/15_escalation.test.sql`, `supabase/tests/{03,07,12,14}_*.test.sql`, `docs/*`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M14 مغلقة** — 96/96، 602/602، CI أخضر (`290a566`)؛ اعتماد إضافة WITH CHECK (تعديل RLS §7)؛ سياسة `identity_scopes` في M14 **نهائية** — M17 لا تمسّها | `CLAUDE.md`, `docs/RLS_MODEL_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md` |
| 2026-09-25 | ✅ **M14** — سياسات Tenancy/Platform؛ I1–I7؛ قراران: كتالوج Platform Admin لـservice فقط، و EXECUTE مع السياسات لا في M20 | `supabase/migrations/20260925154337_policies_tenancy_platform.sql`, `supabase/tests/14_isolation.test.sql`, `docs/RLS_MODEL_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-25 | 🔒 **M13 مغلقة** — 61/61، 506/506، CI أخضر (`320f883`)؛ اعتماد: Foundation = 29 جدولاً، RLS enforcement 29/29، سياسات التطبيق 28 و`auth_identities` مستثنى صراحةً؛ فحص «لا سياسات قبل M14» داخل الـmigration | `CLAUDE.md`, `docs/*` |
| 2026-09-25 | ✅ **M13** — `rls_enable`: بوابة RLS على 29 جدولاً بالاسم؛ ضوابط سلبية (بلا FORCE، بلا RLS، جدول في `app`، سياسة، جدول غير مدرج) كلها تفشل كما يجب | `supabase/migrations/20260925151821_rls_enable.sql`, `supabase/tests/13_rls_enable.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `docs/RLS_MODEL_v1.md`, `CLAUDE.md` |
| 2026-09-25 | 🔒 **M12 و M12b و H1/H2 مغلقة** — CI أخضر على `ab65c75`, `7c1cbe2`, `6c4e32c`, `18c70b2`؛ 445/445 | `CLAUDE.md` |
| 2026-09-25 | H2 مغلق قراراً وتنفيذاً (بانتظار CI)؛ future enrollment مسجل كـdesign item للمرحلة 4 (§6 بند 6) | `CLAUDE.md` |
| 2026-09-25 | ✅ **M12b** — H2 منفذ: أحدث تسجيل، ارتباط نشط، تكليف نشط؛ 12b 14/14 | `supabase/migrations/20260925144149_authz_helpers_current_scope.sql`, `supabase/tests/12b_current_scope.test.sql`, `supabase/tests/12_helpers.test.sql`, `docs/RLS_MODEL_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-25 | ✅ **H2 محسوم** — المدرسة السابقة لا تدير حساب الطالب ولا ولي أمره بتسجيل تاريخي | `CLAUDE.md`, `docs/PLAN_v3.md`, `docs/RLS_MODEL_v1.md` |
| 2026-09-24 | ✅ **H1 محسوم** — السماح للسكرتير بنطاق المدرسة، النطاق مشتق من المدرسة الهدف لا من العميل | `CLAUDE.md`, `docs/PLAN_v3.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md` |
| 2026-09-24 | ✅ **M12** — دوال العلاقة الثمانية + `can_see/can_manage_membership`؛ كشف H1 (نطاق هوية Group مغلق أمام عضو نطاق المدرسة)؛ 431/431 | `supabase/migrations/20260924234528_authz_helpers.sql`, `supabase/tests/12_helpers.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | 🔒 **M11 مغلقة** — 44/44، 370/370، CI أخضر (`e4f8790`)؛ الانحرافات الخمسة معتمدة؛ متطلب M21 وتبعية M18/M20 موثقان | `CLAUDE.md` |
| 2026-09-24 | ✅ **M11** — `audit_log` (بلا FK)، T5 (صف + جملة)، T7 على 28 جدولاً بفاعل مستقل (tenant_user / platform_admin / system)؛ سحب UPDATE/DELETE/TRUNCATE من كل أدوار الـAPI؛ 370/370 | `supabase/migrations/20260924203358_audit.sql`, `supabase/tests/11_audit.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | 🔒 **M10 مغلقة** — 26/26، 326/326، CI أخضر (`c4e84f9`)؛ كل حالة رفض مُثبتة بقيدها؛ استثناء I38 مقبول؛ لا قيد على `effective_from` مقابل السنة (يُترك لقواعد القبول) | `CLAUDE.md` |
| 2026-09-24 | ✅ **M10** — `enrollments`: I39 بـFK واحد إلى `sections`، G3 بثلاثة FKs مركّبة، G6 عبر `EXCLUDE`، B6؛ 326/326 | `supabase/migrations/20260924202242_enrollments.sql`, `supabase/tests/10_enrollments.test.sql`, `docs/DATA_DICTIONARY_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | 🔒 **M09 مغلقة** — 61/61، 300/300، CI أخضر (`27536b7`)؛ انحراف `full_name` مقبول؛ قرار تعدد علاقات الـprofile | `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-24 | ✅ **M09** — `staff`، `staff_school_assignments`، `families`، `students` (A4: بلا `school_id`/`group_id`، `identity_scope_id` و`student_profile_id` NOT NULL؛ G3: `(id, identity_scope_id)`)، `guardians`، `student_guardians`؛ I22–I32 بأسماء القيود؛ 300/300 | `supabase/migrations/20260924200821_people.sql`, `supabase/tests/09_people.test.sql`, `docs/DATA_DICTIONARY_v1.md`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | ✅ **M08** — `academic_years` (I33، I34)، `terms` (I35 إعلاني عبر FK بتواريخ السنة، I36)، `stages`، `grade_levels`، `sections` (I37)؛ 239/239 | `supabase/migrations/20260924200246_academic_structure.sql`, `supabase/tests/08_academic_structure.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | ✅ **M07** — `memberships` (I12)، `membership_roles` (I16 إعلاني)، `membership_scopes` (I13–I15، NULLS NOT DISTINCT)؛ `has_permission()` (G10)، `can_access_tenant/group/school()` (F1)؛ 209/209 | `supabase/migrations/20260924195708_memberships.sql`, `supabase/tests/07_memberships.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
| 2026-09-24 | ✅ **M06** — `permissions` (I18)، `roles` + `owner_key` (I16، I17)، `role_permissions`، `platform_admin_role_permissions`؛ `has_platform_permission()` (G10، C3)؛ 163/163 | `supabase/migrations/20260924195208_permission_catalog_tables.sql`, `supabase/tests/06_permission_catalog_tables.test.sql`, `docs/DB_IMPLEMENTATION_SPEC_v1.md`, `CLAUDE.md` |
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
