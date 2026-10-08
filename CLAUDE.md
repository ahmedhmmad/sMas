# CLAUDE.md — دليل التنفيذ وتتبع التقدم

**المشروع:** نظام إدارة المدارس متعدد المستأجرين (Multi-Tenant SMS)
**تاريخ الإنشاء:** 2026-09-22
**آخر تحديث:** 2026-10-07
**المرحلة الحالية:** 🔒 **المرحلة 1 — الأساس (Foundation) مكتملة (2026-10-02)** · 🔒 **المرحلة 2 — إعداد المدرسة (School Setup) مكتملة (2026-10-07)** — 2A (P2-A…P2-E، CI `3c68a7d`) و2B (2B-1…2B-6، CI `94d0ccb`)؛ القبول: `docs/PHASE2A_ACCEPTANCE.md`، `docs/PHASE2B_ACCEPTANCE.md`. **المرحلة 2 baseline مغلقة — لا تعديل وظيفي عليها؛ المؤجل (backup/restore الإنتاجي لمحتوى الملفات، جداول الدوام المؤقتة، عرض الشبكة) قرار/نطاق جديد في مرحلته.** **المرحلة 3 (الموظفون والتكليفات): خطة النطاق ✅ معتمدة — 🟢 GO لـ3A؛ 3-1 (ملف الموظف) 🔒 مغلقة (CI `ee68f5a`)؛ 3-2 (الحساب والدور والنطاق) جارية — M47 (فرع الموظف في `can_manage_membership`) 🔒 مغلقة (CI `c80ad44`)؛ 3-2 (الحساب والدور والنطاق) 🔒 مغلقة (بلا migration، CI `025b48c`)؛ 3-3 (التكليفات + P10 ودورة حياة التفويض) ✅ implemented, pending CI closure (M48، M49)** (`docs/PHASE3_SCOPE.md`) (السجل: **Gate C 🔒 M01–M23**؛ **Gate E 🔒 E1–E6** — Production Backup Policy TBD؛ **Gate F 🔒 F1–F4**؛ **🔒 Stage 1** — R1–R10 + M31/M32، CI `f41b0ff`)

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

**الحالة:** المستودع على GitHub: `ahmedhmmad/sMas` (`main`). CI أخضر. 54 migration (M01–M49)؛ pgTAP 2390 (52 ملفاً)، pytest 303 (منها 3 `storage` محلية — مستبعدة صراحةً في CI)، Vitest 152، Playwright 36 (منها 1 `@storage`).

```
/docs                 وثائق التصميم + وثيقة لكل Gate + STAGE1_REVIEW  ✅
/supabase             54 migration + 52 ملف pgTAP + seed.sql   ✅
/spikes/m00           تحقق V1–V8 — ليست migrations          ✅
/scripts              check-secrets، podman-relay، restore-test، db-fingerprint  ✅
/.github/workflows    ci.yml                               ✅
/apps/web             React + TS + Vite + Tailwind (RTL)   ✅ F1 (هيكل)
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
| M26 | `tenant_account_login` (F2/D3) | ✅ 46/46 | OTP وكلمة المرور لحسابات Tenant قبل JWT؛ `login_challenges` (الجدول 30، بلا وصول عميل ولا T7)؛ أعمدة قفل `staff` + بريد فريد داخل الـTenant؛ I1؛ **I2 مفروض في `provision_account`**؛ 11/13/14/20/22 على الجدول 30 و I2 |
| M27 | `guardian_onboarding` (F2/D4) | ✅ 41/41 | `schools.guardian_first_login_mode`؛ حساب ولي الأمر يولد pending؛ بوابة OTP بالمدرسة الهدف (A: يبدأ، B: يفعّل، C: لا OTP)؛ إصدار C بـ`security.manage`؛ `otp_*` بمعامل المدرسة (استبدلت نسختي M26) |
| M28 | `my_permissions` (F1.3) | ✅ 20/20 | effective keys من الجداول بشروط `has_permission`/`has_platform_permission` نفسها؛ مطابقة المحمولين على الكتالوج لكل فاعل؛ 3 ضوابط سلبية (الحالة، السياق، إسناد المنصة) |
| M29 | `platform_reads` (F1/W1) | ✅ 15/15 | الجداول الثلاثة ضمن N5: حذف سياسات Platform Admin الثماني؛ `platform_read_tenants([id])` تقرأ وتدقّق في عبارة واحدة (fail closed)؛ 14 و21b على الحقيقة الجديدة؛ ضابطان سلبيان |
| M30 | `tenant_host_context` (F3) | ✅ 49/49 (1395/1395) | `platform_tenants.host_label` (DNS، محجوزات، فريد، بلا GRANT)؛ `app.login_context` المحلّل الوحيد — host يسمّي مدرسة مؤرشفة/غير موجودة لا يجد حساباً؛ دوال الدخول الست بالـlabel؛ `bootstrap_tenant` بتوقيع جديد؛ حارس: لا سياسة تقرأ الـlabel؛ 3 ضوابط سلبية |
| M30b | `host_dns_labels` (مراجعة F3) | ✅ 22/22 (1417/1417) | `host_label` و`schools.slug` labels DNS (RFC 1123): لا شرطة ختامية؛ الاسمان نفسيهما (استبدال)؛ فحص البيانات القائمة قبل القيد يوقف الـmigration بقائمة مسمّاة — لا تصحيح تلقائي؛ ضابط سلبي على نص الـmigration نفسه |
| M31 | `security_relationship_source` (مراجعة Stage 1 — S1، S2) | ✅ 40/40 (1480/1480) | **S1:** `student_guardians.relationship_source` (`direct`\|`provisioned`، افتراضي `direct`، خارج GRANT؛ القائم `direct` — fail-closed)؛ `provision_guardian` تكتب `provisioned` وحدها؛ `guardian_account_for_issue` تشترط ارتباطاً `provisioned` نشطاً بطالب في النطاق الحالي. **S2:** `students_update` WITH CHECK += `family_id IS NULL OR family_in_scope(family_id)` (لقطة الجملة، بلا دالة جديدة). السلسلة كاملة تفشل عند إدارة الحساب؛ الربط والقراءة و`provision_guardian` تعمل؛ 5 ضوابط سلبية |
| M32 | `privilege_index_followup` (مراجعة Stage 1 — C1–C3) | ✅ (20: +2، 31: +1؛ 1483/1483) | لا امتياز لـ`anon`/`authenticated` على sequences قائمة أو مستقبلية؛ سحب `MAINTAIN` وافتراضيّه؛ فهرسا `platform_tenant_id` (`families`، `login_challenges`)؛ حارس «كل FK له فهرس» باستثناء FK الهوية الموثق؛ 10 ضوابط سلبية |
| M33 | `academic_year_guard` (Phase 2A / P2-B — ف4) | ✅ 37/37 (1520/1520) | T10 `BEFORE UPDATE` على `academic_years`: `planned` الاسم والتواريخ، `active` الاسم فقط، `closed` immutable (حتى no-op)، الانتقالات المعلنة فقط، `school_id` ثابت — على كل مسار (العميل، دوال M21، المسار المميّز)؛ الدالة `SECURITY INVOKER` بلا EXECUTE لأدوار الـAPI؛ `08` نُقل اختبار I35 إلى سنة `planned`؛ `31`: +trigger و+دالة (72)؛ 9 ضوابط سلبية |
| M34 | `term_lifecycle` (Phase 2A / P2-B — ف5) | ✅ 70/70 (1590/1590) | `terms_active_uq` (فصل نشط واحد لكل سنة)؛ T11 `BEFORE INSERT OR UPDATE` `SECURITY DEFINER` (يولد `planned`، الانتقالات المعلنة، النشط داخل سنة نشطة، `active` الاسم فقط، `closed` وفصول السنة المغلقة مجمدة، هوية الفصل ثابتة)؛ `activate_term`/`close_term` بـ`term.manage`؛ `close_academic_year` يرفض مع فصل نشط؛ `status` خارج منح العميل؛ الصلاحية والنطاق في RLS والدوال لا في الحارس (مُثبت)؛ allowlist +2، `31`: 75 دالة؛ 22 ضابطاً سلبياً كلٌّ يضرب حارسه |
| M35 | `structure_guards` (Phase 2A / P2-B — ف6، Q7) | ✅ 66/66 (1656/1656) | T12: ثلاثة حراس `SECURITY DEFINER` — شعبة نشطة (سنة غير مغلقة) ⇒ صف نشط ⇒ مرحلة نشطة من الجهتين؛ هوية الشعبة (مدرسة، سنة، صف) ثابتة؛ بنية السنة المغلقة مجمدة؛ لا تعطيل لشعبة فيها تسجيلات نشطة؛ `school_id` خارج UPDATE في الجداول الثلاثة؛ الحالة تبقى عموداً بـ`*.manage` (لا دالة ولا مفتاح)؛ `16`: منع النقل بمنح العمود و`WITH CHECK` طبقة ثانية؛ `31`: 78 دالة؛ 21 ضابطاً سلبياً |
| M36 | `school_slug` (Phase 2A / P2-B — ف3، Q6) | ✅ 46/46 (1702/1702) | `slug` خارج منح UPDATE؛ `app.set_school_slug` المكان الوحيد (`school.update` + نطاق + سبب + مدرسة `active`)؛ الصيغة والتفرد بالقيدين القائمين وحدهما؛ الفشل بلا أثر (لا slug ولا تدقيق ولا سياق عالق)؛ القديم يتحرر فوراً؛ **العضويات والنطاقات ونطاقات الهوية وصف المدرسة متطابقة قبل وبعد** — الـhost يتبع الـslug والتفويض لا يتحرك؛ `30b` عبر الدالة؛ `31`: 79 دالة؛ 14 ضابطاً سلبياً |
| M37 | `copy_sections` (Phase 2A / P2-B — القرار 8، Q5) | ✅ 41/41 (1743/1743) | عملية domain ذرية: شعب `active` تحت صفوف `active` إلى سنة `planned` في المدرسة نفسها؛ المفتاح الطبيعي `(school, year, grade_level, name)` — المطابق «منسوخ سابقاً» لا يُمس، غير المطابق يُفشل الكل؛ التشغيل الثاني 0 والموجود متطابق بايتياً؛ لا تسجيلات ولا فصول؛ صف تدقيق domain + T7 لكل شعبة؛ لا `school_id` من العميل؛ T12 على المسار؛ `31`: 80 دالة؛ 18 ضابطاً سلبياً |
| M38 | `subject_permissions` (Phase 2B / 2B-1 — B10) | ✅ (23: 75 مفتاحاً، 265 ربطاً) | أول فتح للكتالوج المجمَّد بقرار PLAN §9: `subject.read`/`subject.manage`؛ 10 روابط مطابقة لقوائم ROLE_PERMISSION_SEED §4 (ta/gm/sa المفتاحان؛ السكرتير والمحاسب والمعلم والمرشد القراءة)؛ حارس داخل الـmigration؛ `seed.sql` حارسه 75/265؛ `34`–`37` «لا مفتاح من هذه الـmigration» |
| M39 | `subjects` (Phase 2B / 2B-1 — B9، B15) | ✅ 54/54 | `subjects` [S] و`grade_subjects` [S عبر السنة] (الجدولان 31، 32): RLS + FORCE، 6 سياسات، منح صريح (الرمز والهوية خارج UPDATE، الربط يولد active)؛ **T13**: هوية ثابتة، السنة المغلقة مجمدة، الربط النشط ⇒ صف نشط ومادة نشطة من الجهتين (امتداد T12 في `tg_grade_level_guard`)؛ UPDATE أعمى (بلا WHERE/RETURNING) يثبت أن سياسة UPDATE تحمل النطاق بنفسها؛ `11`/`13`/`14`/`20`/`31` حُدِّثت |
| M40 | `copy_grade_subjects` (Phase 2B / 2B-1 — B13) | ✅ 36/36 | عقد M37: المفتاح `(year, grade_level, subject)`؛ المطابق (active + الحصص + المجموع) «منسوخ سابقاً»، المتعارض — ومنه المعطَّل أو اختلاف «المجموع» وحده — يُفشل الكل؛ لا ربط لصف أو مادة معطَّلين؛ ذري؛ صف domain + T7؛ 36 ضابطاً سلبياً DB (M38–M40) و7 على الـAPI |
| M41 | `calendar` (Phase 2B / 2B-2 — B7، B8، B12؛ C1–C5) | ✅ 79/79 | `calendar_weekdays` (بلا كتابة للعميل — `set_calendar_weekdays`) و`calendar_exceptions` (الجدولان 33، 34): RLS + FORCE، 4 سياسات، منح صريح؛ **T14**: «اليوم» بتوقيت `schools.timezone` (مُثبت بمدرستين UTC+14 و UTC−11)، السبب إلزامي في سنة نشطة على كل مسار ومنه `postgres` (C3)، الإضافة من اليوم، العطلة الجارية `end_date` وحده والقديم والجديد ≥ اليوم (C4)، الإلغاء نهائي، المغلقة مجمدة، اليوم الاستثنائي ليس يوم دوام (C5)؛ C2 التعريف الأول مرة واحدة؛ `is_school_day` بلا EXECUTE لأدوار الـAPI؛ `14` fixture: planned ← active |
| M42 | `copy_calendar_weekdays` (Phase 2B / 2B-2 — B13) | ✅ 31/31 | عقد M37/M40: الموجود `inactive` تعارض يُفشل الكل؛ الاستثناءات المؤرخة لا تُنسخ؛ ضوابط سلبية: DB 53 (M41–M42) و API 10 |
| M43 | `bell_schedules` (Phase 2B / 2B-3 — B11، B12؛ D1–D7) | ✅ 76/76 | الجداول 35–37: `bell_schedules` (فترة في سنة)، `bell_periods` (حصة/استراحة لكل يوم — D1؛ `id` معرّف ثابت للفتحة والرقم الظاهر مشتق من `start_time` — D5)، `grade_level_bell_schedules` (الصف ← جدول — D2)؛ RLS + FORCE، 9 سياسات، منح صريح؛ **D6** `bell_periods_no_overlap` قيد DB على كل مسار (`09:00–10:00` مع `09:30–10:30` يفشل، `10:00–11:00` مسموح، جدولان مختلفان يتداخلان)؛ **T15**: حالة السنة بسبب (D3)، الحصة النشطة تحت جدول نشط وعلى يوم دوام نشط (D4)، لا تعطيل لجدول له حصص نشطة أو إسناد، الهوية؛ **D4 الجهة الثانية** باستبدال `tg_calendar_weekday_guard` (M41 لا تُعدَّل)؛ `copy_bell_day` بلا دمج صامت |
| M44 | `copy_bell_schedules` (Phase 2B / 2B-3 — B13) | ✅ 40/40 | الجداول + الحصص + الإسناد ذرياً بعقد M37/M40/M42؛ التعارضات: جدول معطَّل بالاسم، حصة متداخلة لا تطابق (ومنها اختلاف الاسم وحده)، يوم ليس دوام نشطاً في الهدف (D4)، صف مُسنَد لجدول آخر؛ ضوابط سلبية: DB 61، API 13 |
| M45 | `school_profile_assets` (Phase 2B / 2B-4 — B2–B6؛ E1–E10) | ✅ 74/74 | الجدولان 38، 39: `school_profiles` (1:1، `id` مفتاحاً و`school_id` فريداً — T7 يسجّل `entity_id` من `id`) و`school_assets` (بنسخ لا تُستبدل، لا كتابة للعميل)؛ RLS + FORCE، 4 سياسات؛ **T16**؛ **E4** المسار تشتقه DB وتتحقق منه (CHECK للمدرسة/النوع/المعرّف/الامتداد + الحارس للـtenant) على كل مسار؛ نشط واحد لكل نوع وصفة مُطبَّعة (B3، E2)؛ الصلاحية حسب النوع (B5)؛ `authorize_asset_url` يدقّق **إصدار** رابط الختم/التوقيع لا الرابط (E8)؛ `school_asset_consistency` (E9) في بصمة الاستعادة؛ bucket خاص بلا سياسة عميل؛ `app_owner` يقرأ `storage.objects` وحده؛ ضوابط سلبية DB 49، API 12 |
| M46 | `staff_profile` (Phase 3A / 3-1 — P12) | ✅ 54/54 | الجدولان 40، 41: `staff_specialties` و`staff_qualifications` **[I]** — بلا `school_id`، FK مركّب بالـTenant، الرؤية والكتابة **بالعلاقة** (`staff_in_scope` + `staff.read`/`staff.update`) لا بالـTenant (ضابط سلبي)؛ RLS + FORCE، 6 سياسات بلا DELETE؛ الموظف والـTenant ثابتان؛ T6، T7؛ بلا دالة ولا حارس ولا مفتاح؛ **PD1** محروس: لا عمود شخصي جديد (ولا عمود جديد على `staff`)؛ UPDATE أعمى بضابط تنفيذ (كشف خطأ اختبار: `INTO` مع UPDATE بلا RETURNING أبطل الأعمى) |
| M47 | `staff_membership_grant` (Phase 3A / 3-2 — P13، Q3) | ✅ 40/40 | **امتداد متحكَّم به لـM12**: `can_manage_membership` بنص M12 حرفياً + فرع واحد — عضوية بلا نطاقات لموظف له تكليف مدرسة **نشط** ضمن نطاق الفاعل (`staff_in_scope`) = نقطة دخول لأول منح؛ التوقيع والمالك والمنح كما هي، لا مفتاح ولا سياسة؛ مصفوفة الفاعل × الهدف كاملة (SA، SB، tenant_admin، Tenant آخر)؛ الحالات العشر: مسار tenant_admin، أول منح (النطاق أولاً والدور أولاً)، مدرسة أخرى، بلا تكليف نشط، T8 يرفض `tenant_admin`، نطاق خارج الفاعل، القاعدة القائمة بعد أول نطاق، لا إدارة ذاتية (والفاعل نفسه موظف)، ولي الأمر كما كان، عبر الـTenant؛ **ضابط سلبي داخل الحزمة**: نص M12 بلا الفرع يُفشل مسار مدير المدرسة وحده |
| M48 | `teaching_assignments` (Phase 3A / 3-3 — T1–T9) | ✅ 82/82 | الجدولان 42، 43: `teaching_assignments` و`class_teacher_assignments` [S عبر السنة]؛ FKs مركّبة (الشعبة بسياقها، ربط المادة بالصف في السنة، الموظف والمدرسة بالـTenant)؛ **فهرسا «نشط واحد» الجزئيان = سلطة التزامن** (T3)؛ RLS + FORCE، 4 سياسات (SELECT بـ`staff.read`، INSERT بـ`staff.assign`) **بلا UPDATE/DELETE للعميل**؛ **T17** على كل مسار (السنة غير مغلقة وسبب النشطة — إعادة استعمال `require_year_setup_writable`؛ عند الإنشاء: الشعبة والمادة وربطها نشطة، الموظف `active` بتكليف مدرسة نشط؛ الهوية ثابتة؛ `active → ended` فقط)؛ `end_teaching_assignment`/`end_class_teacher_assignment`؛ لا حارس عكسي على المرحلة 2 (T8) ولا مسّ لـ`close_academic_year` (T7)؛ FKا الـTenant يُختبران باسميهما والحارس معطَّل داخل المعاملة (الحارس يسبقهما) |
| M49 | `staff_lifecycle` (Phase 3A / 3-3 — T10، T11) | ✅ 41/41 | `set_staff_status` و`end_staff_assignment` بنصّي M21 + P10: إنهاء تكليف مدرسة يُنهي تكليفات التدريس والمربي في **تلك المدرسة وحدها** (إن لم يبقَ تكليف مدرسة نشط آخر فيها) ويحذف **نطاقها وحده** (G2) — الأدوار والعضوية كما هي، وإعادة المنح تعمل (M47)؛ `ended` يُنهي الكل ويعطّل العضوية **بلا حذف صف**؛ `on_leave` لا أثر؛ السنوات المغلقة لا تُمس؛ **T8 بلا تعديل** (حذف النطاق غير مفحوص فيه)؛ `21_state_functions` بلا تعديل. T7 يسجل حذف النطاق `delete` بالفاعل والسبب والصف القديم (التسمية المخصصة للتحديثات وحدها) |

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

- [x] **C1.** `schema app` + الأنواع/الـenums المشتركة.
      ✅ **منفَّذ** — M01 (`schema app`، `app_owner`)، M02 (دوال الـtriggers) — الأنواع `text + CHECK` لا ENUM. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C2.** Tenancy: `platform_tenants`, `groups`, `schools` (+ قيد: `schools.group_id` من نفس Tenant).
      ✅ **منفَّذ** — M03 (`platform_tenants`)، M04 (`groups`, `schools`, `identity_scopes`, T9). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C3.** Platform Admin: `system_users`, `platform_admin_roles`, `platform_admin_assignments`, `platform_admin_role_permissions` (بعد `permissions`).
      ✅ **منفَّذ** — M05، M06 (`platform_admin_role_permissions`). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C4.** Identity: `profiles` (+ **`UNIQUE (auth_user_id)` عالمياً** — O1؛ + `auth_identities` إن اعتُمد G10).
      ✅ **منفَّذ** — M03 (`profiles`، `auth_identities` — G10 معتمد). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C5.** AuthZ: `roles`, `permissions`, `role_permissions`, `memberships`, `membership_roles`, `membership_scopes` (+ CHECK على `scope_type` مقابل `group_id`/`school_id`).
      **البذر يتبع `docs/ROLE_PERMISSION_SEED_v1.md` §8.1 حرفياً:** 73 permission ← 10 roles (`platform_tenant_id IS NULL`, `is_system = true`) ← خريطة `role_permissions` من §4.
      ✅ **منفَّذ** — M06، M07؛ البذر M23 (73 / 10 / 255). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C6.** Academic: `academic_years` (سنة active واحدة/مدرسة)، `terms` (داخل حدود السنة)، `stages`, `grade_levels`, `sections`.
      ✅ **منفَّذ** — M08. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C7.** People: `staff`, `staff_school_assignments`, `families`, **`identity_scopes`**, `students`, `guardians`, `student_guardians`.
      ✅ **منفَّذ** — M09 (`identity_scopes` في M04). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C8.** `enrollments` (+ enrollment نشط واحد لكل student+school+year).
      ✅ **منفَّذ** — M10. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C9.** `audit_log` + trigger عام؛ منع DELETE/UPDATE من التطبيق.
      ✅ **منفَّذ** — M11 (T5، T7) + M02. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **C10.** Indexing baseline حسب `ERD_CORE_v1.md` §8 — لا indexes عشوائية.
      ✅ **منفَّذ** — ضمن migration كل جدول؛ قائمة ERD §8 كاملة (16/16). ✅ قاعدة «كل FK له فهرس»: الفهرسان الناقصان (C3) أُضيفا في M32، واستثناء FK الهوية موثق ومحروس (`31`). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)

### Gate D — RLS

- [x] **D1.** Helpers — **النص الكامل في `docs/RLS_MODEL_v1.md` §1–§3**. مالكها دور يحمل `BYPASSRLS` (يُتحقَّق عملياً لا يُفترض — §4.2 هناك):
      `app.current_profile_id()`, `app.current_tenant_id()`, `app.is_platform_admin()`,
      `app.has_permission(text)`, `app.can_access_tenant(uuid)`, `app.can_access_group(uuid)`, `app.can_access_school(uuid)`.
      `app.user_school_ids()` اختياري كتحسين أداء خلف الطبقة الموحدة فقط، لا كمصدر صلاحية.
      المرجع الملزم: §1.1 أعلاه.
      ✅ **منفَّذ** — M03، M05، M06، M07، M12، M12b (H2). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **D2.** ENABLE + FORCE RLS على كل جداول Foundation — **قبل** كتابة السياسات، ليظهر أي recursion فوراً (`RLS_MODEL_v1.md` §14).
      ✅ **منفَّذ** — عند إنشاء كل جدول؛ بوابة M13 (30 جدولاً بالاسم). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **D3.** Policies لجداول Tenant-level / Group-level / School-level — كل policy = `app.can_access_*()` + `app.has_permission()`؛ ممنوع الاستعلام المباشر من `memberships` أو الاكتفاء بتطابق `platform_tenant_id`.
      ✅ **منفَّذ** — M14، M16 (+ M17 للعلاقات). (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **D4.** Policies لهوية الطالب — ثلاثة مسارات (`student_in_scope` / `student_linked_to_guardian` / `student_is_self`)، `RLS_MODEL_v1.md` §8.
      ✅ **منفَّذ** — M17. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **D5.** Policies لـ`profiles`/`memberships` + **trigger T8** (`grant.permission ⊆ actor.permissions`) — `RLS_MODEL_v1.md` §10.2.
      ✅ **منفَّذ** — M15؛ T8 في M19. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **D6.** سياسات Platform Admin: `is_platform_admin() AND has_permission(...)` — لا استثناء boolean (`RLS_MODEL_v1.md` §11).
      ✅ **منفَّذ** — M14 بـ`has_platform_permission` (G10)؛ ثم M20b و M29: قراءة المنصة بدالة مُدقَّقة بدل السياسات. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)
- [x] **D7.** سياسة `audit_log` + GRANT على مستوى الأعمدة (`RLS_MODEL_v1.md` §13, §12.2).
      ✅ **منفَّذ** — M18، M20، M20b. (مراجعة Stage 1، 2026-10-01: الخانة كانت متأخرة عن الواقع)

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

- [x] **F1.** تطبيق الويب: Vite + TS + Tailwind RTL، خط عربي (IBM Plex Sans Arabic / Cairo)، i18n، تنقل حسب الدور.
      🔒 **مغلق (2026-09-28، CI `25570ce`)** — W1 (M29) و W2 مُصلحان. (`docs/F1_WEB_APP.md`): shell + سياق (`getTenantContext/getSchoolContext`، عرض/دخول فقط) + capabilities (M28) + تنقل حسب المفاتيح + مسارات دخول F2 كلها + شاشات تمثيلية + `t(key)` وقاعدة lint للنصوص؛ Vitest 29، Playwright 16 (كل الأدوار + ولي الأمر A/B/C + الطالب + عبث السياق)، ضوابط سلبية؛ CI على Node 22 بخطوات الويب.
- [x] **F2.** المصادقة: Supabase Auth + JWT للموظفين؛ حساب الطالب المستقل؛ حساب ولي الأمر OTP/كلمة مرور حسب إعداد المدرسة.
      🔒 **مغلق (2026-09-27، CI `860a14a`)** — D1/M24، D2/M25، D3/M26، D4/M27 + E2E لكل الأدوار (11 حساباً). لا إعادة فتح لـD1–D4.
      `docs/F2_AUTHENTICATION.md` — الترتيب: M24 → D1 → D2 → D3 Spike → D3 → D4 → E2E. **D1/M24 🔒** (CI `3f4ae05`؛ 24: 26/26، pytest 68/68)؛ **D2/M25 🔒** (CI `62c76b1`؛ 25: 36، pytest 81/81)؛ D3 Spike؛ D4 دلالات A/B/C.
- [x] **F3.** تحديد المدرسة من الـsubdomain (سياق واجهة فقط — لا يمنح أي صلاحية).
      🔒 **مغلق (2026-10-01، CI `d3d12b1`)** — لا إعادة فتح لـF1/F2/F4. (`docs/F3_HOST_CONTEXT.md`): M30 `host_label` + `login_context` (المحلّل الوحيد)؛ FastAPI يشتق سياق الدخول من `Origin` وحده (لا حقول سياق في الجسم — `422`)؛ CORS مرسَّخ بالمحلل نفسه؛ الواجهة من `window.location.hostname` وأداة التطوير أُزيلت؛ متجهات مشتركة `docs/contracts/host_context_vectors.json` للواجهة والـAPI وقيد DB. pgTAP 1395 (30: 49)، pytest 213، Vitest 77، Playwright 21؛ 22 ضابطاً سلبياً.
      ✅ **مراجعة F3 (2026-10-01):** البنود 1 و4 معتمدة؛ **M30b** يشدّد `host_label` و`schools.slug` إلى labels DNS (لا شرطة ختامية)؛ اختبار مستقل لـ«الطالب من host مدرسة» في FastAPI. pgTAP 1417 (30b: 22)، pytest 225، Vitest 87، Playwright 21.
- [x] **F4.** هيكل FastAPI: التحقق من Supabase JWT، استخراج Tenant/Scope/Role، طبقة تفويض مشتركة.
      🔒 **مغلق (2026-09-26، CI `addae39`)** (`docs/F4_API_SECURITY.md`): JWT ← FastAPI ← DB (RLS + `app.*`) ← البيانات؛ لا تفويض موازٍ في FastAPI. اتصال `authenticator`؛ P3 بمفتاح التصدير نفسه عبر `has_permission` + `can_access_school`؛ N5 مُدقَّق ذرياً؛ 48/48 pytest + 4 ضوابط سلبية؛ خطوة CI.

### معايير إنجاز المرحلة 1

- [x] اختبارات العزل خضراء: مستخدم مدرسة (أ) لا يقرأ ولا يعدل بيانات مدرسة (ب).
      ✅ **S1 و S2 مُصلحتان (M31)** — علاقة ينشئها الفاعل لا تمنحه إدارة حساب ولا نطاق أسرة؛ pgTAP 1483؛ CI `f41b0ff`، https://github.com/ahmedhmmad/sMas/actions/runs/36992802792.
- [x] تسجيل الدخول يعمل والقائمة تتغير حسب الدور.
      ✅ F1 + F2 (Playwright 21: كل الأدوار + ولي الأمر A/B/C + الطالب).
- [x] CI أخضر.
      ✅ يُثبَّت مع كل push.
- [x] مراجعة ERD + migrations قبل الانتقال إلى المرحلة 2.
      🔒 **Stage 1 مغلق (2026-10-02)** — `docs/STAGE1_REVIEW.md` (R1–R10): A (14) و B (7) مغلقة؛ C الخمس مُصلحة: M31 (S1، S2) و M32 (C1–C3)، بلا C جديدة؛ CI `f41b0ff`، https://github.com/ahmedhmmad/sMas/actions/runs/36992802792.

---

## 4. المراحل التالية — تتبع عام

| # | المرحلة | تعتمد على | الحالة |
|---|---|---|---|
| 1 | الأساس (Foundation) | — | 🔒 مكتملة (2026-10-02) |
| 2 | إعداد المدرسة | 1 | 🔒 **مكتملة (2026-10-07)** — 2A (M33–M37، CI `3c68a7d`) · 2B (M38–M45 + المعالج + القبول، CI `94d0ccb`)؛ baseline مغلقة |
| 3 | الموظفون والتكليفات | 2 | 🔄 خطة النطاق ✅ (`docs/PHASE3_SCOPE.md`)؛ **3A**: 3-1 الملف 🔒 (M46، CI `ee68f5a`) · 3-2 الحساب والدور والنطاق 🔒 (M47 CI `c80ad44`؛ API + الواجهة CI `025b48c`) · 3-3 التكليفات ودورة الحياة ✅ منفَّذة (M48، M49) — بانتظار CI |
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
| 2026-10-08 | **3-3 — التكليفات ودورة الحياة: T1–T12 معتمدة، 🟢 GO للتنفيذ (2026-10-08)** (`docs/PHASE3_3_ASSIGNMENTS.md`): **M48** الجدولان `teaching_assignments` و`class_teacher_assignments` [S عبر السنة] + T17 + دالتا الإنهاء، ثم **M49** استبدال `set_staff_status` و`end_staff_assignment` بنصّيهما + P10 + إسقاط نطاق المدرسة. (T2) `active`/`ended` بتواريخ؛ لا إعادة فتح. (T3) **الفهرس الفريد الجزئي هو سلطة التزامن** — معلم نشط واحد لكل (شعبة، مادة) ومربٍّ نشط واحد لكل شعبة؛ إدراجان متزامنان ← واحد ينجح والآخر `23505` ← 409 (اختبار تزامن حقيقي). (T4) INSERT تحت RLS، بلا UPDATE/DELETE للعميل. (T5) الاستبدال = إنهاء ثم إدراج في معاملة واحدة، بلا دالة ثالثة. (T6) T17 `SECURITY DEFINER` على كل مسار — يوسّع قائمة الـtriggers المغلقة بقرار. (T9) `staff.read`/`staff.assign`، لا مفتاح. **(T7) السنة المغلقة:** تكليف بقي `active` لحظة الإغلاق يبقى تاريخاً مجمَّداً، و`close_academic_year` لا تُعدَّل؛ القراءات التشغيلية (ومنها P5) لا تعدّه حالياً. **(T8) لا حارس عكسي:** لا فتح لـ`tg_section_guard` ولا `tg_grade_subject_guard`؛ تعطيل الشعبة أو ربط المادة يجعل التكليف «معلَّقاً» مشتقاً. **(T10) P10:** `end_staff_assignment` تُنهي تكليفات **تلك المدرسة وحدها** (إن لم يبقَ له تكليف مدرسة نشط آخر فيها)، و`set_staff_status(ended)` تُنهي الكل في مدارس الـTenant؛ `on_leave` لا أثر. **(T11) تنقيح لقرار 3-2:** **إنهاء تكليف مدرسة لا ينهي العضوية أبداً** — يُحذف **نطاق تلك المدرسة وحده** (G2)، و**الأدوار لا تُسحب** والعضوية تبقى `active`؛ `staff.status = ended` وحده يعطّل العضوية (بلا حذف). **لا استثناء في T8 ولا تعديل لـ`tg_authz_integrity`**؛ دور بلا نطاق لا يصل إلى مدرسة ولا إلى بيانات أشخاص (دين صغير مسجل: قراءة كتالوج الأدوار والصلاحيات). P5 الأمني لا يعتمد على cascade — الـcascade لاتساق دورة الحياة وإزالة المنح الخاملة. خارج 3-3: مفاتيح `*.read_assigned` والتضييق (3-4)، النصاب (3-5)، حراس المرحلة 2، T8، 3B | Phase 3A — 3-3 |
| 2026-10-08 | **3-2 — الحساب والدور والنطاق: A1–A9 معتمدة، 🟢 GO للتنفيذ (2026-10-08)** (`docs/PHASE3_2_ACCOUNT_ACCESS.md`): **الرؤية A** — `can_see_membership` كما هي، H2 ثابت، لا مسار قراءة خاص لشاشة Access (توجد فقط لموظف يراه الفاعل). تفعيل واحد ذري `POST /schools/{school}/staff/{staff}/account` (الحساب + نطاق المدرسة + الدور)؛ نطاق المدرسة وحده في هذه الشاشة (المجموعة/الـTenant خارج 3-2)؛ المدرسة والموظف والدور أهداف في المسار لا سلطة في الجسم؛ البريد شرط؛ قائمة «قابلة للإسناد» عرض فقط و T8 الحكم. **دورة حياة التفويض:** *Staff account access is granted through membership + role + school scope. Ending the staff's operational relationship automatically revokes the corresponding authorization grants.* — (1) **السحب الجزئي عبر G2** (حذف صف الربط مع حفظه في `audit_log`) و**الإنهاء الكلي بـ`memberships.status = ended` بلا حذف**؛ إنهاء تكليف مدرسة يسحب نطاقها وحده، وإن لم يبقَ نطاق تُعطَّل العضوية؛ (2) الإسقاط التلقائي **نتيجة** للعملية المصرَّح بها داخل الدالة المتحكَّم بها، بلا `membership.end` ولا T8 إضافيين، مُدقَّق باسم الفاعل؛ (3) الأدوار على العضوية لا على المدرسة — لا تغيير في النموذج؛ (4) نطاق المدرسة فقط. **التنفيذ التلقائي مع P10 في 3-3؛ 3-2 يوثّقه فقط.** قيود 3-2: لا migration، لا جدول/عمود، لا دالة، لا سياسة، لا تعديل `can_see_membership`، لا تغيير H2 ولا نموذج تفويض Foundation؛ M47 مصدر الحقيقة لأول منح | Phase 3A — 3-2 |
| 2026-10-07 | **M47 — فرع الموظف في `can_manage_membership` (Phase 3A / 3-2، 2026-10-07):** فجوة تفويض حقيقية ظهرت عند استهلاك Foundation: العضوية **بلا نطاقات** تُدار في M12 بنطاق Tenant أو بعلاقة طالب/ولي أمر فقط، فمدير المدرسة ينشئ الموظف وحسابه ثم تُرفض له أول دور وأول نطاق (RLS — مُثبت على الـseed). **القرار (A):** M47 يضيف فرعاً واحداً — عضوية بلا نطاقات ∧ الـprofile لموظف ∧ له تكليف مدرسة **نشط** ضمن نطاق الفاعل (`staff_in_scope`). **M47 امتداد متحكَّم به لـM12، وليس تعديلاً على قرار Foundation السابق** (authorization-enablement fix): لا تغيير في `role.assign` ولا T8 ولا قواعد التصعيد ولا «كل نطاقات الهدف ⊆ نطاقات الفاعل» بعد أول نطاق ولا سياسات `membership_scopes`/`membership_roles` ولا منع الإدارة الذاتية ولا مسار `tenant_admin` ولا فرعَي الطالب وولي الأمر ولا كتالوج الصلاحيات. **Q3 منقّح: DB مصدر الحقيقة لأول منح لعضوية موظف** (لا فحص الخادم وحده). الاختبارات السلبية العشرة إلزامية، ومعها إثبات أن إزالة الفرع وحده تُفشل مسار مدير المدرسة. يُنقّح P13 («مدير المدرسة يسند الأدوار السبعة» يصح بعد M47). البديل (B: `tenant_admin` وحده يفعّل حسابات الموظفين) مرفوض — يكسر دور مدير المدرسة التشغيلي | Phase 3A — 3-2 |
| 2026-10-07 | **Phase 3 — خطة النطاق معتمدة، 🟢 GO لـ3A (2026-10-07)** (`docs/PHASE3_SCOPE.md`): P1–P14 كما اقتُرحت — 3A (الموظفون، الحسابات، التكليفات، تضييق المعلم R5، النصاب) ثم 3B (مستندات الموظفين) بتصميم مستقل؛ الترتيب 3-1 الملف ← 3-2 الحساب والدور والنطاق ← 3-3 التكليفات ← 3-4 التضييق ← 3-5 النصاب ← 3-6 القبول. **الكتالوج 75 ← 79 (P3):** `student.read_assigned`، `enrollment.read_assigned`، `guardian.read_assigned`، `family.read_assigned` — تُقيَّم بالمفتاح + العلاقة لا باسم الدور؛ لا `*.export_assigned` ولا مفتاح موحّد. **خريطة `teacher` (P4):** سحب `student.read`/`enrollment.read`/`guardian.read`/`family.read` ومنح الأربعة (12 ← 12) — تُنفَّذ في 3-4. **P5 المصدر الوحيد للرؤية:** `staff.status = active` ∧ تكليف مدرسة نشط ∧ تكليف تدريس/مربٍّ نشط ∧ السنة ليست `closed` ∧ التسجيل الحالي — لا cascade للأمان. **P10 منقّح:** `end_staff_assignment` تُنهي تكليفات **مدرسة ذلك التكليف وحدها**؛ `set_staff_status(ended)` تُنهي التكليفات التشغيلية **في كل مدارس الـTenant**؛ باختبار pgTAP صريح. P6 معلم نشط واحد لكل (شعبة، مادة)؛ P7 مربٍّ نشط واحد لكل شعبة؛ P8 `staff.read`/`staff.assign` للتكليفات (لا مفاتيح)؛ P9 الإنهاء بدالة و T17 حارس؛ P11 النصاب مشتق والحد تنبيه لا رفض؛ P12 التخصصات والمؤهلات Tenant-level؛ P13 لا دالة جديدة للحساب والسؤال 7 مفتوح؛ P14 OTP على البريد وقناة البريد الإنتاجية اعتماد تشغيل. **Q1:** `staff.read` للمعلم **قبول مؤقت بدين خصوصية صريح PD1** (`ROLE_PERMISSION_SEED_v1.md` §7) — لا يُعتبر مغلقاً أمنياً، ولا يتوسع `staff.read`؛ **Q2** المعلم يرى البنية كلها؛ **Q3** فحص النطاق بلا تكليف في الخادم وحده، باختبار «بلا تكليف ← لا طالب» وضابط إزالة الفحص؛ **Q4** لا تكليف جديد لموظف غير `active`، والقائم يبقى بلا رؤية أثناء `on_leave`، و`active ↔ on_leave` لا ينشئ ولا يُنهي تكليفاً؛ **Q5** لا نسخ للتكليفات؛ **Q6** المسمّى نص حر. لا تغيير في Foundation ولا المرحلة 2 | Phase 3 — خطة النطاق |
| 2026-10-07 | **المرحلة 2 — إعداد المدرسة: مكتملة ومغلقة (2026-10-07)** — 2A و2B بقبولهما (`PHASE2A_ACCEPTANCE.md`، `PHASE2B_ACCEPTANCE.md`)؛ المرحلة **baseline مغلقة**: لا تعديل وظيفي رجعي؛ المؤجل (backup/restore الإنتاجي لمحتوى الملفات، جداول الدوام المؤقتة بمدى تواريخ، عرض الشبكة) يدخل **قراراً/نطاقاً جديداً في المرحلة المناسبة** | Phase 2 — الإغلاق |
| 2026-10-07 | **2B-5 — معالج الإعداد: W1–W6 معتمدة كما اقتُرحت (2026-10-07)** (`docs/PHASE2B_5_WIZARD.md`)، مؤكَّدة مقابل عقد `ready_for_enrollment` و2A و2B و F4: المعالج **طبقة orchestration/visibility فقط — ليس domain ولا مسار كتابة**. القيود: لا migration؛ لا مفتاح؛ لا جدول `wizard_state`؛ لا دالة DB للمعالج؛ لا endpoint كتابة خاص به؛ يستدعي مسارات الإعداد القائمة؛ (W1) سنة القياس: النشطة ← وإلا أقرب planned ← أو سنة يختارها المستخدم صراحةً، **ولا تتغير تلقائياً أثناء الجلسة ولا تُخزَّن**؛ (W2) المواد والدوام شرط **شامل لكل صف نشط له شعب** (لا وجود سجل واحد)؛ (W3) `setup_complete = profile ∧ year ∧ calendar ∧ structure ∧ subjects ∧ bell_schedules` — **لا تدخله الأصول ولا `ready_for_enrollment`**؛ و`setup_complete = true` مع `ready_for_enrollment = false` ليس تناقضاً؛ (W4) 404 للمدرسة غير المرئية، 403 لنقص أي مفتاح قراءة — قاعدة الجاهزية؛ (W5) استعلام واحد تحت RLS بصلاحيات المستخدم الفعلية؛ (W6) البطاقات القائمة نفسها. **`ready_for_enrollment` لا يُعاد تعريفه** | Phase 2B — 2B-5 |
| 2026-10-06 | **2B-4 — ملف المدرسة و Storage: E1–E10 معتمدة (2026-10-06)** (`docs/PHASE2B_4_PROFILE_STORAGE.md`)؛ لا مفتاح جديد — الكتالوج 75: (E1) ملف واحد للمدرسة بلا تاريخ نسخ — الوثائق (6) تلتقط ما تطبعه؛ (E2) `signer_title` حر، توقيع نشط واحد لكل صفة؛ (E3) لا حذف من التطبيق، التقاعد نهائي، الكائن يبقى؛ (E4) `{tenant_id}/{school_id}/{kind}/{asset_id}.{ext}` و**DB هي التي تتحقق من تطابق المسار** (tenant، school، asset، kind، extension) — لا مسار لمدرسة أخرى مهما عُبث بالطلب؛ (E5) DB ← Storage ← commit، **وهي ليست معاملة ذرية بين PostgreSQL و Storage**: فشل الرفع ← rollback؛ فشل الـcommit بعد الرفع ← حذف **الكائن الذي رفعه هذا الطلب وحده** (لا ملف قديم ولا ملف لا يخص العملية)؛ timeout/exception لا يُنهي الطلب بكائن يتيم؛ **تعذّر التنظيف خطأ مرئي قابل للتشخيص لا نجاح**؛ (E6) التحقق من البايتات الفعلية (التوقيع، الأبعاد، 1MB) بلا مكتبة صور ولا إعادة ترميز؛ **`sha256` للبايتات المخزنة فعلاً**؛ (E7) الشعار `school.read`، الختم والتوقيعات `security.manage`، الرابط 60 ثانية؛ (E8) التدقيق يسجل **عملية إصدار الرابط لا الرابط ولا الـtoken** — لا رابط موقّع في `audit_log`؛ (E9) الـdump يغطي الصفوف وبيانات الكائنات الوصفية لا محتواها، وفحص الاتساق يكشف الافتراق — **2B لا تدّعي backup/restore إنتاجياً للملفات**؛ (E10) **`python-multipart` معتمدة صراحةً** (لا base64)؛ اختبارات Storage في CI **excluded صراحةً بسبب غياب خدمة Storage — Excluded ≠ skipped**، وكل اختبارات DB/الأمن/الـAPI غير المعتمدة على Storage إلزامية. **خارج 2B-4:** مستندات الطلاب وصورهم، الشهادات، إعادة الترميز، الاحتفاظ/الإتلاف، backup/restore الإنتاجي للملفات | Phase 2B — 2B-4 |
| 2026-10-06 | **2B-3 — الدوام والحصص: D1–D7 معتمدة كما اقتُرحت (2026-10-06)** (`docs/PHASE2B_3_BELL_SCHEDULES.md`): (D1) قائمة حصص لكل يوم أسبوع داخل الجدول؛ (D2) إسناد الصف إلى جدول واحد لكل سنة — لا إسناد للشعبة منفردة؛ (D3) السنة النشطة: التعديل بسبب إلزامي (آلية C3)، المغلقة immutable؛ (D4) من الجهتين: لا حصة على يوم ليس دوام نشطاً، ولا تعطيل يوم دوام له حصص نشطة — بـmigration جديدة، **M41 لا تُعدَّل**؛ (D5) **`bell_periods.id` معرّف ثابت للفتحة وليس رقم الحصة الظاهر**: الرقم مشتق من ترتيب `start_time` للحصص النشطة من نوع `lesson` في اليوم، و`id` ثابت عند التعديل (للجدول والسجلات التاريخية)؛ (D6) منع التداخل **database-enforced** داخل (الجدول، اليوم) على كل مسار: `09:00–10:00` مع `09:30–10:30` يفشل، و`09:00–10:00` مع `10:00–11:00` مسموح (`[)`)؛ جدولان مختلفان قد يتداخلان؛ (D7) `lesson` و`break` فقط، والاستراحة لا تُجدول. **خارج 2B-3:** الجدول الدراسي، الحضور بالحصة، الجداول المؤقتة بمدى تواريخ (رمضان) — **لا schema مؤقت لها الآن**؛ تصميم مستقل إن احتاجتها المرحلة 11 أو التشغيل — وإسناد الشعبة منفردة | Phase 2B — 2B-3 |
| 2026-10-05 | **2B-2 — التقويم: C1–C5 معتمدة كما اقتُرحت (2026-10-05)** (`docs/PHASE2B_2_CALENDAR.md`): (C1) «اليوم» = `current_date_in_school_timezone` — التاريخ الحالي بتوقيت المدرسة المخزن في `schools.timezone`، لا توقيت الخادم ولا المتصفح؛ اليوم نفسه قابل للإضافة/التعديل بسبب؛ (C2) سنة نشطة بلا أيام دوام: التعريف الأول مرة واحدة بسبب ثم تُجمَّد — لا تعديل لتفعيل السنة (2A مغلقة)؛ (C3) السبب invariant في DB: الـAPI يمرره إلى سياق التدقيق في المعاملة نفسها، والحارس يرفض أي كتابة على تقويم سنة نشطة بلا سبب على كل مسار (ومنه الكتابة المباشرة)؛ (C4) الاستثناء الجاري: `end_date` وحده، والقديم والجديد ≥ اليوم؛ البداية والنوع والاسم ثابتة؛ لا إلغاء؛ (C5) اليوم الدراسي الاستثنائي يوم واحد، لا يُقبل على يوم دراسي عادي. **لا منطق حضور في 2B-2** — المرحلة 5 تستهلك `is_school_day()` | Phase 2B — 2B-2 |
| 2026-10-04 | **Phase 2B — كتالوج الصلاحيات و Storage (2026-10-04):** تم اعتماد الصلاحيتين `subject.read` و`subject.manage`، ليصبح كتالوج الصلاحيات **75**؛ لا إعادة استعمال لـ`grade.*` ولا لمفاتيح أكاديمية أخرى لمجرد التشابه. تم اعتماد Storage في 2B مع بقاء إثبات backup/restore الإنتاجي للملفات كـ**Production Readiness Gate** مستقل، وليس شرطاً لإغلاق 2B (B6 معدَّل: Storage يُصمَّم ويُنفَّذ ويُختبر كاملاً محلياً — الـbucket والسياسات والرفع والاسترجاع والاتساق — ولا يُشترط تفعيله في CI) | Phase 2B — خطة النطاق |
| 2026-10-04 | **Phase 2B — B1–B5، B7–B9، B11–B15 معتمدة كما اقتُرحت (2026-10-04)** (`docs/PHASE2B_SCOPE.md` §0): الترتيب المواد ← التقويم ← الدوام ← الملف و Storage ← المعالج؛ `school_profiles` مستقل؛ الأصول بنسخ لا تُستبدل؛ الرفع عبر FastAPI ودالة DB و bucket خاص وروابط موقّعة؛ الختم والتوقيعات بـ`security.manage`؛ التقويم لكل سنة (السنة النشطة: الاستثناءات المستقبلية فقط، المغلقة immutable)؛ المواد كتالوج للمدرسة وربط لكل سنة؛ الدوام جداول لكل فترة بحصص واستراحات بلا تداخل، بـ`academic_year.read/update`؛ النسخ إلى سنة جديدة ذري idempotent بنمط M37 (أيام الدوام، ربط المواد، جداول الدوام — لا الاستثناءات المؤرخة ولا أي بيانات تشغيلية)؛ المعالج بلا حالة مخزنة ولا يغيّر الجاهزية؛ القراءة للمعلم والسكرتير والمحاسب والمرشد بالمفاتيح القائمة و`subject.read`. **التنفيذ جزءاً جزءاً بمراجعة بعد كل جزء، بدءاً بـ2B-1 (المواد)** | Phase 2B — خطة النطاق |
| 2026-10-04 | **P2-C — الجاهزية تشترط صلاحيتي القراءة:** `GET /schools/{id}/readiness` يسأل DB `has_permission('academic_year.read') AND has_permission('section.read')` وإلا `403` — من يرى المدرسة بلا قراءة السنة والشعبة يرى الشروط «غير مرئية» لا «غير متحققة»؛ لا مفتاح جديد | Phase 2A — P2-C |
| 2026-10-03 | **M37 — عقد نسخ الشعب (منقّح أثناء التنفيذ، 2026-10-03):** المفتاح الطبيعي للنسخة `(school, target_year, grade_level, name)`؛ **لا `ON CONFLICT DO NOTHING`**: المطابق (`active` + السعة وسياسة الجنس) «منسوخ سابقاً» لا يُمس، وغير المطابق (ومنه المعطّل) يُفشل العملية كلها بقائمة المفاتيح؛ النسخ لا يعدّل الموجود ولا يمس الشعب الإضافية. **سبب إلزامي** (توقيع الدالة `(source, target, reason)` بدل `(source, target)` في §6.4) و**صف تدقيق domain** `copy_sections` بالمصدر والهدف والعددين | Phase 2A — M37 |
| 2026-10-02 | **Phase 2A — وثيقة التصميم و Q1–Q9 معتمدة (2026-10-02):** (Q1) قواعد «ما يُعدَّل حسب الحالة» بـtriggers حارسة T10–T12 تسري على كل مسار — يوسّع قائمة الـtriggers المغلقة بقرار، والرقم T10 (بديل G10 غير المستعمل) أُعيد إسناده؛ (Q2) الفصل كالسنة: `planned` كل شيء، `active` الاسم فقط، `closed` لا شيء؛ (Q3) إغلاق سنة فيها فصل `active` يُرفض؛ (Q4) الجاهزية تشترط شعبة نشطة **في السنة النشطة**؛ (Q5) نسخ الشعب idempotent بالمفتاح الطبيعي؛ (Q6) الـ`slug` القديم يتحرر فوراً بلا سجل ولا تحويل؛ (Q7) بنية السنة المغلقة مجمدة، ولا تعطيل لصف له شعب نشطة ولا لمرحلة لها صفوف نشطة، ولا شعبة تحت صف معطَّل؛ (Q8) شاشات F1 القائمة تبقى؛ (Q9) إدارة المجموعات ضمن 2A بأدنى حد | Phase 2A — P2-A |
| 2026-10-02 | **Phase 2 — التقسيم (معتمد):** **2A** (دورة حياة المدرسة، السنة، الفصول، البنية التعليمية، الجاهزية، API، الواجهة) ثم **2B** بخطة نطاق مستقلة (ملف المدرسة و Storage، العطلات وأيام الدوام، المواد، الدوام والحصص، المعالج، وجداولها ومفاتيحها). نظام التقييم ← المرحلة 6؛ إشعارات الغياب ← المرحلة 5؛ قواعد التوزيع و I43 ← المرحلة 4؛ نمط الحضور ثابت في v1. **2A: لا جدول جديد ولا مفتاح صلاحية جديد (الـ73 القائمة)** | Phase 2A — خطة النطاق |
| 2026-10-02 | **Phase 2A — إنشاء المدرسة (معتمد):** يبقى لدى `tenant_admin`، و`group_manager` داخل مجموعته. **إنشاء Tenant/Group/School من مستوى المنصة ليس جزءاً من Phase 2A؛ مسار Platform Admin المستقبلي قرار مستقل** — لا إعادة فتح لـM29 (ينقّح صياغة §7.9). أول `school_admin` يعيّنه `tenant_admin` بالدوال القائمة؛ السؤال المفتوح 7 يبقى قراراً تجارياً ولا يُحل بتوسيع `role.assign` | Phase 2A — خطة النطاق |
| 2026-10-02 | **Phase 2A — المدرسة (معتمد):** `active`/`archived` فقط، بلا draft وبلا unarchive. **`ready_for_enrollment` مشتقة غير مخزنة:** المدرسة `active` + سنة `active` + شعبة `active`. **`slug`** يخرج من UPDATE المباشر ويتغير بدالة متحكَّم بها وحدها (`school.update` + نطاق المدرسة + صحة + تفرد + حالة + تدقيق، في معاملة)؛ تغيير العنوان لا يغيّر `school_id` ولا الملكية ولا سياق التفويض | Phase 2A — خطة النطاق |
| 2026-10-02 | **Phase 2A — السنة والفصول (معتمد):** السنة `planned → active → closed`: `planned` الاسم والتواريخ، `active` الاسم فقط، `closed` immutable، لا reopening، لا تعديل صامت لحدود الفصول؛ التفعيل لا يشترط فصولاً. الفصل `planned → active → closed` بدوال صريحة بـ`term.manage`، لا اشتقاق من التواريخ؛ **فصل `active` واحد على الأكثر لكل سنة، وداخل سنة `active` فقط**؛ فصول السنة `planned` تُجهَّز مسبقاً | Phase 2A — خطة النطاق |
| 2026-10-02 | **Phase 2A — الشعب (معتمد):** لا تعطيل لشعبة ذات enrollments نشطة؛ لا شعبة في سنة `closed`؛ **`school_id + academic_year_id + grade_level_id` هوية تشغيلية ثابتة بعد الإنشاء** (بنية مختلفة = شعبة جديدة). **نسخ الشعب** عملية domain واحدة ذرية (لا loop من الـAPI): المدرسة نفسها، إلى سنة `planned`، بلا enrollments ولا بيانات تشغيلية ولا فصول؛ idempotent أو رفض حتمي للتكرار | Phase 2A — خطة النطاق |
| 2026-10-02 | **Phase 2A — التنفيذ (معتمد):** كل CRUD عبر FastAPI (`verified JWT → authenticated DB transaction → DB/RLS/function authorization → result`) بلا تفويض موازٍ ولا PostgREST مباشر من المتصفح. الترتيب: P2-A التصميم (`docs/PHASE2_SCHOOL_SETUP.md`) ← P2-B DB ← P2-C API ← P2-D Web ← P2-E الإغلاق؛ **P2-B لا تبدأ قبل اعتماد وثيقة التصميم**. معيار الإغلاق: من الواجهة فقط حتى `ready_for_enrollment`، بلا cross-school/cross-tenant violation، وكل العمليات الحساسة مدققة، وCI كامل أخضر | Phase 2A — خطة النطاق |
| 2026-10-02 | **S1 — الآلية النهائية (الحزمة النهائية، معتمد):** `student_guardians.relationship_source` هو العقد — `direct` \| `provisioned`، افتراضي `direct`، **لا يكتبه العميل**، و`provisioned` تكتبه `app.provision_guardian` وحدها. إصدار الكلمة المؤقتة لولي الأمر يشترط ارتباطاً **`provisioned` نشطاً** بطالب في النطاق الحالي للفاعل؛ `direct` لا يمنح وحده إدارة credentials. **لا اعتماد على `created_by`** — يُنقِّح «أو أنشأه فاعل آخر» في صف S1 أدناه. **صلاحية ربط ولي الأمر ≠ صلاحية إدارة حساب ولي الأمر** | مراجعة Stage 1 — M31 |
| 2026-10-02 | **S2 — الآلية (M31):** `students_update` WITH CHECK += `family_id IS NULL OR app.family_in_scope(family_id)` بلا دالة جديدة؛ دوال WITH CHECK تقرأ لقطة الجملة (الصف القديم) فالطالب المنقول لا يجعل الأسرة الهدف ضمن النطاق بنفسه، والأسرة غير المتغيرة مقبولة ولو كان الطالب عضوها الوحيد. البديل (دالة تستثني الطالب الحالي) **مرفوض**: يمنع تعديل الطالب العضو الوحيد في أسرته (ضابط سلبي: 3 اختبارات) | مراجعة Stage 1 — M31 |
| 2026-10-02 | **C1–C3 (معتمد، الحزمة النهائية):** migration غير أمنية واحدة (M32) بعد الأمنية: (C1) لا امتياز لـ`anon`/`authenticated` على أي sequence ولا على sequence جديدة؛ (C2) سحب `MAINTAIN` وافتراضيّه — الجدول الجديد يعطي `authenticated` SELECT وحده؛ (C3) فهرسا `platform_tenant_id` في `families` و`login_challenges`. **الاستثناء الوحيد لـ«كل FK له فهرس»: FK الهوية المركّب `(auth_user_id, identity_kind)` في `profiles`/`system_users` — مستوفى بـ`UNIQUE (auth_user_id)`**؛ حراس دائمة في `20` و`31` | مراجعة Stage 1 — M32 |
| 2026-10-02 | **تكليف الموظف (D2 في المراجعة) — يبقى D، لا تغيير الآن:** INSERT بـ`staff.assign` + مدرسة الهدف (خيار b، 2026-09-25) قائم؛ لا مسار إدارة حساب يتبعه اليوم. يُراجَع عند تصميم 5c/حسابات الموظفين | مراجعة Stage 1 |
| 2026-10-01 | **مراجعة Stage 1 — القواعد (2026-10-01):** خط الأساس `59399d4`؛ الـcatalog مصدر حقيقة **الحالة المنفذة** فقط، وعند تعارضه مع وثيقة يُرجع إلى التصميم المعتمد لتحديد A (وثيقة متأخرة — تُصحَّح in-place بتاريخ، بلا v2) أو C (خلل تنفيذ). C تُعرض دفعة واحدة في النهاية بلا تنفيذ؛ **C الأمني (Tenant isolation، RLS bypass، privilege escalation، account takeover، cross-tenant) يُعرض فوراً**. لا migration إصلاحية أثناء المراجعة بلا اعتماد. الحراس الدائمة للعقود المستقرة الحتمية الرخيصة فقط. لا إعادة فتح لقرار مغلق | مراجعة Stage 1 |
| 2026-10-01 | **M30b — البيانات المخالفة: fail before mutation + enumerate all offending values (معتمد 2026-10-01):** لا auto-fix — `slug`/`host_label` عنوان قابل للوصول، وتغييره قرار صريح لا normalization تقني | مراجعة Stage 1 |
| 2026-10-01 | **R5 teaching-assignment — Deferred / Phase 3:** R5 teaching-assignment invariant cannot be fully enforced or tested until `teaching_assignments` is introduced in Phase 3. لا يُحوَّل إلى C ولا يمنع Stage 1؛ ومثله Production Backup Policy والبنود المصنفة TBD صراحةً | مراجعة Stage 1 |
| 2026-10-01 | **S1 — C أمني (معتمد: S1-أ، 2026-10-01):** `begin_guardian_temporary_password`/`arm_guardian_temporary_password` لا تعتمدان على `guardian_in_scope` وحده حين يكون النطاق قابلاً للإنشاء من الفاعل نفسه. **إصدار الكلمة المؤقتة يشترط أن يكون ارتباط ولي الأمر بطالب المدرسة قد أنشأته `provision_guardian` أو أنشأه فاعل آخر، لا ربطاً مباشراً من المُصدِر نفسه** — مصدر العلاقة جزء من الـauthorization invariant (**نُقِّح 2026-10-02:** `provisioned` وحدها، بلا `created_by` — صف 2026-10-02 أعلاه). S1-ب (سحب INSERT المباشر) **غير معتمد**: §10.5 لا تُفتح. الاختبار يثبت السلسلة كاملة (`SA → student_guardians INSERT → guardian_in_scope → begin`) ويفشل عند إدارة الحساب تحديداً، مع بقاء الربط المشروع والقراءة بعده و`provision_guardian` تعمل | مراجعة Stage 1 |
| 2026-10-01 | **S2 — C أمني (معتمد، 2026-10-01):** `students` `WITH CHECK`: `family_id IS NULL OR` الأسرة ضمن نطاق الفاعل أصلاً — لا علاقة ينشئها الفاعل تصير مصدر النطاق (self-created scope escalation). الاختبار: SA2 لا يسند أسرة خارج نطاقه، ويستطيع استعمال أسرة في نطاقه | مراجعة Stage 1 |
| 2026-10-01 | **S1/S2 — التنفيذ:** migration أمنية **مستقلة** بعد اكتمال المراجعة وعرض الحزمة النهائية — لا تُخلط مع إصلاحات C غير الأمنية (الامتيازات، الفهارس) ولا مع الوثائق | مراجعة Stage 1 |
| 2026-10-01 | **F3 — مراجعة (1) معتمد:** host يسمّي مدرسة مؤرشفة أو غير موجودة ← **generic authentication failure** لكل أنواع الحسابات، حتى المرتبطة بها تاريخياً (التاريخية لا تعني operational access — متسق مع H2)؛ host الـTenant يبقى صالحاً لمستخدمي مستوى الـTenant حسب صلاحياتهم | مراجعة F3 |
| 2026-10-01 | **F3 — M30b: `host_label` و`schools.slug` labels DNS صالحة (RFC 1123):** لا شرطة في البداية ولا النهاية، ≤ 63. `host_label` `^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$` (1–63)؛ `schools.slug` `^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$` (2–63 — الحد الأدنى القائم يبقى). لأن F3 جعل الـslug جزءاً من hostname: **لا tenant label صالح مع school slug غير صالح كـhostname**. البيانات القائمة المخالفة توقف الـmigration بقائمة مسمّاة — لا تصحيح تلقائي (تغيير الـslug/label يغيّر العنوان، فهو قرار صريح) | مراجعة F3 |
| 2026-10-01 | **F3 — «دخول الطالب من host مدرسة فقط» defense-in-depth invariant في FastAPI نفسه**، لا نتيجة جانبية لبحث DB: له اختبار مستقل يستبدل الطبقتين الأخريين بما كان سيسمح بالدخول (host الـTenant، host المنصة)، ويفشل إذا أُزيل الفحص الصريح | مراجعة F3 |
| 2026-10-01 | **F3 — دلالات `getTenantContext()`/`getSchoolContext()` معتمدة:** `label`/`slug`/`null` — host المدرسة: (tenant، school)؛ host الـTenant: (tenant، `null`)؛ host المنصة: (`null`، `null`) | مراجعة F3 |
| 2026-10-01 | **F3 — شكل الـhost (قرار 2026-10-01):** `{school}.{tenant}.{base}` ← سياق مدرسة · `{tenant}.{base}` ← سياق Tenant · `admin.{base}` ← المنصة؛ `admin`/`api`/`www` محجوزة **كـtenant label** (لا يُمنع `admin` كـslug مدرسة). الـsubdomain **context فقط، ليس authorization** | F3 |
| 2026-10-01 | **F3 — `platform_tenants.host_label` (M30) بدل تعديل `tenant_code`:** `tenant_code` معرّف أعمال (`_`، أحرف كبيرة) و`host_label` معرّف DNS `^[a-z0-9][a-z0-9-]{0,62}$`، فريد على مستوى المنصة، المحجوزات مرفوضة، لا يكتبه العميل، يُحدَّد في `bootstrap_tenant`. `tenant_code` لا يتغير | F3 |
| 2026-10-01 | **F3 — `Origin` مصدر سياق الدخول:** **`Origin` مصدر context فقط، وليس مصدر authority ولا إثبات هوية** — `Origin → where to look · JWT/auth → who is the user · DB/RLS → what the user may access`. لا كود يستنتج صلاحية من Origin؛ تزويره من عميل غير المتصفح ليس ثغرة لأنه لا يُستعمل تفويضاً. غائب أو خارج الأصل الأساسي ← **generic failure** بلا كشف وجود؛ **لا fallback من الجسم**. Flutter: مسار سياق مستقل عند بدئه — ليس في F3 | F3 |
| 2026-10-01 | **F3 — CORS مرسَّخ:** `API_CORS_ORIGIN_BASE` بدل القائمة الصريحة؛ الأصل مسموح ⟺ يحلله **محلل F3 نفسه** (لا regex موازٍ) — لا `*` ولا wildcard غير مرسَّخ؛ محلل Origin ومحلل hostname على القواعد نفسها | F3 |
| 2026-10-01 | **F3 — لا بحث عام عن اسم المدرسة:** صفحة الدخول تعرض المعرّف المشتق من الـhost؛ endpoint مثل `GET /public/schools/by-host` خارج F3 (سطح enumeration) — الاسم لاحقاً بقرار مستقل | F3 |
| 2026-10-01 | **F3 — لا context drift:** حقول `tenant`/`school` **أُزيلت من schemas الدخول نهائياً** (`extra="forbid"`) — جسم يحملها ← `422`، لا قبول ثم تجاهل | F3 |
| 2026-10-01 | **F3 — سياق تشغيلي غير صالح (تفسير تنفيذي):** host يسمّي مدرسة **مؤرشفة أو غير موجودة** لا يجد **أي** حساب (موظف، ولي أمر، طالب) — `app.login_context` يحل السياق كاملاً أو لا شيء؛ host الـTenant يبقى صالحاً للموظف؛ الرد نفسه لكل الحالات | F3 |
| 2026-10-01 | **F3 — أداة سياق التطوير (W2) أُزيلت:** السياق من الـhost وحده في كل بناء (التطوير `*.localhost`)؛ `vite build` يشترط `VITE_BASE_DOMAIN` صالحاً. `getTenantContext()`/`getSchoolContext()` باقيتان للعرض (`label`/`slug`، `null` حيث لا ينطبق) | F3 |
| 2026-09-28 | **W1 — `platform_tenants` و`groups` و`schools` ضمن N5 (قرار 2026-09-28):** بنص RLS_MODEL §11 («كل قراءة Platform Admin لبيانات Tenant تُسجَّل» بعد سياسة `platform_tenants` و«النمط نفسه على groups و schools»)، ولا وثيقة تصنّفها خارج N5. **لا قراءة مباشرة لـPlatform Admin عبر PostgREST** للجداول الثلاثة | F1/W1 |
| 2026-09-28 | **W1 — الآلية: دالة DB متحكَّم بها (M29):** `app.platform_read_tenants([id])` تتحقق من سياق المنصة و`tenant.read` وتكتب صف تدقيق N5 لكل Tenant في العبارة نفسها (fail closed)؛ FastAPI يستدعيها. حُذفت سياسات Platform Admin الثماني على الجداول الثلاثة (SELECT، ومعها INSERT/UPDATE التي تعتمد على رؤية الصف)؛ كتابة المنصة = دوال متحكَّم بها؛ groups/schools تُضاف لها دالة قراءة مع أول شاشة تحتاجها | F1/W1 |
| 2026-09-27 | **F1 — خطة النطاق معتمدة (2026-09-27):** shell (React/TS/Vite/Tailwind، RTL، IBM Plex Sans Arabic، responsive، routing، حالات، logout، انتهاء الجلسة)؛ سياق عبر `getTenantContext()`/`getSchoolContext()`؛ تنقل حسب الصلاحيات (الإخفاء عرض لا أمن)؛ مسارات دخول F2 الحقيقية؛ شاشات تمثيلية فقط (Login ← Dashboard ← Students ← Detail ← Export)؛ `t(key)` بلا مكتبة؛ lint/typecheck/build + Vitest + Playwright. **خارج F1:** F3، design system، accessibility audit متقدم، PWA/offline، Flutter، notifications، business modules، school settings UI، 5c، deployment/CDN، لغات أخرى. **F3 لا يبدأ بالتوازي** | F1 |
| 2026-09-27 | **F1 — قيد 1:** `app.my_permissions()` (M28) تستخرج **effective permission keys** داخل DB من الجداول نفسها وبشروط السياق/الحالة نفسها، **لا enumeration عبر `has_permission()`** ولا قائمة يرسلها العميل؛ مفاتيح فقط (لا أدوار ولا نطاقات ولا معرّفات)؛ tenant أو platform بلا اتحاد؛ **ليست حداً أمنياً** | F1 |
| 2026-09-27 | **F1 — قيد 2:** `school_id` في F1 **ليس authorization input**: `getTenantContext/getSchoolContext` للعرض ولطلبات الدخول فقط؛ **لا تضيف أي data-fetching function في React `school_id` كنطاق صلاحية**؛ F3 يستبدل مصدرهما بالـsubdomain دون تغيير المستدعين | F1 |
| 2026-09-27 | **F1 — الإضافات الأربع معتمدة:** الاعتماديات (ضمن §3.1، بلا state-management ولا مكتبة i18n)؛ M28 + `/me/capabilities`؛ CORS من البيئة (**لا `*`**)؛ مرسل OTP ملفي للتطوير/CI فقط: بلا مسار HTTP يقرؤه، مرفوض في production، الملف خارج `apps/web` وخارج Git/artifacts، ويُنظَّف بين اختبارات Playwright. E2E تعتمد مدارس الـfixture بأسمائها (SA، SB، SS) لا عددها | F1 |
| 2026-09-27 | **F3 ↔ D4 (قرار 2026-09-27):** مدرسة سياق الدخول تأتي اليوم من جسم الطلب (F2)؛ عند تنفيذ F3 يصبح **tenant + school المستخرجان من الـsubdomain هما مصدر السياق** لا قيمة يختارها العميل في الجسم. 5c (إعادة ضبط حساب active) منفصل عن إصدار كلمة الـonboarding | F3 |
| 2026-09-26 | **D4.1:** نمط A/B/C لولي الأمر يحكم **أول دخول (onboarding) فقط**؛ بعده تحكم طرق الحساب نفسه: كلمة المرور إن وُجدت، وOTP للاسترداد/فك القفل (وفي B يبقى OTP ما لم تُضبط كلمة مرور) | F2 — قرارات D4 |
| 2026-09-26 | **D4.2:** النمط الافتراضي **A** — OTP ← إنشاء كلمة مرور إجبارياً ← الدخول اللاحق بكلمة المرور، وOTP للاسترداد/فك القفل | F2 — قرارات D4 |
| 2026-09-26 | **D4 — التخزين:** عمود `schools.guardian_first_login_mode` (`A`|`B`|`C`، افتراضي A)، لا يكتبه العميل؛ تغييره بدالة متحكَّم بها: `security.manage` + نطاق المدرسة + سبب، مُدقَّق (T7)؛ ينتقل إلى وحدة إعدادات المدرسة (المرحلة 2) إن لزم | F2 — قرارات D4 |
| 2026-09-26 | **D4 — المدرسة الهدف:** مدرسة سياق الدخول (من الـsubdomain، F3)، ويجب أن تكون **المدرسة الحالية لابن نشط الارتباط** (أحدث تسجيل — H2)؛ وإلا الرد العام نفسه بلا كشف. نمطها يحكم الـonboarding | F2 — قرارات D4 |
| 2026-09-26 | **D4 — C:** إصدار كلمة المرور المؤقتة بـ**`security.manage`** + ولي الأمر في النطاق الحالي، عملية متحكَّم بها مُدقَّقة؛ للحساب غير المُستكمل فقط (إعادة الضبط مسار 5c مستقل) | F2 — قرارات D4 |
| 2026-09-26 | **F2 defaults — OTP:** صلاحية الرمز **5 دقائق**، **5 محاولات** لكل تحدٍّ، والطلب الجديد يُلغي السابق | F2 — مراجعة D3 |
| 2026-09-26 | **F2 defaults — كلمة المرور:** **5 إخفاقات ⇒ قفل 15 دقيقة**؛ نجاح OTP يفك القفل (PLAN §7.8). تبقى **configuration** لا افتراضات أعمال ثابتة متى سمح التصميم (اليوم ثوابت في M26 — نقلها إلى إعداد متابعة) | F2 — مراجعة D3 |
| 2026-09-26 | **Staff authentication requires `status = active`:** `on_leave` لا يحصل على جلسة (fail-closed)؛ أي دخول محدود لموظف في إجازة قرار مستقل لاحق | F2 — مراجعة D3 |
| 2026-09-26 | **تنبيهات القفل (ولي الأمر + المدرسة):** لا تُضاف الآن — تابعة لقناة الإرسال (المرحلة 5) | F2 — مراجعة D3 |
| 2026-09-26 | **I4:** حدود معدّل Supabase Auth ومعالجة IP العميل = **Production deployment requirement**، لا مانع لـF2 المحلي | F2 — مراجعة D3 |
| 2026-09-26 | **Tenant Admin Auth identity remains native email for now; separate decision deferred.** (`bootstrap_tenant` — lifecycle مختلف عن student/guardian/staff) | F2 — مراجعة D3 |
| 2026-09-26 | **`login_challenges` بلا T7 (معتمد):** لا تُنسخ OTP hashes إلى `audit_log`؛ نتيجة الدخول/القفل تُدقَّق على guardian/staff | F2 — مراجعة D3 |
| 2026-09-26 | **D4 — ربط الحروف بترتيب PLAN (السطر 412):** **A** = OTP ثم إنشاء كلمة مرور إجبارياً؛ **B** = OTP فقط وكلمة المرور اختيارية؛ **C** = كلمة مرور مؤقتة من المدرسة ثم تغيير إجباري | F2 — مراجعة D3 |
| 2026-09-26 | **D3 — Tenant accounts synthetic identity (معتمد بعد الـSpike):** ولي الأمر (هاتف) والموظف (بريد): الهاتف/البريد الحقيقي في `guardians`/`staff`، وحساب Auth اصطناعي؛ الجلسة يصدرها Supabase Auth عبر Admin `generate_link` (magiclink) ثم `/verify` في الخادم — FastAPI لا يصدر JWT، والبريد الاصطناعي والـtoken_hash ورابط الجلسة والأسرار لا تصل إلى العميل. **I1:** الحساب الموقوف لا يبدأ مصادقة أصلاً (لا OTP ولا جلسة) بالرد الخارجي نفسه. **I2:** `auth.users.id = guardian_id` / `staff_id` — قاعدة موحدة مع D1: **Domain entity ID = Supabase Auth user ID**. **I4:** حدود معدّل Supabase Auth لكل IP = Production configuration dependency، لا مانع لـD3. **I6:** مسار الموظف مختبر قبل إغلاق D3. **I7:** قناة WhatsApp/SMS — المرحلة 5؛ مرسل محلي في D3 | F2 — Spike D3 (8/8) |
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
| 2026-10-08 | ✅ **3-3 — التكليفات ودورة الحياة (M48، M49 + API + الواجهة) — implemented, pending CI closure** — T1–T12 كما اعتُمدت: الجدولان و T17 ودالتا الإنهاء (M48)؛ P10 وإسقاط نطاق المدرسة (M49)؛ الـAPI `services/api/app/teaching.py` (السياق كله من صف الشعبة؛ الاستبدال = إنهاء ثم إدراج في معاملة واحدة؛ `operational` عرض مشتق للتكليف «المعلَّق»)؛ الواجهة: بطاقة «التكليفات» في صفحة السنة. pgTAP 2390 (52 ملفاً؛ `47`: 82، `48`: 41)، pytest 303 (`test_teaching` 8، منها **تزامن حقيقي**: معاملة تحجز (شعبة، مادة) وطلب ثانٍ ينتظر على الفهرس ثم 409)، Vitest 152 (+7)، Playwright 36 (+1)؛ الاستعادة PASS (نظيفة وبالـseed)؛ البناء الإنتاجي؛ الحتمية الرسمية (reset بلا seed ×2): بنية 0/2014؛ 54 migration؛ **ضوابط سلبية: API 11/11، DB 67/67** (بتشغيل «بلا تغيير» نظيف). الجولة الأولى كشفت **تسع فجوات اختبار أُغلقت باختبارات لا بتخفيف التنفيذ**: ست في DB (فحوص كُتبت لجدول التدريس دون جدول المربي؛ واختبار قراءة كان الـjoin على `schools` يخفي فيه صفوف المدارس الأخرى فلا يكشف سياسة بلا نطاق) وثلاث في الـAPI (سبب الإنهاء، حالة الموظف في «معلَّق»، تصفية الموظف). لا مفتاح صلاحية (75)؛ لا تغيير في T8 ولا حراس المرحلة 2 ولا `close_academic_year` ولا `can_see_membership`؛ لا تغيير في رؤية أي دور (التضييق في 3-4). **دين صغير مسجل (T11):** دور بلا نطاق يقرأ كتالوج الأدوار والصلاحيات فقط — لا مدرسة ولا أشخاص. `test_phase2b_acceptance`: قائمة ما أضافته المراحل اللاحقة صارت أربعة جداول؛ أعداد المرحلة 2 (39/75) كما هي | `supabase/migrations/2026100809*–10*`, `supabase/tests/{11,13,14,20,31,47,48}_*.test.sql`, `services/api/app/{teaching,main}.py`, `services/api/tests/{test_teaching,test_phase2b_acceptance}.py`, `apps/web/src/{pages/setup/{Assignments,Year}.tsx,i18n/ar.json,assignments.test.tsx}`, `apps/web/e2e/assignments.spec.ts`, `docs/{PHASE3_3_ASSIGNMENTS,PHASE3_2_ACCOUNT_ACCESS,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-08 | 🔒 **3-2 — Account / Role / Scope: CLOSED** — CI أخضر على `025b48c` (https://github.com/ahmedhmmad/sMas/actions/runs/37731428621) بكل خطواته (M01–M47 من الصفر، pgTAP، الاستعادة نظيفة وبالـseed، pytest، lint/typecheck/Vitest، البناء الإنتاجي، Playwright) وإشعاري استبعاد Storage المعتمدين؛ الـbaseline النهائي الموحد وضوابط API 14/14 كما سُجِّلت؛ لا migration. **يُحمَل إلى 3-3:** الإسقاط التلقائي لمنح التفويض عند انتهاء العلاقة (مع P10) — المنح الخامل حتى ذلك دين مسجل لا ثغرة وصول | `CLAUDE.md`, `docs/PHASE3_SCOPE.md`, `docs/PHASE3_2_ACCOUNT_ACCESS.md` |
| 2026-10-08 | ✅ **3-2 — الحساب والدور والنطاق (API + الواجهة، بلا migration)** — **Baseline نهائي موحد على الشجرة النهائية:** pgTAP 2261، الاستعادة نظيفة وبالـseed، pytest 295، lint/typecheck/Vitest 145، البناء الإنتاجي، Playwright 35، الحتمية الرسمية (reset بلا seed ×2) بنية 0/1901، 52 migration، ضوابط سلبية API 14/14 (بتشغيل «بلا تغيير» نظيف قبلها وبعدها). القرارات على الملاحظات: OTP في تبويب الموظف بصفحة الدخول معتمد ضمن 3-2؛ `school_admin` يسند دوراً مساوياً له — T8 كما هو (منعه قرار تفويض مستقل)؛ فحص Q3 في الخادم رسالة لا حدّ أمان؛ المنح المكرر 200؛ نطاق مدرسة غير مرئية يظهر بلا اسمها — دلالة قائمة مسجلة — A1–A9 كما اعتُمدت: `services/api/app/staff_access.py` (التفعيل الذري `POST /schools/{school}/staff/{staff}/account` = الحساب + نطاق المدرسة + الدور في معاملة واحدة مع تعويض حساب Auth؛ قراءة الوصول؛ القائمة القابلة للإسناد — عرض؛ منح/سحب الدور ونطاق المدرسة بسبب عبر G2؛ رفض T8 برمز `role_exceeds_authority` بلا سرد المفاتيح)؛ الواجهة: قسم «الحساب والصلاحيات» في صفحة الموظف، و**وضع رمز التحقق في تبويب الموظف بصفحة الدخول** (الحساب الجديد بلا كلمة مرور — P14؛ الـAPI قائم منذ D3). **لا migration ولا جدول ولا دالة ولا سياسة**؛ `can_see_membership` و H2 كما هما. pgTAP 2261 (بلا تغيير)، pytest 295 (`test_staff_access` 8، منها دخول فعلي بـOTP لموظف فُعِّل للتو)، Vitest 145 (+6)، Playwright 35 (+1: مدير المدرسة يفعّل الحساب من الواجهة والموظف الجديد يدخل بـOTP من host المدرسة)؛ الاستعادة PASS (نظيفة وبالـseed)؛ الحتمية: البنية 0. **ضوابط سلبية API 14/14** (واحد كشف فجوة — سحب نطاق مدرسة يمس نطاق الأخرى — أُغلقت باختبار). **تصحيح وثيقة بالتنفيذ:** T8 = «صلاحيات الدور ⊆ صلاحيات الفاعل»، فمدير المدرسة يسند دوراً مساوياً له (`school_admin`) ولا يسند `group_manager`/`tenant_admin` — سلوك Foundation القائم. **دلالة رؤية قائمة (known existing visibility semantics):** نطاق مدرسة لا يراها الفاعل يظهر في Access بلا اسمها ولا رمزها («مدرسة أخرى») — سياسة `membership_scopes` القائمة، بلا تعديل؛ لا يمنح الفاعل وصولاً (مُثبت). **ملاحظة Q3:** فحص `staff_not_assigned` في الخادم رسالة للفاعل متعدد المدارس فقط؛ لمدير المدرسة الشرط متحقق بالبناء، والرفض خارج العلاقة تحسمه DB (M47 — `46`) والرؤية (404) | `services/api/app/{staff_access,main}.py`, `services/api/tests/test_staff_access.py`, `apps/web/src/{pages/{Login,setup/Staff}.tsx,auth/loginFlows.ts,i18n/ar.json,staff.test.tsx}`, `apps/web/e2e/staff.spec.ts`, `docs/{PHASE3_2_ACCOUNT_ACCESS,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-08 | 🔒 **M47 — Staff First-Grant Membership Authorization: CLOSED** — CI أخضر على `c80ad44` (https://github.com/ahmedhmmad/sMas/actions/runs/37685326916) بكل خطواته (M01–M47 من الصفر، pgTAP، الاستعادة نظيفة وبالـseed، pytest، lint/typecheck/Vitest، البناء، Playwright) وإشعاري استبعاد Storage المعتمدين؛ الحتمية الرسمية (reset بلا seed ×2 بلا تدخل): البنية 0/1901؛ ضوابط الطفرة 9/10 بالاستثناء الموثق؛ حزم التفويض القائمة (12، 12b، 15، 19) بلا تعديل. امتداد متحكَّم به لـM12 — لا إعادة فتح لـFoundation. تشغيل CI لـ`971de21` (وثائق إغلاق 3-1) أُلغي ولا يمنع: محتواه ضمن `c80ad44`. **`can_see_membership` لا تُعدَّل كإصلاح عاجل** — دلالات شاشة Access تُحدَّد أولاً في تصميم 3-2 | `CLAUDE.md`, `docs/PHASE3_SCOPE.md` |
| 2026-10-07 | ✅ **M47 — فرع الموظف في `can_manage_membership` (3-2)** — امتداد متحكَّم به لـM12 (القرار A): أول منح (دور/نطاق) لحساب موظف جديد صار ممكناً لمدير المدرسة حين يكون للموظف تكليف مدرسة نشط ضمن نطاقه؛ لا مفتاح ولا سياسة، التوقيع والمالك والمنح كما هي. `46_staff_membership_grant` 40/40: مصفوفة الفاعل × الهدف، الحالات العشر المطلوبة، وإثبات داخل الحزمة (نص M12 بلا الفرع يُفشل مسار مدير المدرسة وحده). pgTAP 2261 (50 ملفاً)، pytest 287، Vitest 139، Playwright 34؛ الاستعادة PASS (نظيفة وبالـseed)؛ **ضوابط الطفرة 9/10** — غير الملتقَط: حذف سطر تطابق الـTenant في الدالة، وهو من M12 وزائد بالبناء (كل الفروع تحته محدودة بالـTenant) — دفاع بعمق، بلا اختبار مصطنع. **نقطة تصميم لـ3-2 (لم تُعدَّل):** `can_see_membership` (M12) لا تُظهر عضوية بلا نطاقات لموظف بلا تكليف نشط حتى لـ`tenant_admin` (يستطيع منحها ولا يراها) — تُحسم قبل شاشة Access، لا بالتفاف في الواجهة | `supabase/migrations/20261007120000_staff_membership_grant.sql`, `supabase/tests/46_staff_membership_grant.test.sql`, `docs/{PHASE3_SCOPE,RLS_MODEL_v1,DB_IMPLEMENTATION_SPEC_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-07 | 🔒 **3-1 — ملف الموظف مغلقة** — CI أخضر على `ee68f5a` (https://github.com/ahmedhmmad/sMas/actions/runs/37659159988) بكل خطواته وإشعاري استبعاد Storage المعتمدين (B6/E10)؛ M01–M46 من الصفر، pgTAP 2221، الاستعادة نظيفة وبالـseed، pytest 287، Vitest 139، Playwright 34؛ الضوابط السلبية API 9/9 و DB كما سُجِّلت | `CLAUDE.md`, `docs/PHASE3_SCOPE.md` |
| 2026-10-07 | ✅ **3-1 — ملف الموظف (M46 + API + الواجهة)** — `staff_specialties` و`staff_qualifications` [I] بالعلاقة (`staff_in_scope`) لا بالـTenant؛ الـAPI `services/api/app/staff.py`: قائمة موظفي المدرسة (تكليف نشط)، الإنشاء (`provision_staff`)، التعديل، الحالة (`set_staff_status` — بلا فحص رؤية مسبق: أرشفة الموظف المنتهي بنطاق الـTenant مشروعة)، تكليفات المدارس (`/schools/{id}/staff-assignments` — المدرسة هدف في المسار)، الإنهاء بسبب، التخصصات والمؤهلات؛ لا سياق ولا سلطة من الجسم؛ الواجهة `pages/setup/Staff.tsx` (رابط «الموظفون» في صفحة المدرسة بـ`staff.read`). pgTAP 2221 (45: 55)، pytest 287 (`test_staff_profile` 6)، Vitest 139 (+12)، Playwright 34 (+3: مدير المدرسة من الواجهة، المعلم يقرأ ويُرفض تجاوزه، السكرتير لا يرى)؛ الاستعادة PASS (نظيفة وبالـseed)؛ **الضوابط السلبية:** 9/9 API controls caught؛ DB controls: 37/40 mechanically catchable — 2 غير قابلين للكشف بطبيعة الاختبار (`select without tenant` على الجدولين: الشرط زائد بالبناء — الـFK المركّب يربط Tenant الصف بـTenant الموظف و`staff_in_scope` لا تمر إلا داخل Tenant الفاعل؛ يبقى دفاعاً بعمق كـ`staff_select`)، وفجوة qualifications read-key update أُغلقت باختبارات teacher-update إضافية (موجَّهة وعمياء). **تعديل اختبار لا سلوك:** `test_phase2b_acceptance` كان يثبّت «39 جدولاً بالضبط» — صار يثبت خط أساس المرحلة 2 (39 جدولاً، 75 مفتاحاً) مع قائمة مسمّاة لما تضيفه المراحل اللاحقة. **E2E كشف:** رفض التحقق في الـAPI (422 بقائمة) يظهر عاماً — حقل الهاتف بنمط E.164 (عرض) والرفض مثبت بتجاوز الواجهة | `supabase/migrations/20261007090000_staff_profile.sql`, `supabase/tests/{11,13,14,20,31,45}_*.test.sql`, `services/api/app/{staff,main}.py`, `services/api/tests/{test_staff_profile,test_phase2b_acceptance}.py`, `apps/web/src/{App.tsx,pages/setup/{Staff,School}.tsx,i18n/ar.json,staff.test.tsx}`, `apps/web/e2e/staff.spec.ts`, `docs/{PHASE3_SCOPE,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1}.md`, `CLAUDE.md` |
| 2026-10-07 | 🔒 **2B-6 مغلقة — 🔒 المرحلة 2 (إعداد المدرسة) مكتملة** — اعتماد الإغلاق: معيار «مدرسة كاملة من الواجهة» مُثبت بـPlaywright؛ 2B-1…2B-5 مكتملة ومختبرة؛ ضوابط سلبية DB 199 و API 56؛ عزل Tenant/School والتدقيق و reset/restore؛ بقاء إعدادات السنة السابقة دون تغيير؛ CI `94d0ccb`؛ استبعاد Storage صريح وموثق (B6)؛ البنود الثلاثة المؤجلة **Deferred / خارج المرحلة 2** لا عيوب. **المرحلة 2 baseline مغلقة: لا تعديل وظيفي عليها؛ أي عمل على backup/restore الملفات أو الجداول المؤقتة أو الشبكة قرار/نطاق جديد في مرحلته** | `CLAUDE.md`, `docs/PHASE2B_ACCEPTANCE.md`, `docs/PHASE2B_SCOPE.md`, `docs/PLAN_v3.md` |
| 2026-10-07 | ✅ **2B-6 — قبول إغلاق المرحلة 2 (اختبارات ووثائق فقط)** — CI أخضر (`94d0ccb`، https://github.com/ahmedhmmad/sMas/actions/runs/37421998492)؛ لا migration ولا مفتاح ولا endpoint ولا شاشة ولا قاعدة؛ `docs/PHASE2B_ACCEPTANCE.md` يفصل **PASS (مُثبت في المرحلة 2)** عن **DEFERRED (خارجها عمداً)**: معيارا PLAN — مدرسة كاملة من الواجهة وحدها (Playwright `wizard.spec` + القبول عبر الـAPI)، والإعدادات للسنة وتعديلها لا يمس سنة سابقة (`test_phase2b_acceptance`: نسخ إلى السنة التالية ثم تعديل النسخ — السنة السابقة متطابقة بايتياً في 15 صفاً من الجداول السبعة، ثم إغلاقها يجمّد كل إعداداتها)؛ الأجزاء 2B-1…2B-5 بأدلتها (ضوابط سلبية DB 199 و API 56)؛ DEFERRED: إثبات backup/restore الإنتاجي لمحتوى الملفات، جداول الدوام المؤقتة بمدى تواريخ، عرض الشبكة. pgTAP 2160، pytest 281، Vitest 127، Playwright 31؛ الاستعادة PASS | `services/api/tests/test_phase2b_acceptance.py`, `docs/PHASE2B_ACCEPTANCE.md`, `docs/PHASE2B_SCOPE.md`, `CLAUDE.md` |
| 2026-10-07 | 🔒 **2B-5 — معالج الإعداد مغلقة** — المراجعة PASS بلا ملاحظات مانعة؛ CI أخضر على `aeca5df` (https://github.com/ahmedhmmad/sMas/actions/runs/37420091454) بلا تغيير في الكود؛ حل عيب البطاقات داخل المعالج وحده معتمد (W6) | `CLAUDE.md`, `docs/PHASE2B_5_WIZARD.md`, `docs/PHASE2B_SCOPE.md` |
| 2026-10-07 | ✅ **2B-5 — معالج الإعداد (API + الواجهة، بلا migration)** — W1–W6 كما اعتُمدت والقيود العشرة: لا migration، لا مفتاح، لا `wizard_state`، لا دالة DB، لا endpoint كتابة؛ `GET /schools/{id}/setup-progress[?year_id=]` قراءة مشتقة واحدة تحت RLS بصلاحيات المستخدم؛ `ready_for_enrollment` باستعلام `/readiness` نفسه؛ `setup_complete` = الخطوات 1–6 (بلا الأصول ولا الجاهزية)؛ المواد والدوام شرط شامل لكل صف نشط له شعب؛ الواجهة `pages/setup/Wizard.tsx` تضمّن البطاقات القائمة نفسها، والسنة الافتراضية تُثبَّت في العنوان فلا تتغير تلقائياً. **معيار إغلاق المرحلة 2 مُثبت في Playwright** (`e2e/wizard.spec.ts`): `tenant_admin` يبني مدرسة كاملة من الصفر عبر المعالج وحده — مكتملة الإعداد وغير جاهزة (planned)، ثم جاهزة بعد التفعيل. pgTAP 2160 (بلا تغيير)، pytest 279 (`test_setup_progress` 4)، Vitest 127 (+4)، Playwright 31 (+2)؛ الاستعادة PASS؛ **ضوابط سلبية API 14** (واحد كشف فجوة — شمول الدوام لكل صف كان يُختبر بإسناد الصفين معاً — أُغلقت). **عيب كشفه Playwright وأُصلح في المعالج:** بطاقتا الخطوة الواحدة لا ترى إحداهما ما أنشأته الأخرى حتى إعادة التركيب — «تحديث التقدّم» يعيد تركيب بطاقات الخطوة | `services/api/app/setup.py`, `services/api/tests/test_setup_progress.py`, `apps/web/src/{App.tsx,pages/setup/{Wizard,School,Year,SchoolProfile}.tsx,i18n/ar.json,setup.test.tsx}`, `apps/web/e2e/wizard.spec.ts`, `docs/{PHASE2B_5_WIZARD,PHASE2B_SCOPE,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-07 | 🔒 **2B-4 — ملف المدرسة و Storage مغلقة** — معتمدة بلا تعديل بعد CI أخضر (`0bb66e4`) بإشعاري الاستبعاد الصريحين؛ لا إعادة تشغيل للاختبارات المحلية | `CLAUDE.md`, `docs/PHASE2B_4_PROFILE_STORAGE.md`, `docs/PHASE2B_SCOPE.md` |
| 2026-10-06 | ✅ **2B-4 — ملف المدرسة و Storage (M45 + FastAPI + الواجهة)** — CI أخضر (`0bb66e4`، https://github.com/ahmedhmmad/sMas/actions/runs/37417074088) مع إشعاري الاستبعاد الصريحين في التشغيل نفسه («Storage tests excluded»، «Storage E2E excluded»)؛ E1–E10 كما اعتُمدت مع ملاحظات الاعتماد؛ **FastAPI:** `images.py` (E6: التوقيع والأبعاد والحجم من البايتات، بلا مكتبة)، `storage_admin.py` (**الموضع الثاني** للمفتاح السري — موثق في `F4_API_SECURITY.md`؛ حارس `test_service_role` صار القائمة المغلقة {auth_admin، storage_admin})، `assets.py` (الـSaga E5: DB ← Storage ← commit؛ التنظيف لمسار الطلب وحده؛ تعذّره `500 asset_cleanup_failed`)؛ `python-multipart==0.0.32`؛ المسارات: `GET/PUT /schools/{id}/profile`، `GET/POST /schools/{id}/assets`، `POST /assets/{id}/retire`، `GET /assets/{id}/url` (60 ثانية)؛ **CI:** `pytest -m "not storage"` و`playwright --grep-invert @storage` مع `::notice`، وملخص pytest يطبع `EXCLUDED: N Storage integration tests` بأسمائها (Excluded ≠ skipped)؛ **محلياً** `storage-api` مُفعَّل وكل الاختبارات تعمل؛ **الاستعادة:** البصمة تحمل الـbuckets وقائمة الكائنات ونتيجة الاتساق (البايتات خارج الـdump — Production Readiness)؛ الواجهة: قسم «ملف المدرسة». pgTAP 2160 (44: 74)، pytest 275 (`test_school_assets` 15: 12 بلا Storage بمخزن مزيّف يحاكي الفشل + 3 `storage`)، Vitest 123 (+4)، Playwright 29 (+2، منها `@storage`)؛ الاستعادة PASS؛ **ضوابط سلبية: DB 49** (ثلاثة كشفت فجوات أُغلقت: UPDATE أعمى على الملف، تطبيع صفة التوقيع في الفهرس، حارس المدرسة المؤرشفة)، **API 12**. **وقائع أثناء التنفيذ:** (1) `app_owner` احتاج `USAGE` على schema `storage` (مُنح من `postgres` الذي يملك grant option — لا استثناء R2)؛ (2) CHECK بـ`between … and between` يعود من dump/restore بأقواس مختلفة فيُفشل البصمة — كُتب مسطّحاً؛ (3) اختبارات Storage الحقيقية تركت 17 كائناً يتيماً كشفها فحص الاتساق نفسه — حُذفت (عبر Storage API، بأسمائها) وصار تنظيف الاختبار يحذف الكائنات قبل الصفوف | `supabase/migrations/20261006120000_school_profile_assets.sql`, `supabase/tests/{11,13,14,20,31,44}_*.test.sql`, `scripts/db-fingerprint.sql`, `services/api/app/{assets,images,storage_admin,main}.py`, `services/api/{requirements.txt,pytest.ini}`, `services/api/tests/{conftest,test_school_assets,test_service_role}.py`, `apps/web/src/{pages/setup/{SchoolProfile,School}.tsx,lib/api.ts,i18n/ar.json,setup.test.tsx}`, `apps/web/e2e/setup.spec.ts`, `.github/workflows/ci.yml`, `docs/{PHASE2B_4_PROFILE_STORAGE,PHASE2B_SCOPE,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,F4_API_SECURITY,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-06 | 🔒 **2B-3 — الدوام والحصص مغلقة** — معتمدة بلا تعديل ولا migration إضافية؛ إصلاح عيب التكامل بين بطاقتي التقويم والدوام (كشفه Playwright) ضمن الإغلاق؛ الفجوات التي كشفتها الضوابط السلبية أُغلقت باختبارات لا بتخفيف القواعد | `CLAUDE.md`, `docs/PHASE2B_3_BELL_SCHEDULES.md`, `docs/PHASE2B_SCOPE.md` |
| 2026-10-06 | ✅ **2B-3 — الدوام والحصص (M43، M44 + API + الواجهة)** — CI أخضر (`8d736c2`، https://github.com/ahmedhmmad/sMas/actions/runs/37378736064)؛ D1–D7 كما اعتُمدت مع التثبيتين (D5: `id` ثابت والرقم مشتق؛ D6: قيد DB)؛ الـAPI: `GET/POST /academic-years/{id}/bell-schedules`، `PATCH /bell-schedules/{id}`، `GET/POST /bell-schedules/{id}/periods` (بـ`lesson_no` مشتق)، `PATCH /bell-periods/{id}`، `POST /bell-schedules/{id}/copy-day`، `GET /academic-years/{id}/grade-bell-schedules`، `PUT /academic-years/{id}/grade-bell-schedules/{grade_level_id}`، `POST /academic-years/{id}/copy-bell-schedules`؛ الواجهة: بطاقة «الدوام والحصص» في صفحة السنة. لا جدول دراسي ولا حضور بالحصة ولا جداول مؤقتة ولا إسناد شعبة. pgTAP 2080 (42: 76، 43: 40)، pytest 260 (`test_bell_schedules` 7)، Vitest 119 (+4)، Playwright 27 (سير tenant_admin والسكرتير موسَّعان)؛ الاستعادة PASS (نظيفة وبالـseed)؛ **ضوابط سلبية: DB 61 — ستة كشفت فجوات اختبار أُغلقت** (إدراج حصة بمفتاح القراءة، UPDATE أعمى على الإسناد — `SET col = col` يُطبّق سياسة SELECT فيخفي العطب فصار بقيمة ثابتة، هوية الجدول وهوية الإسناد، اختلاف اسم الحصة وحده في النسخ، و`[]` بدل `[)` كان يُفشل الاختبار قبل خطة pgTAP فلم يُحتسب — أُصلح المُشغّل)؛ **API 13** (واحد كشف فجوة — إدراج حصة في جدول مدرسة أخرى — أُغلقت). **Playwright كشف عيب واجهة أُصلح:** بطاقة الدوام كانت تقرأ أيام الدوام مرة عند فتح الصفحة فلا ترى أياماً عُرِّفت للتو في بطاقة التقويم — صارت تُقرأ عند فتح الجدول | `supabase/migrations/20261006090000_bell_schedules.sql`, `supabase/migrations/20261006100000_copy_bell_schedules.sql`, `supabase/tests/{11,13,14,20,31,42,43}_*.test.sql`, `services/api/app/setup.py`, `services/api/tests/test_bell_schedules.py`, `apps/web/src/{pages/setup/{BellSchedules,Year}.tsx,i18n/ar.json,setup.test.tsx}`, `apps/web/e2e/setup.spec.ts`, `docs/{PHASE2B_3_BELL_SCHEDULES,PHASE2B_SCOPE,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-05 | 🔒 **2B-2 — التقويم مغلقة** — معتمدة بلا تعديل ولا migration إضافية؛ CI `2a20197` لم يعمل (لا runner) و`c5a0aaf` بالكود نفسه أخضر — لا فشل اختبار مخفي | `CLAUDE.md`, `docs/PHASE2B_2_CALENDAR.md`, `docs/PHASE2B_SCOPE.md` |
| 2026-10-05 | ✅ **2B-2 — التقويم (M41، M42 + API + الواجهة)** — **CI:** run `2a20197` (https://github.com/ahmedhmmad/sMas/actions/runs/37369976412) وrun `38b80d2` الوثائقي قبله **أُلغيا دون تنفيذ أي خطوة**: «The job was not acquired by Runner of type hosted even after multiple attempts» — عطل بنية GitHub لا فشل اختبار؛ أُعيد التشغيل بـ`c5a0aaf` (الكود نفسه + وثيقة): **CI أخضر** (https://github.com/ahmedhmmad/sMas/actions/runs/37371644305)؛ C1–C5 كما اعتُمدت؛ الـAPI: `GET/PUT /academic-years/{id}/weekdays`، `POST /academic-years/{id}/copy-weekdays`، `GET/POST /academic-years/{id}/calendar-exceptions`، `PATCH /calendar-exceptions/{id}`، `POST /calendar-exceptions/{id}/cancel`؛ السبب من الجسم إلى `app.audit_reason` في المعاملة نفسها؛ CORS + `PUT`؛ الواجهة: بطاقة «التقويم» في صفحة السنة (عرض شهري للقراءة، تلوينه للعرض فقط). لا منطق حضور. pgTAP 1955 (40: 79، 41: 31)، pytest 253 (`test_calendar` 7)، Vitest 115 (+5)، Playwright 27 (سير tenant_admin والسكرتير موسَّعان)؛ الاستعادة PASS (نظيفة وبالـseed)؛ ضوابط سلبية: DB 53 (كلها مكتشفة؛ قبلها أُضيفت حالة `is_school_day` ليوم دوام معطَّل)، API 10 (واحد كشف فجوة — النسخ بلا سبب — أُغلقت) | `supabase/migrations/20261005090000_calendar.sql`, `supabase/migrations/20261005100000_copy_calendar_weekdays.sql`, `supabase/tests/{11,13,14,20,31,40,41}_*.test.sql`, `services/api/app/{setup,main}.py`, `services/api/tests/test_calendar.py`, `apps/web/src/{pages/setup/{Calendar,Year}.tsx,lib/api.ts,i18n/ar.json,setup.test.tsx}`, `apps/web/e2e/setup.spec.ts`, `docs/{PHASE2B_2_CALENDAR,PHASE2B_SCOPE,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-05 | 🔒 **2B-1 — المواد مغلقة** — معتمدة بلا تعديل: لا migration ولا مفتاح إضافي، والشبكة (صف × مادة) **لا تُضاف الآن** — قرار UX لاحق خارج نطاق المرحلة؛ 265 = 255 (M23) + 10 روابط M38 بالتوزيع المعتمد (مُتحقَّق من DB) | `CLAUDE.md`, `docs/PHASE2B_SCOPE.md` |
| 2026-10-04 | ✅ **2B-1 — المواد (M38–M40 + API + الواجهة)** — CI أخضر (`7187ccd`، https://github.com/ahmedhmmad/sMas/actions/runs/37233047532)؛ M38 المفتاحان (75)، M39 الجدولان و T13، M40 النسخ؛ الـAPI (`/schools/{id}/subjects`، `/subjects/{id}`، `/academic-years/{id}/grade-subjects`، `/grade-subjects/{id}`، `/academic-years/{id}/copy-grade-subjects`)؛ الواجهة: «المواد» في صفحة المدرسة و«مواد الصفوف» + النسخ في صفحة السنة (قائمة لا شبكة). pgTAP 1839 (38: 54، 39: 36)، pytest 246 (`test_subjects` 6)، Vitest 110 (+5)، Playwright 27؛ الاستعادة PASS (نظيفة وبالـseed)؛ ضوابط سلبية: DB 36 (اثنان كشفا فجوتين أُغلقتا: UPDATE الأعمى، واختلاف «المجموع» وحده)، API 7 | `supabase/migrations/2026100409*–11*`, `supabase/tests/{11,13,14,15,20,23,31,34..39}_*.test.sql`, `supabase/seed.sql`, `services/api/app/setup.py`, `services/api/tests/test_subjects.py`, `apps/web/src/{pages/setup/{School,Year}.tsx,i18n/ar.json,setup.test.tsx}`, `apps/web/e2e/setup.spec.ts`, `docs/{DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,PHASE2B_SCOPE,AUTHORIZATION_MATRIX_v1,ROLE_PERMISSION_SEED_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-04 | 🔒 **Phase 2A — School Setup مغلقة** — CI `3c68a7d`، https://github.com/ahmedhmmad/sMas/actions/runs/37207754351؛ قائمة القبول (21) مستوفاة؛ Phase 2 **ليست** مكتملة: 2B بخطة نطاق مستقلة | `CLAUDE.md`, `docs/PHASE2A_ACCEPTANCE.md`, `docs/PHASE2_SCHOOL_SETUP.md`, `docs/PLAN_v3.md` |
| 2026-10-04 | ✅ **P2-E — قبول الإغلاق** — اختبارات ووثائق فقط: `test_phase2a_acceptance` (المسار المعتمد بالترتيب، الجاهزية بعد كل خطوة ولا تصير true خطأً، تدقيق 16 عملية بفاعلها وسببها، الرفض بلا صف)؛ `docs/PHASE2A_ACCEPTANCE.md` (21 بنداً ← دليل كل منها؛ ملاحظات مصنَّفة بلا نقص وظيفي). pgTAP 1743، pytest 240، Vitest 105، Playwright 27؛ الاستعادة PASS (نظيفة وبالـseed) | `services/api/tests/test_phase2a_acceptance.py`, `docs/{PHASE2A_ACCEPTANCE,PHASE2_SCHOOL_SETUP}.md`, `CLAUDE.md` |
| 2026-10-04 | ✅ **P2-D — الواجهة** — `apps/web/src/pages/setup/` (المجموعات، المدارس، المدرسة، السنة): كل البيانات عبر FastAPI؛ الأزرار بالمفاتيح (عرض فقط)؛ الجاهزية من الـAPI وحده؛ أخطاء الـAPI بنصوص الفهرس؛ RTL و`t(key)` (قاعدة lint)؛ Vitest 105 (`setup.test` 18)، Playwright 27 (`setup.spec` 6: tenant_admin من الصفر حتى الجاهزية، مدير المجموعة، مدير المدرسة، السكرتير، بلا صلاحية، السياق ليس سلطة — وكل «ممنوع» يتجاوز الواجهة إلى الـAPI)؛ 7 ضوابط سلبية على الواجهة | `apps/web/src/{App.tsx,components/navigation.ts,i18n/ar.json,lib/api.ts,pages/setup/*,setup.test.tsx}`, `apps/web/e2e/setup.spec.ts`, `docs/PHASE2_SCHOOL_SETUP.md`, `CLAUDE.md` |
| 2026-10-04 | ✅ **P2-C — الـAPI** — `services/api/app/setup.py`: المجموعات، المدارس (إنشاء، تعديل، `slug`، أرشفة، جاهزية، نمط ولي الأمر القائم)، السنوات (+ تفعيل/إغلاق/نسخ الشعب)، الفصول (+ تفعيل/إغلاق)، المراحل، الصفوف، الشعب؛ لا DELETE؛ لا سياق ولا سلطة من الطلب (`extra="forbid"`، الـTenant من DB، مدرسة الابن من أبيه)؛ 404 غير مرئي / 403 مرئي ومرفوض؛ `23P01`←409، `23502`←422؛ CORS + `PATCH`؛ `RETURNING` ممنوع لإدراج المجموعة والمدرسة (يُرفض حتى لمدير الـTenant — مُثبت). pytest 239 (`test_school_setup` 14)، pgTAP 1743، Vitest 87؛ الاستعادة PASS؛ 12 ضابطاً سلبياً على الكود | `services/api/app/{setup,main,deps}.py`, `services/api/tests/{conftest,test_school_setup}.py`, `docs/PHASE2_SCHOOL_SETUP.md`, `CLAUDE.md` |
| 2026-10-03 | ✅ **M37 — نسخ الشعب** — pgTAP 1743 (37: 41)، pytest 225، Vitest 87؛ الاستعادة PASS (نظيفة وبالـseed)؛ 18 ضابطاً سلبياً؛ عقد §8 منقّح (لا `ON CONFLICT DO NOTHING`، سبب، صف domain) | `supabase/migrations/20261003130000_copy_sections.sql`, `supabase/tests/{20,31,37}_*.test.sql`, `docs/{PHASE2_SCHOOL_SETUP,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-03 | ✅ **M36 — تغيير `slug` بدالة متحكَّم بها** — pgTAP 1702 (36: 46)، pytest 225، Vitest 87؛ الاستعادة PASS (نظيفة وبالـseed)؛ 14 ضابطاً سلبياً | `supabase/migrations/20261003110000_school_slug.sql`, `supabase/tests/{20,30b,31,36}_*.test.sql`, `docs/{PHASE2_SCHOOL_SETUP,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,F3_HOST_CONTEXT}.md`, `CLAUDE.md` |
| 2026-10-03 | ✅ **M35 — حواجز البنية** — T12 على الشعب والصفوف والمراحل؛ pgTAP 1656 (35: 66)، pytest 225، Vitest 87؛ الاستعادة PASS (نظيفة وبالـseed)؛ 21 ضابطاً سلبياً. **ملاحظة للمرحلة 4:** `provision_student` و`transfer_enrollment` لا تفحصان حالة الشعبة ولا السنة — التسجيل في شعبة معطّلة أو سنة مغلقة قاعدة قبول تُحسم هناك | `supabase/migrations/20261003090000_structure_guards.sql`, `supabase/tests/{16,20,31,35}_*.test.sql`, `docs/{PHASE2_SCHOOL_SETUP,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1}.md`, `CLAUDE.md` |
| 2026-10-02 | ✅ **M34 — دورة حياة الفصول** — فهرس الفصل النشط الواحد، T11، `activate_term`/`close_term`، إغلاق السنة يُرفض مع فصل نشط؛ pgTAP 1590 (34: 70)، pytest 225، Vitest 87؛ الاستعادة PASS (نظيفة وبالـseed)؛ 22 ضابطاً سلبياً | `supabase/migrations/20261002140000_term_lifecycle.sql`, `supabase/tests/{20,31,33,34}_*.test.sql`, `docs/{PHASE2_SCHOOL_SETUP,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1}.md`, `CLAUDE.md` |
| 2026-10-02 | ✅ **Phase 2A — P2-A معتمدة + M33** — وثيقة التصميم و Q1–Q9 معتمدة؛ T10 (حارس السنة الأكاديمية)؛ pgTAP 1520 (33: 37)، pytest 225، Vitest 87؛ الاستعادة PASS (نظيفة وبالـseed)؛ 9 ضوابط سلبية | `supabase/migrations/20261002120000_academic_year_guard.sql`, `supabase/tests/{08,31,33}_*.test.sql`, `docs/{PHASE2_SCHOOL_SETUP,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-02 | ⏳ **Phase 2A — P2-A:** خطة النطاق والقرارات 1–11 معتمدة؛ وثيقة التصميم مكتوبة (عقود الكيانات، state machines، الجاهزية، مصفوفة الدور × العملية، النطاقات، الدوال المتحكَّم بها، CRUD مقابل الانتقال، عقد نسخ الشعب، التدقيق، عقد الـAPI، قبول الواجهة) مع 9 نقاط تفصيلية (Q1–Q9) بانتظار التأكيد — لا SQL ولا كود | `docs/PHASE2_SCHOOL_SETUP.md`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-10-02 | 🔒 **Stage 1 مغلق — المرحلة 1 مكتملة** — CI `f41b0ff`، https://github.com/ahmedhmmad/sMas/actions/runs/36992802792؛ معايير الإنجاز الأربعة؛ لا C مفتوحة ولا جديدة؛ المؤجل بقرار (§9.5 من المراجعة) لا يمنعها | `CLAUDE.md`, `docs/STAGE1_REVIEW.md`, `docs/PLAN_v3.md` |
| 2026-10-02 | ✅ **M31 + M32 — إصلاح نتائج C لمراجعة Stage 1** — S1 (`relationship_source`: صلاحية الربط ≠ إدارة الحساب)، S2 (`students_update` WITH CHECK)، C1 (sequences)، C2 (`MAINTAIN`)، C3 (فهرسان + استثناء FK الهوية)؛ pgTAP 1483 (32: 40)، pytest 225، Vitest 87؛ الاستعادة PASS (نظيفة وبالـseed)؛ ضوابط سلبية M31 5 / M32 10؛ لا C جديدة | `supabase/migrations/20261002090000_security_relationship_source.sql`, `supabase/migrations/20261002100000_privilege_index_followup.sql`, `supabase/tests/{20,27,31,32}_*.test.sql`, `docs/{STAGE1_REVIEW,DATA_DICTIONARY_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,F2_AUTHENTICATION,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-01 | ✅ **مراجعة Stage 1 (R1–R10)** — لا عمود ولا قيد موثق غائب عن DB؛ الـ46 invariant بكائناتها؛ 61 سياسة مطابقة؛ 7 فجوات اختبار أُغلقت و حراس دائمة (`31`: 23، + 11 ضابطاً سلبياً)؛ بصمة الاستعادة وُسِّعت (929 ← 1360 سطراً)؛ 14 تصحيح وثائق. **C مفتوحة: S1، S2 (أمنيتان، معتمدتان)، C1–C3** — لا migration نُفذت. pgTAP 1440 | `docs/STAGE1_REVIEW.md`, `supabase/tests/31_stage1_contract.test.sql`, `scripts/db-fingerprint.sql`, `docs/{DATA_DICTIONARY_v1,ERD_CORE_v1,DB_IMPLEMENTATION_SPEC_v1,RLS_MODEL_v1,TRACEABILITY_E1_E4,PLAN_v3}.md`, `CLAUDE.md` |
| 2026-10-01 | 🔒 **F3 مغلق و Gate F مكتمل (F1–F4)** — CI أخضر (`d3d12b1`، https://github.com/ahmedhmmad/sMas/actions/runs/36872502996)؛ pgTAP 1417، pytest 225، Vitest 87، Playwright 21؛ البنود الأربعة لمراجعة F3 محسومة | `CLAUDE.md`, `docs/F3_HOST_CONTEXT.md`, `docs/PLAN_v3.md` |
| 2026-10-01 | ✅ **مراجعة F3 + M30b** — `host_label` و`schools.slug` labels DNS (فحص البيانات القائمة قبل القيد، بلا تصحيح تلقائي)؛ المحللان والمتجهات على القاعدة نفسها؛ اختبار مستقل لـinvariant دخول الطالب؛ pgTAP 1417، pytest 225، Vitest 87، Playwright 21 | `supabase/migrations/20261001120000_host_dns_labels.sql`, `supabase/tests/30b_host_dns.test.sql`, `services/api/app/host_context.py`, `services/api/tests/test_host_context.py`, `apps/web/src/context/hostContext{,.test}.ts`, `docs/contracts/host_context_vectors.json`, `docs/*`, `CLAUDE.md` |
| 2026-10-01 | ✅ **F3 + M30** — سياق الـhost: `host_label`، `login_context`، الدخول من `Origin` وحده بلا حقول سياق، CORS مرسَّخ بالمحلل نفسه، الواجهة من الـhost وإزالة أداة التطوير؛ pgTAP 1395، pytest 213، Vitest 77، Playwright 21؛ ضوابط سلبية DB 3 / API 8 / Web 6 (+ ملاحظة دفاع بطبقتين) | `supabase/migrations/20261001090000_tenant_host_context.sql`, `supabase/tests/{03..29,30}_*.test.sql`, `supabase/seed.sql`, `services/api/**`, `apps/web/**`, `docs/contracts/host_context_vectors.json`, `docs/F3_HOST_CONTEXT.md`, `docs/*`, `.github/workflows/ci.yml`, `.env.example`, `CLAUDE.md` |
| 2026-09-28 | 🔒 **F1 مغلق** — CI أخضر (`25570ce`، https://github.com/ahmedhmmad/sMas/actions/runs/36353813939)؛ pgTAP 1346، pytest 132، Vitest 32، Playwright 16 | `CLAUDE.md`, `docs/F1_WEB_APP.md`, `docs/PLAN_v3.md` |
| 2026-09-28 | ✅ **F1/W1 + M29** — قراءة المنصة لبيانات Tenant مسار واحد مُدقَّق داخل DB؛ لا قراءة مباشرة عبر PostgREST للجداول الثلاثة؛ pgTAP 29: 15؛ pytest 132 (اختبارا F4 لفشل التدقيق صارا اختباراً واحداً على الآلية الجديدة) | `supabase/migrations/20260928090000_platform_reads.sql`, `supabase/tests/{14,20,21b,29}_*.test.sql`, `services/api/**`, `docs/*`, `CLAUDE.md` |
| 2026-09-28 | ✅ **F1/W2** — أداة سياق التطوير dev-only فعلياً (وحدة كسولة يطويها البناء، فحص حزمة production في CI، حارس `vite build`)؛ Vitest 32، E2E 16. **القيد التشغيلي: Node 22** لـCI والتشغيل؛ `API_LOGIN_ATTEMPTS` افتراضي 10 / `API_LOGIN_WINDOW_SECONDS` 300 | `apps/web/**`, `.github/workflows/ci.yml`, `docs/F1_WEB_APP.md`, `CLAUDE.md` |
| 2026-09-27 | ✅ **F1 — تطبيق الويب** — `apps/web`: shell، سياق، capabilities، تنقل، دخول (موظف، ولي أمر OTP/كلمة مرور، طالب، إداري)، تغيير إجباري، انتهاء الجلسة، الطلاب/التفاصيل/التصدير، الجهات (مُدقَّقة)؛ Vitest 29، Playwright 16؛ `API_LOGIN_ATTEMPTS` إعداد؛ CI Node 22 + خطوات الويب | `apps/web/**`, `services/api/app/{config,main}.py`, `services/api/tests/{conftest,web_e2e_fixtures}.py`, `.github/workflows/ci.yml`, `docs/F1_WEB_APP.md`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-27 | ✅ **F1 — الخلفية:** M28 `my_permissions` + `GET /me/capabilities` + `GET /platform/tenants` (مُدقَّق N5) + CORS من البيئة + مرسل OTP ملفي بحراساته؛ pgTAP 28: 20؛ pytest 133/133 | `supabase/migrations/20260927090000_my_permissions.sql`, `supabase/tests/{20,28}_*.test.sql`, `services/api/**`, `.env.example`, `.gitignore`, `CLAUDE.md`, `docs/PLAN_v3.md` |
| 2026-09-27 | 🔒 **F2 مغلق** — E2E أخضر في CI (`860a14a`، https://github.com/ahmedhmmad/sMas/actions/runs/36332097484)؛ pgTAP 1311/1311، pytest 116/116 | `CLAUDE.md`, `docs/F2_AUTHENTICATION.md`, `docs/PLAN_v3.md` |
| 2026-09-27 | ✅ **F2 — E2E لكل الأدوار** — 11 حساباً بمسارها الحقيقي حتى البيانات المسموحة والممنوعة؛ ولي الأمر A/B/C والطالب first-login؛ 13/13 (116/116)؛ ضابطان سلبيان | `services/api/tests/test_e2e_auth.py`, `docs/F2_AUTHENTICATION.md`, `CLAUDE.md` |
| 2026-09-27 | 🔒 **D4/M27 مغلقان** — CI أخضر (`fb71356`)؛ بوابة إغلاق F2 = E2E لكل الأدوار بالمسار الكامل | `CLAUDE.md`, `docs/F2_AUTHENTICATION.md` |
| 2026-09-26 | ✅ **F2/D4 + M27** — onboarding ولي الأمر A/B/C بالمدرسة الهدف؛ D4.1 و D4.2؛ إصدار C؛ pgTAP 27: 41؛ pytest 103/103؛ 6 ضوابط سلبية | `supabase/migrations/20260926200000_guardian_onboarding.sql`, `supabase/tests/{20,26,27}_*.test.sql`, `services/api/**`, `docs/*`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **D3/M26 مغلقان** — CI أخضر (`bdfce09`)؛ الافتراضيات والاستثناءات معتمدة (§6)؛ `tenant_admin` خارج D3 بقرار | `CLAUDE.md`, `docs/F2_AUTHENTICATION.md`, `docs/PLAN_v3.md` |
| 2026-09-26 | ✅ **F2/D3 + M26** — دخول حسابات Tenant (ولي الأمر، الموظف) بـOTP وكلمة المرور؛ جلسة من Supabase Auth؛ I1، I2 في DB؛ الـseed على I2؛ pgTAP 26: 46؛ pytest 97/97؛ 5 ضوابط سلبية | `supabase/migrations/20260926180000_tenant_account_login.sql`, `supabase/tests/{11,13,14,20,22,26}_*.test.sql`, `supabase/seed.sql`, `services/api/**`, `docs/*`, `.env.example`, `CLAUDE.md` |
| 2026-09-26 | 🔬 **D3 Spike ✅ 8/8** — هوية اصطناعية لكل حساب Tenant؛ جلسة من Supabase Auth عبر `generate_link`(magiclink) + `/verify` في الخادم؛ الهاتف نفسه في Tenantين بلا كشف؛ القفل، الحظر، كلمة المرور، رموز مزوّرة مرفوضة في FastAPI و PostgREST؛ شرط إنتاج: حدود معدّل Supabase Auth لكل IP (تمس D1) | `spikes/d3/*`, `docs/F2_AUTHENTICATION.md`, `CLAUDE.md` |
| 2026-09-26 | 🔒 **D2/M25 مغلقان** — CI أخضر (`62c76b1`)؛ طالب الـseed `pending` صحيح (lifecycle الحقيقي — اختبارات E2E تُتم first-login أولاً)؛ **ملاحظة أداء:** مسح `auth.audit_log_entries` بلا فهرس — يُقاس زمن `activate_first_login()` وحجم الجدول مع بيانات حقيقية، ولا فهرس الآن بافتراض ولا تعديل غير مدعوم لجداول Supabase | `CLAUDE.md`, `docs/F2_AUTHENTICATION.md` |
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
