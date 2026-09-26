# Data Dictionary v1 — Foundation

**التاريخ:** 2026-09-22
**الحالة:** مسودة للمراجعة — البند A1 في `CLAUDE.md` §3
**المرجع:** `ERD_CORE_v1.md` (النموذج المنطقي) + `PLAN_v3.md` §3.3 (القواعد الإلزامية) و§10 (Implementation Lock)
**النطاق:** جداول Foundation فقط. Finance / Timetable / Grading internals / OCR / Payroll خارج هذا الملف، وتتبع نفس القواعد عند الوصول إليها.

> هذا الملف هو المرجع المُلزم للأعمدة والأنواع والقيود قبل كتابة أي migration (Gate C). أي جدول غير موصوف هنا لا تُكتب له migration.

---

## 0. الاصطلاحات العامة

### 0.1 الأنواع والمفاتيح

| البند | القاعدة |
|---|---|
| المفتاح الأساسي | `id uuid PRIMARY KEY DEFAULT gen_random_uuid()` في كل جدول إلا جداول الربط الصرفة |
| الوقت | `timestamptz` حصراً. لا `timestamp` ولا `date` إلا للتواريخ التقويمية الصرفة (بداية سنة، تاريخ ميلاد) |
| النصوص | `text` (لا `varchar(n)`)، والطول يُقيَّد بـ`CHECK` عند الحاجة الفعلية |
| المبالغ | `numeric(12,2)` — لا تظهر في Foundation، مذكورة للاتساق |
| المنطقية | `boolean NOT NULL DEFAULT false` — لا `boolean` قابل لـNULL |
| JSON | `jsonb` فقط |

### 0.2 قرار: `text + CHECK` بدل PostgreSQL ENUM

كل الحقول المحصورة بقيم (`status`, `scope_type`, `actor_type`, ...) تُنفَّذ:

```sql
status text NOT NULL DEFAULT 'active'
  CONSTRAINT <table>_status_chk CHECK (status IN ('active','suspended'))
```

**السبب:** إضافة قيمة إلى `ENUM` تتطلب `ALTER TYPE ... ADD VALUE` (غير قابل للتراجع داخل transaction في بعض الحالات)، وحذف قيمة يتطلب إعادة بناء النوع بالكامل — وهذا يصطدم بقاعدة "لا تعديل على migration منفذة" (`PLAN_v3.md` §3.3 بند 19). أما `CHECK` فيُستبدل بـ`DROP CONSTRAINT` + `ADD CONSTRAINT` في migration جديدة نظيفة.

كل قيد `CHECK` يأخذ اسماً صريحاً (`<table>_<column>_chk`) حتى يمكن استبداله لاحقاً باسمه.

### 0.3 الأعمدة المشتركة

تُضاف إلى كل جدول أعمال ما لم يُذكر خلاف ذلك:

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `created_at` | timestamptz | NOT NULL | `now()` | |
| `updated_at` | timestamptz | NOT NULL | `now()` | يُحدَّث عبر trigger `app.tg_set_updated_at()` |
| `created_by` | uuid | NULL | — | FK → `profiles(id)`، NULL للعمليات النظامية والـseed |
| `updated_by` | uuid | NULL | — | FK → `profiles(id)` |

`archived_at timestamptz NULL` تُضاف فقط للجداول ذات الحذف الناعم (`students`, `staff`, `guardians`, `schools`, وما يُذكر صراحةً).

### 0.4 قطعة الاسم الرباعي

تُطبَّق حرفياً في `students`, `guardians`, `staff` (قاعدة `PLAN_v3.md` §3.3 بند 8):

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `first_name` | text | NOT NULL | `CHECK (length(btrim(first_name)) > 0)` |
| `father_name` | text | NULL | |
| `grandfather_name` | text | NULL | |
| `family_name` | text | NOT NULL | `CHECK (length(btrim(family_name)) > 0)` |
| `full_name` | text | GENERATED | `GENERATED ALWAYS AS (btrim(regexp_replace(concat_ws(' ', first_name, father_name, grandfather_name, family_name), '\s+', ' ', 'g'))) STORED` |

`full_name` محسوب ومخزَّن — لا يُكتب من التطبيق أبداً، ويُفهرس للبحث.

> **🔴 تصحيح تنفيذي (M09، 2026-09-24):** الصيغة أعلاه **لا تُنفَّذ** — `concat_ws` مصنّفة `STABLE` فيرفضها Postgres في عمود محسوب (`generation expression is not immutable`، ثبت على PG 17.6). المُنفَّذ — الناتج نفسه بدوال `IMMUTABLE`:
>
> ```sql
> GENERATED ALWAYS AS (btrim(regexp_replace(
>   first_name || ' ' || coalesce(father_name, '') || ' ' ||
>   coalesce(grandfather_name, '') || ' ' || family_name, '\s+', ' ', 'g'))) STORED
> ```
>
> الاختبار `09_people` يقارن الناتج بالصيغة الأصلية على كل صف (أسماء ناقصة، مسافات زائدة): مطابق.

### 0.5 الهاتف

`phone_e164 text` مع:

```sql
CONSTRAINT <table>_phone_e164_chk CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$')
```

لا يُخزَّن أي رقم بصيغة محلية. التحويل مسؤولية طبقة الإدخال.

### 0.6 نمط سلامة الـTenant عبر FK المركّب

لمنع ارتباط صف بأب من Tenant آخر، **لا نعتمد على trigger**، بل على FK مركّب:

```sql
-- في جدول الأب
ALTER TABLE groups ADD CONSTRAINT groups_id_tenant_uq UNIQUE (id, platform_tenant_id);

-- في جدول الابن
ALTER TABLE schools ADD CONSTRAINT schools_group_same_tenant_fk
  FOREIGN KEY (group_id, platform_tenant_id)
  REFERENCES groups (id, platform_tenant_id);
```

هذا يجعل القاعدة مفروضة من المحرك لا من الكود. كل جدول أب يحمل `platform_tenant_id` يُضاف له `UNIQUE (id, platform_tenant_id)` لهذا الغرض، حتى لو بدا زائداً.

الجداول التي تحمل `UNIQUE (id, platform_tenant_id)`: `groups`, `schools`, `profiles`, `memberships`, `staff`, `students`, `guardians`, `families`, `roles`, `identity_scopes`.
الجداول التي تحمل `UNIQUE (id, school_id)`: `academic_years`, `grade_levels`, `sections`, `stages`.

**مفاتيح مرجعية إضافية (Gate B):** `roles (id, owner_key)`، `academic_years (id, school_id, start_date, end_date)`، `sections (id, school_id, academic_year_id, grade_level_id)`، `schools (id, is_standalone)`؛ ومع ✅ G3: `schools (id, scope_owner_id)`، `identity_scopes (id, owner_id)`، `students (id, identity_scope_id)`. السجل الكامل: `DB_IMPLEMENTATION_SPEC_v1.md` §4.2.

### 0.7 سلوك FK عند الحذف

القاعدة الافتراضية: `ON DELETE RESTRICT`. الاستثناءات الوحيدة `ON DELETE CASCADE` هي جداول الربط الصرفة التي لا معنى لها بدون طرفيها (`role_permissions`, `membership_roles`, `membership_scopes`, `platform_admin_role_permissions`). لا يوجد `ON DELETE SET NULL` في Foundation.

### 0.8 مستويات الملكية المستخدمة

| الرمز | المستوى | قاعدة العزل |
|---|---|---|
| **P** | Platform / System | خارج Tenant — Platform Admin فقط |
| **T** | Platform Tenant | `platform_tenant_id` NOT NULL |
| **G** | Group | داخل Tenant + Group scope |
| **S** | School | `school_id` NOT NULL + School scope |
| **I** | Identity داخل Tenant | `platform_tenant_id` NOT NULL، **بلا** `school_id`؛ الوصول عبر العلاقة |
| **A** | Audit stream | tenant/school داخل الصف |

---

## 1. خريطة الملكية — جداول Foundation

| # | الجدول | الملكية | ملاحظة |
|---|---|---|---|
| 1 | `platform_tenants` | P | جذر العزل |
| 2 | `groups` | T | |
| 3 | `schools` | T | وحدة التشغيل |
| 4 | `system_users` | P | Platform Admin identity |
| 5 | `platform_admin_roles` | P | |
| 6 | `platform_admin_role_permissions` | P | قدرات Platform Admin (قرار C3) |
| 7 | `platform_admin_assignments` | P | |
| 8 | `profiles` | T | |
| 9 | `memberships` | T | 1:1 مع profile |
| 10 | `roles` | T / P | `platform_tenant_id IS NULL` = قالب نظام |
| 11 | `permissions` | P | كتالوج عالمي — 73 مفتاحاً |
| 12 | `role_permissions` | يتبع `roles` | |
| 13 | `membership_roles` | يتبع `memberships` | |
| 14 | `membership_scopes` | يتبع `memberships` | |
| 15 | `staff` | I | |
| 16 | `staff_school_assignments` | S | |
| 17 | `families` | I | |
| 18 | `identity_scopes` | T | نطاق تفرد هوية الطالب — Group أو مدرسة مستقلة |
| 19 | `students` | I | **بلا `school_id` ولا `group_id`**؛ التفرد عبر `identity_scope_id` |
| 20 | `guardians` | I | |
| 21 | `student_guardians` | يتبع `students` | |
| 22 | `enrollments` | S | جسر الهوية ↔ المدرسة |
| 23 | `academic_years` | S | |
| 24 | `terms` | S (عبر السنة) | |
| 25 | `stages` | S | |
| 26 | `grade_levels` | S | |
| 27 | `sections` | S | |
| 28 | `audit_log` | A | |
| (29) | `auth_identities` | P | ✅ G10 — حصرية هوية Tenant/Platform |

---

## 2. الجداول

### 2.0 `auth_identities` — [P] (G10)

حساب Auth واحد = سياق أمني واحد. المفتاح الأساسي على `auth_user_id` يجعل الحصرية بين `tenant` و`platform` **إعلانية بلا race**.

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `auth_user_id` | uuid | NOT NULL | — | PK، FK → `auth.users(id)` |
| `kind` | text | NOT NULL | — | `tenant` \| `platform` |
| `created_at` | timestamptz | NOT NULL | `now()` | |
| `credential_state` | text | NOT NULL | `'active'` | ✅ M25 (F2/D2): `active` \| `pending` — `pending` ⇒ `current_profile_id()`/`current_tenant_id()` = NULL (بوابة الجذر) |
| `credential_issued_at` | timestamptz | NULL | — | ✅ M25: لحظة كتابة الكلمة المؤقتة **بساعة Supabase Auth** (`auth.users.updated_at` بعد الكتابة، عبر `arm_first_login`)؛ NULL = لم تُصدَر بعد ⇒ لا تفعيل |
| `credential_activated_at` | timestamptz | NULL | — | ✅ M25: لحظة التفعيل عبر `activate_first_login` |

**القيود:** `PRIMARY KEY (auth_user_id)`؛ `CHECK (kind IN ('tenant','platform'))`؛ `UNIQUE (auth_user_id, kind)`؛ ✅ M25: `auth_identities_credential_state_chk` (`credential_state IN ('active','pending')`)، `auth_identities_credential_kind_chk` (حساب المنصة `active` دائماً — D2 لحسابات Tenant)، `auth_identities_credential_activated_chk` (`credential_activated_at` ⇒ `active`) — هدف FK من:
- `profiles (auth_user_id, identity_kind)` حيث `identity_kind` ثابت `'tenant'` (`CHECK`)
- `system_users (auth_user_id, identity_kind)` حيث `identity_kind` ثابت `'platform'` (M05)

`app.current_security_context()` (`RLS_MODEL_v1.md` §2.1) تقرأ `kind` من هنا.

---

### 2.1 `platform_tenants` — [P]

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `tenant_code` | text | NOT NULL | — | فريد على مستوى المنصة، ثابت، غير معاد الاستخدام |
| `name` | text | NOT NULL | — | |
| `status` | text | NOT NULL | `'active'` | `active`, `suspended` |
| `suspended_at` | timestamptz | NULL | — | |
| `created_at` / `updated_at` | timestamptz | NOT NULL | `now()` | |

**القيود:**
- `PK (id)`
- `UNIQUE (tenant_code)`
- `CHECK (tenant_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$')` — أكواد الأعمال بصيغة ثابتة قابلة للطباعة
- `CHECK (status IN ('active','suspended'))`
- `CHECK ((status = 'suspended') = (suspended_at IS NOT NULL))`

**ملاحظات:** `suspended` لا يحذف بيانات ولا يمنع القراءة الإدارية؛ يمنع العمليات التشغيلية ويسمح بإعادة التفعيل. لا يوجد حذف لصف Tenant.

---

### 2.2 `groups` — [T]

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `platform_tenant_id` | uuid | NOT NULL | — | FK → `platform_tenants(id)` |
| `group_code` | text | NOT NULL | — | فريد داخل Tenant، ثابت، غير معاد الاستخدام |
| `name` | text | NOT NULL | — | |
| `status` | text | NOT NULL | `'active'` | `active`, `inactive` |
| الأعمدة المشتركة | | | | §0.3 |

**القيود:**
- `UNIQUE (platform_tenant_id, group_code)`
- `UNIQUE (id, platform_tenant_id)` — لنمط §0.6
- `CHECK (status IN ('active','inactive'))`
- `CHECK (group_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$')`

**الفهارس:** `(platform_tenant_id)`

---

### 2.3 `schools` — [T]

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `platform_tenant_id` | uuid | NOT NULL | — | FK → `platform_tenants(id)` |
| `group_id` | uuid | NULL | — | مدرسة مستقلة = NULL |
| `school_code` | text | NOT NULL | — | فريد داخل Tenant، ثابت، غير معاد الاستخدام |
| `name` | text | NOT NULL | — | **ليس** فريداً عالمياً |
| `slug` | text | NOT NULL | — | سياق الـsubdomain، فريد داخل Tenant |
| `status` | text | NOT NULL | `'active'` | `active`, `archived` |
| `timezone` | text | NOT NULL | `'Africa/Cairo'` | للعرض والحسابات اليومية |
| `is_standalone` | boolean | GENERATED | `(group_id IS NULL) STORED` | يمنع نطاق هوية لمدرسة داخل Group (§2.16.2) |
| `scope_owner_id` | uuid | GENERATED | `(coalesce(group_id, id)) STORED` | ✅ G3 — مالك نطاق الهوية الذي تنتمي إليه المدرسة |
| `archived_at` | timestamptz | NULL | — | حذف ناعم |
| الأعمدة المشتركة | | | | §0.3 |

**القيود:**
- `UNIQUE (platform_tenant_id, school_code)`
- `UNIQUE (platform_tenant_id, slug)`
- `UNIQUE (id, platform_tenant_id)`
- `FOREIGN KEY (group_id, platform_tenant_id) REFERENCES groups (id, platform_tenant_id)` — **يمنع ربط مدرسة بمجموعة من Tenant آخر** (ERD §5 بند 2)
- `CHECK (status IN ('active','archived'))`
- `CHECK ((status = 'archived') = (archived_at IS NOT NULL))`
- `CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$')`
- `CHECK (school_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$')`
- `UNIQUE (id, is_standalone)` — هدف FK من `identity_scopes`
- ✅ G3: `UNIQUE (id, scope_owner_id)` — هدف FK من `enrollments`
- `group_id` **لا يُعدَّل** من المستخدم؛ انضمام مدرسة مستقلة إلى Group إجراء دمج إداري (`DB_IMPLEMENTATION_SPEC_v1.md` §5.5)

**الفهارس:** `(platform_tenant_id, group_id)` (ERD §8)

> **تذكير:** الـslug يحدد سياق الواجهة فقط ولا يمنح أي صلاحية (`PLAN_v3.md` §3.2).

---

### 2.4 `system_users` — [P]

هوية مشغِّل النظام. **ليست** `profiles` ولا ترتبط بأي Tenant.

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `auth_user_id` | uuid | NOT NULL | — | FK → `auth.users(id)`، UNIQUE |
| `display_name` | text | NOT NULL | — | |
| `status` | text | NOT NULL | `'active'` | `active`, `suspended` |
| `identity_kind` | text | NOT NULL | `'platform'` | G10 — ثابت؛ FK مركّب إلى `auth_identities` |
| `created_at` / `updated_at` | timestamptz | NOT NULL | `now()` | |

> **M05 (2026-09-24): لا `created_by`/`updated_by` في جداول Platform Admin الثلاثة.** الصيغة السابقة ربطتها بـ`system_users(id)`، لكن T6 يكتبها من `app.current_profile_id()` (معرّف profile في Tenant)، والكتابة هنا service role فقط (G8) حيث لا فاعل — فكانت ستبقى فارغة دائماً. الفاعل الموثوق في `audit_log` (T7).

**القيود:** `UNIQUE (auth_user_id)`، `CHECK (status IN ('active','suspended'))`

**قيد معماري:** لا يوجد أي FK بين `system_users` و`profiles` أو `memberships`. أي محاولة لتمثيل Platform Admin كعضو Tenant مخالفة لـ§10 بند 2.

---

### 2.5 `platform_admin_roles` — [P]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `code` | text | NOT NULL | UNIQUE، مثل `platform_admin`, `platform_support` |
| `name` | text | NOT NULL | |
| `description` | text | NULL | |

**بذرة v1:** `platform_admin` (إدارة المنصة والـtenancy). أي دور إضافي يُضاف بقرار موثق.

#### 2.5.1 `platform_admin_role_permissions` — [P] ✅ قرار C3

| العمود | النوع | ملاحظات |
|---|---|---|
| `platform_admin_role_id` | uuid | FK → `platform_admin_roles(id)` ON DELETE CASCADE |
| `permission_id` | uuid | FK → `permissions(id)` ON DELETE RESTRICT |

`PRIMARY KEY (platform_admin_role_id, permission_id)`

**السبب:** بدونه تبقى `app.is_platform_admin()` boolean بلا تفصيل، فينتهي الأمر إما بمنح شامل ضمني — يخالف Matrix §15 بند 6 «Platform Admin has no implicit Tenant data access» — أو بترميز القدرات في كود التطبيق، وهو يخالف «Backend وRLS وDB Constraints هي مصادر الحماية الفعلية». إعادة استخدام كتالوج `permissions` نفسه تجعل قدرات Platform Admin مفصَّلة وقابلة للتدقيق بنفس آلية Tenant.

**البذرة المعتمدة** لدور `platform_admin`: `tenant.read`, `tenant.create`, `tenant.update`, `tenant.suspend`, `group.read`, `group.create`, `school.read`, `school.create`, `audit.read` — **بلا** `student.*` أو `guardian.*` أو `staff.*` أو أي `*.export` لبيانات العملاء (`docs/ROLE_PERMISSION_SEED_v1.md` §6).

> `tenant.create` أُضيف إلى الكتالوج (K4) — 73 مفتاحاً.

---

### 2.6 `platform_admin_assignments` — [P]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `system_user_id` | uuid | NOT NULL | FK → `system_users(id)` |
| `platform_admin_role_id` | uuid | NOT NULL | FK → `platform_admin_roles(id)` |
| `status` | text | NOT NULL | `active`, `revoked` |
| `granted_at` | timestamptz | NOT NULL | `now()` |
| `revoked_at` | timestamptz | NULL | |

**القيود:**
- `UNIQUE (system_user_id, platform_admin_role_id)`
- `CHECK (status IN ('active','revoked'))`
- `CHECK ((status = 'revoked') = (revoked_at IS NOT NULL))`

---

### 2.7 `profiles` — [T]

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `platform_tenant_id` | uuid | NOT NULL | — | FK → `platform_tenants(id)` |
| `auth_user_id` | uuid | NOT NULL | — | FK → `auth.users(id)` |
| `identity_kind` | text | NOT NULL | `'tenant'` | G10 — ثابت؛ `CHECK (identity_kind = 'tenant')` + FK مركّب إلى `auth_identities` |
| `display_name` | text | NOT NULL | — | `CHECK (length(btrim(display_name)) > 0)` |
| `status` | text | NOT NULL | `'active'` | `active`, `suspended`, `disabled` |
| الأعمدة المشتركة | | | | |

**القيود:**
- `UNIQUE (auth_user_id)` — **قرار O1 (2026-09-22): نفس Auth User لا يعبر Tenantين**
- `UNIQUE (platform_tenant_id, auth_user_id)` (ERD §4.5) — يبقى للفهرسة وللتعبير الصريح عن النية
- `UNIQUE (id, platform_tenant_id)`
- `CHECK (status IN ('active','suspended','disabled'))`

**أثر O1 على نموذج التفويض — ملزم:**

`UNIQUE (auth_user_id)` يجعل `app.current_tenant_id()` **دالة حتمية** تُرجع صفاً واحداً دائماً:

```sql
-- لا تحتاج سياقاً خارجياً ولا Tenant claim في الـJWT
SELECT platform_tenant_id FROM profiles WHERE auth_user_id = auth.uid();
```

هذا شرط لصحة الطبقة الموحدة في `CLAUDE.md` §1.1: لو أمكن وجود profileين لنفس الحساب، لأصبحت الدالة غير حتمية ولانهار أساس Tenant Isolation. الشخص العامل في Tenantين يحتاج **حسابي دخول منفصلين** (بريد/هاتف مختلف) — وهذا هو المقصود بـ"لا cross-tenant identity sharing" في `PLAN_v3.md` §10 بند 3.

**الفهارس:** `(platform_tenant_id, auth_user_id)` (ERD §8)

---

### 2.8 `memberships` — [T]

علاقة المستخدم بالـTenant. **لا** تحمل دوراً ولا مدرسة داخل الصف نفسه.

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `platform_tenant_id` | uuid | NOT NULL | — | FK |
| `profile_id` | uuid | NOT NULL | — | FK |
| `status` | text | NOT NULL | `'active'` | `active`, `suspended`, `ended` |
| `ended_at` | timestamptz | NULL | — | |
| الأعمدة المشتركة | | | | |

**القيود:**
- `UNIQUE (platform_tenant_id, profile_id)` (ERD §4.6)
- `UNIQUE (profile_id)` — **Gate B:** الـprofile في Tenant واحد (O1)، فالعلاقة 1:1 صراحةً
- `UNIQUE (id, platform_tenant_id)`
- `FOREIGN KEY (profile_id, platform_tenant_id) REFERENCES profiles (id, platform_tenant_id)`
- `CHECK (status IN ('active','suspended','ended'))`
- `CHECK ((status = 'ended') = (ended_at IS NOT NULL))`

**الفهارس:** `(platform_tenant_id, profile_id)` (ERD §8)

> **تذكير معماري (`CLAUDE.md` §1.1):** هذا الجدول مصدر بيانات للتفويض، وليس نموذج RLS. لا تُكتب policy تستعلم منه مباشرة.

---

### 2.9 `roles` — [T / P]

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `platform_tenant_id` | uuid | NULL | — | NULL = قالب نظام؛ NOT NULL = دور مخصص |
| `code` | text | NOT NULL | — | |
| `name` | text | NOT NULL | — | |
| `description` | text | NULL | — | |
| `is_system` | boolean | NOT NULL | `false` | |
| `status` | text | NOT NULL | `'active'` | `active`, `inactive` |
| الأعمدة المشتركة | | | | |

**القيود:**
- `UNIQUE (code) WHERE platform_tenant_id IS NULL` — فهرس فريد جزئي لأدوار النظام
- `UNIQUE (platform_tenant_id, code) WHERE platform_tenant_id IS NOT NULL` — فريد داخل Tenant (ERD §4.7)
- `UNIQUE (id, platform_tenant_id)`
- `CHECK (is_system = (platform_tenant_id IS NULL))` — دور النظام بلا Tenant والعكس
- **Gate B:** `owner_key uuid GENERATED ALWAYS AS (coalesce(platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)) STORED` + `UNIQUE (id, owner_key)` — هدف FK من `membership_roles` (يحل محل T1)
- `CHECK (status IN ('active','inactive'))`

**أدوار النظام المبذورة (v1)** — اتحاد `PLAN_v3.md` §2 و`AUTHORIZATION_MATRIX_v1.md` §5:

| الكود | المصدر | Scope المعتاد |
|---|---|---|
| `tenant_admin` | Matrix §5 | `tenant` |
| `group_manager` | Matrix §5 (+ `PLAN_v3.md` §7.9) | `group` |
| `school_admin` | كلاهما | `school` |
| `secretary` | PLAN §2 | `school` |
| `accountant` | كلاهما | `school` |
| `teacher` | كلاهما | `school` + تكليف |
| `counselor` | PLAN §2 | `school` |
| `bus_supervisor` | PLAN §2 | `school` |
| `guardian` | كلاهما | عبر `student_guardians` |
| `student` | كلاهما | عبر `enrollments` |

`platform_admin` **ليس** من بينها — فهو في `platform_admin_roles` (`PLAN_v3.md` §10 بند 2). ورود "Platform Admin" في صف واحد مع بقية الأدوار في Matrix §5 عرضٌ مفاهيمي لا يعني اشتراكه في نفس الجدول.

`Scope المعتاد` هنا **وصفي لا إلزامي**: الدور لا يحمل Scope، والـScope يُسنَد إلى العضوية في `membership_scopes` (Matrix §2).

---

### 2.10 `permissions` — [P]

كتالوج عالمي. **المدرسة لا تنشئ Permission؛ تنشئ Role وتربطه بالكتالوج** (ERD §4.8).

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `code` | text | NOT NULL | UNIQUE، بصيغة `resource.operation` |
| `resource` | text | NOT NULL | مثل `student` |
| `operation` | text | NOT NULL | مثل `read` |
| `description` | text | NOT NULL | |
| `is_sensitive` | boolean | NOT NULL DEFAULT false | يُلزم بتسجيل Audit عند الاستخدام |

**القيود:**
- `UNIQUE (code)`
- `CHECK (code = resource || '.' || operation)` — يمنع انحراف الكود عن مكوّناته
- `CHECK (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$')`

**الكتالوج التفصيلي:** مثبَّت في `AUTHORIZATION_MATRIX_v1.md` §4 (البند A2) وليس هنا. القواعد الملزمة: `read` و`export` رمزان منفصلان لكل مورد (Matrix §8)، والإدخال منفصل عن الاعتماد (Matrix §7).

**تحقق توافق:** كل رموز Matrix §4 تجتاز قيد `CHECK (code = resource || '.' || operation)` وصيغة `^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$` — بما فيها المركّبة مثل `student.sensitive_read` و`academic_year.activate` و`grade_level.manage`.

**الكتالوج مجمَّد عند 73 مفتاحاً** بعد قرارات K1–K3 في `docs/ROLE_PERMISSION_SEED_v1.md` §2:
- **K1:** `grade.manage` → `grade_level.manage`؛ البادئة `grade.*` محجوزة للدرجات (المرحلة 6)
- **K2:** إضافة `term.read`, `stage.read`, `grade_level.read`, `section.read`
- **K3:** حذف `tenant.manage`؛ و`tenant.suspend` لا تُمنح لأي دور Tenant

بذر الكتالوج والأدوار وخريطة `role_permissions` في Gate C5 يتبع `docs/ROLE_PERMISSION_SEED_v1.md` §8.1 حرفياً.

---

### 2.11 `role_permissions`

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `role_id` | uuid | NOT NULL | FK → `roles(id)` ON DELETE CASCADE |
| `permission_id` | uuid | NOT NULL | FK → `permissions(id)` ON DELETE RESTRICT |

**القيود:** `PRIMARY KEY (role_id, permission_id)`
**الفهارس:** `(permission_id)` — للاستعلام العكسي

---

### 2.12 `membership_roles`

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `membership_id` | uuid | NOT NULL | FK ON DELETE CASCADE |
| `role_id` | uuid | NOT NULL | FK ON DELETE RESTRICT |
| `platform_tenant_id` | uuid | NOT NULL | **Gate B** — لتفعيل FK المركّب وحل Tenant في التدقيق |
| `role_owner_key` | uuid | NOT NULL | **Gate B** — Tenant الدور أو المفتاح الصفري لدور النظام |
| `granted_at` | timestamptz | NOT NULL DEFAULT `now()` | |
| `granted_by` | uuid | NULL | FK → `profiles(id)` — يكتبه T6 |

**القيود:**
- `PRIMARY KEY (membership_id, role_id)`
- `FOREIGN KEY (membership_id, platform_tenant_id) REFERENCES memberships (id, platform_tenant_id)`
- `FOREIGN KEY (role_id, role_owner_key) REFERENCES roles (id, owner_key)`
- `CHECK (role_owner_key IN (platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid))`

**قيد سلامة Tenant — إعلاني الآن:** الدور إما نظامي أو من Tenant العضوية، ولا ثالث. كان T1 سابقاً لأن `roles.platform_tenant_id` قابل لـNULL؛ المفتاح المشتق `owner_key` يحوّل NULL إلى قيمة ثابتة قابلة للمطابقة. **T1 أُلغي.**

**T8** يفحص INSERT و DELETE (`RLS_MODEL_v1.md` §10.2.1).

---

### 2.13 `membership_scopes`

النطاق منفصل عن الدور. Scope لا يمنح Permission؛ يحدد **أين** تُستعمل (ERD §4.11).

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `membership_id` | uuid | NOT NULL | FK ON DELETE CASCADE |
| `platform_tenant_id` | uuid | NOT NULL | مُكرَّر عمداً لتفعيل FK المركّب |
| `scope_type` | text | NOT NULL | `tenant`, `group`, `school` |
| `group_id` | uuid | NULL | لـgroup scope فقط |
| `school_id` | uuid | NULL | لـschool scope فقط |
| `created_at` | timestamptz | NOT NULL DEFAULT `now()` | |
| `created_by` | uuid | NULL | |

**القيود:**
- `CHECK (scope_type IN ('tenant','group','school'))`
- القيد الحاسم:
```sql
CONSTRAINT membership_scopes_shape_chk CHECK (
  (scope_type = 'tenant' AND group_id IS NULL     AND school_id IS NULL)
  OR
  (scope_type = 'group'  AND group_id IS NOT NULL AND school_id IS NULL)
  OR
  (scope_type = 'school' AND group_id IS NULL     AND school_id IS NOT NULL)
)
```
- `FOREIGN KEY (membership_id, platform_tenant_id) REFERENCES memberships (id, platform_tenant_id)`
- `FOREIGN KEY (group_id, platform_tenant_id) REFERENCES groups (id, platform_tenant_id)`
- `FOREIGN KEY (school_id, platform_tenant_id) REFERENCES schools (id, platform_tenant_id)`
  → الثلاثة معاً يفرضون "الكائن المُشار إليه من نفس Tenant العضوية" (ERD §4.11) **دون trigger**
- `UNIQUE NULLS NOT DISTINCT (membership_id, scope_type, group_id, school_id)` — يمنع تكرار نفس النطاق.
  **تصحيح Gate B:** الصيغة السابقة بلا `NULLS NOT DISTINCT` **لم تكن تمنع شيئاً** لنطاقَي `tenant` و`group` — Postgres يعتبر كل NULL مختلفاً عن غيره، فصفّان `(m, 'tenant', NULL, NULL)` لا يتعارضان. يتطلب PG15+ (🔬 V6)
- عدة صفوف `school` لنفس العضوية مسموحة ومقصودة

**الفهارس:** `(membership_id, scope_type)` (ERD §8)، `(school_id)`, `(group_id)`

---

### 2.14 `staff` — [I]

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | PK |
| `platform_tenant_id` | uuid | NOT NULL | — | FK |
| `profile_id` | uuid | NULL | — | موظف بلا حساب دخول = NULL |
| `employee_code` | text | NOT NULL | — | فريد داخل Tenant (ERD §5 بند 6) |
| قطعة الاسم الرباعي | | | | §0.4 |
| `national_id` | text | NULL | — | |
| `phone_e164` | text | NULL | — | §0.5 |
| `email` | text | NULL | — | |
| `gender` | text | NULL | — | `male`, `female` |
| `birth_date` | date | NULL | — | |
| `hire_date` | date | NULL | — | |
| `status` | text | NOT NULL | `'active'` | `active`, `on_leave`, `ended`, `archived` |
| `archived_at` | timestamptz | NULL | — | حذف ناعم — **لا hard delete** |
| الأعمدة المشتركة | | | | |

**القيود:**
- `UNIQUE (platform_tenant_id, employee_code)`
- `UNIQUE (id, platform_tenant_id)`
- `FOREIGN KEY (profile_id, platform_tenant_id) REFERENCES profiles (id, platform_tenant_id)`
- `UNIQUE (profile_id) WHERE profile_id IS NOT NULL` — حساب واحد لا يمثل موظفَين
- `CHECK (status IN ('active','on_leave','ended','archived'))`
- `CHECK ((status = 'archived') = (archived_at IS NOT NULL))`

**الفهارس:** `(platform_tenant_id, employee_code)` (ERD §8)، `(platform_tenant_id, full_name)`

> **لا `school_id` هنا.** وجود الموظف في Tenant لا يعني رؤيته لكل مدارسه (ERD §4.13).

---

### 2.15 `staff_school_assignments` — [S]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `staff_id` | uuid | NOT NULL | FK |
| `school_id` | uuid | NOT NULL | FK — جدول School-level (§3.3 بند 1) |
| `platform_tenant_id` | uuid | NOT NULL | مُكرَّر لتفعيل FK المركّب |
| `job_title` | text | NOT NULL | |
| `is_primary` | boolean | NOT NULL DEFAULT false | المدرسة الأساسية للموظف |
| `status` | text | NOT NULL | `active`, `ended` |
| `effective_from` | date | NOT NULL | |
| `effective_to` | date | NULL | |
| الأعمدة المشتركة | | | |

**القيود:**
- `FOREIGN KEY (staff_id, platform_tenant_id) REFERENCES staff (id, platform_tenant_id)`
- `FOREIGN KEY (school_id, platform_tenant_id) REFERENCES schools (id, platform_tenant_id)`
- `CHECK (effective_to IS NULL OR effective_to > effective_from)` — فترة نصف مفتوحة (B6)
- `CHECK ((status = 'active') = (effective_to IS NULL))` — B6
- `CHECK (status IN ('active','ended'))`
- `UNIQUE (staff_id, school_id, effective_from)`
- `UNIQUE (staff_id) WHERE is_primary AND status = 'active'` — مدرسة أساسية واحدة نشطة

**الفهارس:** `(school_id, status)`, `(staff_id)`

---

### 2.16 `families` — [I]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `platform_tenant_id` | uuid | NOT NULL | FK |
| `family_code` | text | NULL | اختياري |
| `family_name` | text | NOT NULL | |
| `address` | text | NULL | |
| `status` | text | NOT NULL | `active`, `archived` |
| `archived_at` | timestamptz | NULL | |
| الأعمدة المشتركة | | | |

**القيود:**
- `UNIQUE (platform_tenant_id, family_code) WHERE family_code IS NOT NULL`
- `UNIQUE (id, platform_tenant_id)`
- `CHECK (status IN ('active','archived'))`
- `CHECK ((status = 'archived') = (archived_at IS NOT NULL))` — Gate B

**الإنشاء:** لا مفتاح `family.create` في الكتالوج المجمَّد — تُنشأ فقط داخل دوال الإنشاء (✅ G4، G8).

---

### 2.16.1 `identity_scopes` — [T] 🆕

**قرار A4 (2026-09-22):** نطاق تفرد هوية الطالب كيان صريح، لا فرع `NULL` في `students.group_id`.

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `platform_tenant_id` | uuid | NOT NULL | FK |
| `scope_kind` | text | NOT NULL | `group` \| `school` |
| `group_id` | uuid | NULL | لـ`group` فقط |
| `school_id` | uuid | NULL | لـ`school` فقط (مدرسة مستقلة) |
| `school_is_standalone` | boolean | NOT NULL | ثابت `true` — لنمط §2.16.2 |
| الأعمدة المشتركة | | | §0.3 |

**القيود:**
- `CHECK (scope_kind IN ('group','school'))`
- الشكل:
```sql
CHECK (
     (scope_kind = 'group'  AND group_id IS NOT NULL AND school_id IS NULL)
  OR (scope_kind = 'school' AND school_id IS NOT NULL AND group_id IS NULL)
)
```
- `UNIQUE (group_id) WHERE group_id IS NOT NULL` — نطاق واحد لكل Group
- `UNIQUE (school_id) WHERE school_id IS NOT NULL` — نطاق واحد لكل مدرسة مستقلة
- `UNIQUE (id, platform_tenant_id)`
- `FOREIGN KEY (group_id, platform_tenant_id) REFERENCES groups (id, platform_tenant_id)`
- `FOREIGN KEY (school_id, platform_tenant_id) REFERENCES schools (id, platform_tenant_id)` — **أُضيف في M04 (2026-09-24):** قيد `is_standalone` (§2.16.2) لا يضمن أن المدرسة من Tenant النطاق؛ هذا القيد يطبّق نمط §0.6. مُختبَر بضابط.
- `CHECK (school_is_standalone)` — دائماً true

**الإنشاء التلقائي:** صف نطاق يُنشأ مع كل `group` ومع كل مدرسة `group_id IS NULL` — ✅ **G9: عبر trigger T9**. (كانت هذه الملاحظة تنص سابقاً على «طبقة الأعمال لا trigger»؛ عُكست في Gate B لأن الـinvariant «لكل مجموعة نطاق» يجب ألا يعتمد على مسار الإنشاء.)

✅ G3: `owner_id uuid GENERATED ALWAYS AS (coalesce(group_id, school_id)) STORED` + `UNIQUE (id, owner_id)`.

#### 2.16.2 منع النطاق المزدوج — إنفاذ إعلاني

مدرسة **داخل** Group يجب ألا تملك نطاق هوية خاصاً، وإلا انقسمت الهوية داخل المجموعة. `CHECK` لا يستطيع قراءة `schools.group_id`، فبدل trigger نستعمل عموداً محسوباً + FK مركّب:

```sql
-- على schools
ALTER TABLE schools
  ADD COLUMN is_standalone boolean
    GENERATED ALWAYS AS (group_id IS NULL) STORED;
ALTER TABLE schools ADD CONSTRAINT schools_id_standalone_uq
  UNIQUE (id, is_standalone);

-- على identity_scopes
ALTER TABLE identity_scopes ADD CONSTRAINT identity_scopes_school_standalone_fk
  FOREIGN KEY (school_id, school_is_standalone)
  REFERENCES schools (id, is_standalone);
```

`school_is_standalone` مقيَّد بـ`true`، فالـFK لا يطابق إلا مدرسة `is_standalone = true`. **محاولة إنشاء نطاق لمدرسة داخل Group تفشل من المحرك.**

> **عملية أعمال مؤجلة:** انضمام مدرسة مستقلة إلى Group لاحقاً يوجب دمج نطاق هويتها في نطاق المجموعة وفحص تعارض `official_id`. إجراء إداري في المرحلة 2/13، لا migration.

---

### 2.17 `students` — [I] ⚠️

**الجدول الأكثر حساسية في النموذج.** هوية شخص، وليس سجلاً مدرسياً.

| العمود | النوع | NULL | افتراضي | ملاحظات |
|---|---|---|---|---|
| `id` | uuid | NOT NULL | `gen_random_uuid()` | Student UUID — **ثابت داخل نطاق الهوية** |
| `platform_tenant_id` | uuid | NOT NULL | — | FK |
| `identity_scope_id` | uuid | NOT NULL | — | 🆕 **قرار A4** — FK → `identity_scopes`. **يحل محل `group_id`** |
| `family_id` | uuid | NULL | — | FK |
| `official_id` | text | NULL | — | هوية/جواز — معرف الأعمال عند توفره |
| `official_id_type` | text | NULL | — | `national_id`, `passport` |
| `temporary_id` | text | NULL | — | **يولده النظام حصراً** — لا إدخال يدوي. الصيغة في §2.17.1 |
| `student_profile_id` | uuid | NOT NULL | — | **N1** — حساب الطالب، علاقة 1:1 إلزامية. انظر §2.17.2 |
| قطعة الاسم الرباعي | | | | §0.4 |
| `gender` | text | NULL | — | `male`, `female` — **قرار O2: nullable** |
| `birth_date` | date | NULL | — | **قرار O2: nullable** |
| `nationality` | text | NULL | — | |
| `status` | text | NOT NULL | `'active'` | `active`, `withdrawn`, `archived` |
| `archived_at` | timestamptz | NULL | — | حذف ناعم — **لا hard delete** |
| الأعمدة المشتركة | | | | |

**القيود:**
- `UNIQUE (id, platform_tenant_id)`
- `FOREIGN KEY (identity_scope_id, platform_tenant_id) REFERENCES identity_scopes (id, platform_tenant_id)`
- `FOREIGN KEY (student_profile_id, platform_tenant_id) REFERENCES profiles (id, platform_tenant_id)`
- `UNIQUE (student_profile_id)` — 1:1: حساب واحد لا يمثل طالبَين، وطالب واحد لا يملك حسابين
- `FOREIGN KEY (family_id, platform_tenant_id) REFERENCES families (id, platform_tenant_id)`
- `CHECK (official_id IS NOT NULL OR temporary_id IS NOT NULL)` — لا طالب بلا معرف
- `CHECK ((official_id IS NULL) = (official_id_type IS NULL))`
- `CHECK (gender IS NULL OR gender IN ('male','female'))`
- `CHECK (status IN ('active','withdrawn','archived'))`
- `CHECK ((status = 'archived') = (archived_at IS NOT NULL))`
- **تفرد `official_id` — قيد إعلاني واحد بلا فرع NULL (قرار A4):**
```sql
CREATE UNIQUE INDEX students_scope_official_id_uq
  ON students (identity_scope_id, official_id)
  WHERE official_id IS NOT NULL;
```
يغطي الحالتين معاً: Group، والمدرسة المستقلة. **trigger T2 أُلغي** — لم يعد له موجب.
- `UNIQUE (platform_tenant_id, temporary_id) WHERE temporary_id IS NOT NULL`

**❌ لا يوجد `school_id`** — قاعدة مقفلة (`PLAN_v3.md` §10 بند 5). الوصول يثبت عبر `enrollments`.

**✅ القيد الذي كان يحتاج trigger أصبح إعلانياً.** الصيغة السابقة (التفرد عبر `enrollments` للمدرسة المستقلة) كانت تعبر جدولين، وغير إعلانية، ومعرَّضة لـrace condition، ولا تعمل قبل وجود أول enrollment. `identity_scope_id NOT NULL` يزيل الثلاثة.

**الفهارس:** `(identity_scope_id, official_id)`، `(platform_tenant_id, full_name)`, `(family_id)`, `(student_profile_id)`

**أثر قرار O2 (gender / birth_date قابلان لـNULL):**

- OCR **ليس شرطاً** لإنشاء الطالب، و**ليس مصدراً نهائياً** لبياناته. الحقل الناقص يبقى NULL حتى تُدخله المدرسة أو يُصحَّح.
- لا يوجد أي قيد يمنع إنشاء طالب أو تسجيله بحقول ناقصة. اكتمال البيانات **قاعدة أعمال قابلة للإعداد في المرحلة 4**، لا قيد صف.
- **التزام على كل استعلام لاحق:** أي تقرير أو حساب يعتمد `birth_date` (نطاق العمر في قواعد التوزيع) أو `gender` (سياسة جنس الشعبة) يجب أن يعالج NULL صراحةً — لا يُفترض وجود قيمة. هذا يُفحص في مراجعة المرحلة 4.

#### 2.17.2 `student_profile_id` — حساب الطالب المستقل (N1)

`PLAN_v3.md` §7.19 يقرّ حساب طالب مستقل يدخل بـOfficial/Temporary ID. لكن الجدول كان **بلا أي عمود يربطه بـ`profiles`**، بخلاف `staff.profile_id` و`guardians.profile_id` — فلا يمكن تنفيذ الحساب ولا كتابة `app.student_is_self()` في `RLS_MODEL_v1.md` §8.3.

**القيود:**
- `FOREIGN KEY (student_profile_id, platform_tenant_id) REFERENCES profiles (id, platform_tenant_id)`
- `UNIQUE (student_profile_id)` — حساب واحد لا يمثل طالبَين

**قرار A4: `NOT NULL`** — كل طالب يملك حساباً منذ إنشاء الصف.

**التبعات التشغيلية الملزمة (المرحلة 4):**

| البند | الأثر |
|---|---|
| ترتيب الإنشاء | `auth.users` → `profiles` → `students` في **transaction واحدة** |
| معرّف الدخول | الطالب بلا بريد؛ يلزم معرّف Auth اصطناعي مشتق من Official/Temporary ID (`PLAN_v3.md` §7.19) — يُحسم شكله في Gate F2 |
| مسار القبول | اعتماد طلب الالتحاق يوفّر حساب Auth قبل إنشاء صف الطالب؛ لا يمكن إنشاء طالب "بلا حساب بعد" |

العمود ربط بحساب دخول ولا يُلغي كون `students` جدول هوية.

#### 2.17.1 توليد `temporary_id` — قرار O3

**الصيغة:** `TMP-{YEAR}-{SEQUENCE}` — مثل `TMP-2026-000417`.

| القاعدة | التنفيذ |
|---|---|
| توليد ذري | `nextval()` على sequence أصلي في Postgres — غير تعاملي، بلا أقفال، ولا يتأثر بـrollback |
| عدم إعادة الاستخدام | مضمون من `nextval()`: الأرقام الملغاة بسبب rollback **تُهجر ولا تُعاد**. الفجوات مقبولة ومقصودة |
| لا إدخال يدوي | يُولَّد في DEFAULT/trigger على مستوى قاعدة البيانات، لا من التطبيق |
| `{YEAR}` | سنة الإنشاء الميلادية من `now()` — بادئة عرض فقط، لا تدخل في منطق التفرد |
| التفرد | `UNIQUE (platform_tenant_id, temporary_id)` |

```sql
CREATE SEQUENCE app.temporary_id_seq;

CREATE FUNCTION app.next_temporary_id() RETURNS text
LANGUAGE sql VOLATILE AS $$
  SELECT 'TMP-' || to_char(now(), 'YYYY') || '-'
      || lpad(n::text, greatest(6, length(n::text)), '0')
  FROM (SELECT nextval('app.temporary_id_seq') AS n) s;
$$;
```

> **🔴 تصحيح (M02، 2026-09-24):** الصيغة الأولى `lpad(nextval(...), 6, '0')` **تقطع** الأرقام الأطول من 6 خانات: `lpad('1000000', 6) = '100000'` — أي أن الطالب رقم 1,000,000 يأخذ معرّف الطالب رقم 100,000، وهذا يكسر شرط «بلا إعادة استخدام» في O3. الصيغة أعلاه تحافظ على الأصفار البادئة ولا تقطع. مُختبَر في `supabase/tests/02_app_trigger_functions.test.sql`.

```sql
```

**ملاحظة تنفيذية (تُراجع في Gate C7):** الـsequence **مشترك بين الـTenants** ولا يُصفَّر مع تغير السنة. البديلان — تسلسل مستقل لكل Tenant أو تصفير سنوي — يتطلبان إما DDL ديناميكياً (sequence لكل Tenant/سنة) أو جدول عدّادات مع `UPDATE ... RETURNING`، وهذا الأخير **تعاملي** أي يُعيد الرقم عند rollback ويخالف شرط "عدم إعادة الاستخدام". لذلك اختير الـsequence الأصلي المشترك: الرقم معرف داخلي مؤقت لا دلالة إحصائية له، والفجوات فيه غير ضارة.

---

### 2.18 `guardians` — [I]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `platform_tenant_id` | uuid | NOT NULL | FK |
| `profile_id` | uuid | NULL | يُنشأ تلقائياً عند اعتماد أول ابن أو يدوياً |
| قطعة الاسم الرباعي | | | §0.4 |
| `phone_e164` | text | NOT NULL | **فريد داخل Tenant** (ERD §5 بند 15) |
| `alt_phone_e164` | text | NULL | |
| `email` | text | NULL | |
| `national_id` | text | NULL | |
| `residence_country` | text | NULL | قد يكون مقيماً خارج مصر |
| `status` | text | NOT NULL | `active`, `archived` |
| `locked_until` | timestamptz | NULL | القفل المؤقت بعد محاولات دخول فاشلة (§7.8) |
| `failed_login_count` | integer | NOT NULL DEFAULT 0 | |
| `last_login_at` | timestamptz | NULL | يظهر لولي الأمر ضمن معلومات الأمان |
| `archived_at` | timestamptz | NULL | حذف ناعم |
| الأعمدة المشتركة | | | |

**القيود:**
- `UNIQUE (platform_tenant_id, phone_e164)`
- `UNIQUE (id, platform_tenant_id)`
- `FOREIGN KEY (profile_id, platform_tenant_id) REFERENCES profiles (id, platform_tenant_id)`
- `UNIQUE (profile_id) WHERE profile_id IS NOT NULL`
- `CHECK` صيغة E.164 على الحقلين
- `CHECK (failed_login_count >= 0)`
- `CHECK (status IN ('active','archived'))`
- `CHECK ((status = 'archived') = (archived_at IS NOT NULL))` — Gate B

---

### 2.19 `student_guardians`

Many-to-Many. كل أولياء الأمور المرتبطين بالطالب لهم **نفس** صلاحيات رؤية بياناته (`PLAN_v3.md` §7.8).

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `student_id` | uuid | NOT NULL | FK |
| `guardian_id` | uuid | NOT NULL | FK |
| `platform_tenant_id` | uuid | NOT NULL | مُكرَّر لتفعيل FK المركّب |
| `relationship_type` | text | NOT NULL | `father`, `mother`, `grandparent`, `sibling`, `legal_guardian`, `other` |
| `is_primary` | boolean | NOT NULL DEFAULT false | |
| `receives_whatsapp` | boolean | NOT NULL DEFAULT true | |
| `can_pickup` | boolean | NOT NULL DEFAULT false | |
| `status` | text | NOT NULL | `active`, `ended` |
| `effective_from` | date | NOT NULL DEFAULT `current_date` | |
| `effective_to` | date | NULL | |
| الأعمدة المشتركة | | | |

**القيود:**
- `UNIQUE (student_id, guardian_id)`
- `FOREIGN KEY (student_id, platform_tenant_id) REFERENCES students (id, platform_tenant_id)`
- `FOREIGN KEY (guardian_id, platform_tenant_id) REFERENCES guardians (id, platform_tenant_id)`
  → معاً يفرضان "الطالب وولي الأمر داخل نفس Tenant" (ERD §4.18) **دون trigger**
- `UNIQUE (student_id) WHERE is_primary AND status = 'active'` — ولي أمر أساسي واحد
- `CHECK (relationship_type IN (...))`, `CHECK (status IN ('active','ended'))`
- `CHECK (effective_to IS NULL OR effective_to > effective_from)`, `CHECK ((status = 'active') = (effective_to IS NULL))` — B6

**الفهارس:** `(guardian_id, student_id)` (ERD §8)، `(student_id)`

---

### 2.20 `enrollments` — [S] ⚠️

الجسر بين هوية الطالب والمدرسة. **مصدر حقيقة RLS للوصول إلى الطالب.**

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `school_id` | uuid | NOT NULL | FK |
| `student_id` | uuid | NOT NULL | FK |
| `platform_tenant_id` | uuid | NOT NULL | مُكرَّر لتفعيل FK المركّب |
| `academic_year_id` | uuid | NOT NULL | FK |
| `grade_level_id` | uuid | NOT NULL | FK |
| `section_id` | uuid | NOT NULL | FK |
| `enrollment_no` | text | NULL | رقم قيد اختياري داخل المدرسة |
| `status` | text | NOT NULL | `active`, `withdrawn`, `transferred`, `completed` |
| `effective_from` | date | NOT NULL | |
| `effective_to` | date | NULL | |
| `withdrawal_reason` | text | NULL | |
| الأعمدة المشتركة | | | |

**القيود:**
- `FOREIGN KEY (student_id, platform_tenant_id) REFERENCES students (id, platform_tenant_id)`
- `FOREIGN KEY (school_id, platform_tenant_id) REFERENCES schools (id, platform_tenant_id)`
- `FOREIGN KEY (section_id, school_id, academic_year_id, grade_level_id) REFERENCES sections (id, school_id, academic_year_id, grade_level_id)`
  → **FK واحد** يفرض أن السنة والصف والشعبة من نفس المدرسة **ومتسقة فيما بينها** (ERD §5 بند 14). الشعبة مرتبطة بالسنة والصف بـFKs مركّبة، فالاتساق متعدٍّ. **يحل محل T3 وثلاثة FKs سابقة.**
- ✅ G3: أعمدة `identity_scope_id`, `scope_owner_id` + `FOREIGN KEY (student_id, identity_scope_id) REFERENCES students (id, identity_scope_id)` + `FOREIGN KEY (school_id, scope_owner_id) REFERENCES schools (id, scope_owner_id)` + `FOREIGN KEY (identity_scope_id, scope_owner_id) REFERENCES identity_scopes (id, owner_id)` — المدرسة داخل نطاق هوية الطالب
- **Enrollment نشط واحد** (ERD §5 بند 11):
```sql
CREATE UNIQUE INDEX enrollments_active_uq
  ON enrollments (student_id, school_id, academic_year_id)
  WHERE status = 'active';
```

> **ملاحظة (M10، 2026-09-24): I38 محتوى بالكامل في G6.** التسجيل النشط فترته `[from, ∞)`، فأي تسجيلين نشطين للطالب نفسه يتداخلان دائماً، فيرفضهما `enrollments_no_overlap` أولاً. القيد باقٍ (المواصفة + فهرس بحث مفيد)، لكن لا حالة تخرقه وحده، فلا يُختبر باسمه منفرداً.
- `CHECK (status IN ('active','withdrawn','transferred','completed'))`
- `CHECK (effective_to IS NULL OR effective_to > effective_from)` — فترة نصف مفتوحة (B6)
- `CHECK ((status = 'active') = (effective_to IS NULL))` — B6
- ✅ G6: `EXCLUDE USING gist (student_id WITH =, daterange(effective_from, effective_to, '[)') WITH &&)` — لا تداخل زمني عبر الـTenant
- `UNIQUE (school_id, academic_year_id, enrollment_no) WHERE enrollment_no IS NOT NULL`

**✅ T3 أُلغي في Gate B** — القيد إعلاني عبر FK الشعبة المركّب أعلاه.

**الفهارس:** `(school_id, academic_year_id, student_id)`, `(school_id, academic_year_id, section_id)` (ERD §8)، `(student_id)` — حرج لسياسات RLS على `students`

> الانتقال بين الشعب **لا يمحو** السجل القديم؛ يُغلق بـ`effective_to` ويُنشأ سجل جديد (ERD §4.16).

---

### 2.21 `academic_years` — [S]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `school_id` | uuid | NOT NULL | FK |
| `name` | text | NOT NULL | مثل `2026/2027` |
| `start_date` | date | NOT NULL | |
| `end_date` | date | NOT NULL | |
| `status` | text | NOT NULL | `planned`, `active`, `closed` |
| الأعمدة المشتركة | | | |

**القيود:**
- `UNIQUE (id, school_id)` — لنمط FK المركّب
- `UNIQUE (id, school_id, start_date, end_date)` — **Gate B:** هدف FK من `terms`
- `UNIQUE (school_id, name)`
- `CHECK (end_date > start_date)`
- `CHECK (status IN ('planned','active','closed'))`
- **سنة نشطة واحدة لكل مدرسة** (ERD §5 بند 12):
```sql
CREATE UNIQUE INDEX academic_years_active_uq
  ON academic_years (school_id) WHERE status = 'active';
```
- **منع التداخل الزمني** عبر `EXCLUDE` (أنظف من trigger):
```sql
ALTER TABLE academic_years ADD CONSTRAINT academic_years_no_overlap
  EXCLUDE USING gist (
    school_id WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  );
```
يتطلب `CREATE EXTENSION btree_gist`.

**الفهارس:** `(school_id, status)` (ERD §8)

---

### 2.22 `terms` — [S عبر السنة]

عدد الفصول **قابل للإعداد** — ممنوع افتراض فصلين (`PLAN_v3.md` §3.3 / ERD §9).

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `academic_year_id` | uuid | NOT NULL | FK |
| `school_id` | uuid | NOT NULL | مُكرَّر لتفعيل FK المركّب |
| `name` | text | NOT NULL | |
| `sequence_no` | integer | NOT NULL | |
| `start_date` | date | NOT NULL | |
| `end_date` | date | NOT NULL | |
| `year_start_date` | date | NOT NULL | **Gate B** — نسخة من حدود السنة يُزامنها FK |
| `year_end_date` | date | NOT NULL | **Gate B** |
| `status` | text | NOT NULL | `planned`, `active`, `closed` |

**القيود:**
- `FOREIGN KEY (academic_year_id, school_id, year_start_date, year_end_date) REFERENCES academic_years (id, school_id, start_date, end_date) ON UPDATE CASCADE`
- `CHECK (start_date >= year_start_date AND end_date <= year_end_date)` — **الفصل داخل السنة**
- `UNIQUE (academic_year_id, sequence_no)`, `UNIQUE (academic_year_id, name)`
- `CHECK (sequence_no > 0)`, `CHECK (end_date > start_date)`
- `EXCLUDE USING gist (academic_year_id WITH =, daterange(start_date, end_date, '[]') WITH &&)` — لا تداخل بين فصول السنة

**✅ T4 أُلغي في Gate B:** الـFK يحمل تاريخي السنة ويُحدَّث بـ`ON UPDATE CASCADE`، فيُعاد تقييم الـCHECK عند تعديل السنة — ويُرفض التعديل إن أخرج فصلاً عن حدودها (🔬 V3).

---

### 2.23 `stages` — [S]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `school_id` | uuid | NOT NULL | FK |
| `name` | text | NOT NULL | مثل رياض الأطفال، الابتدائية |
| `sequence_no` | integer | NOT NULL | |
| `status` | text | NOT NULL | `active`, `inactive` |

**القيود:** `UNIQUE (id, school_id)`, `UNIQUE (school_id, name)`, `UNIQUE (school_id, sequence_no)`, `CHECK (sequence_no > 0)`

---

### 2.24 `grade_levels` — [S]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `school_id` | uuid | NOT NULL | FK |
| `stage_id` | uuid | NOT NULL | FK |
| `name` | text | NOT NULL | KG1، KG2، الصف الأول … |
| `sequence_no` | integer | NOT NULL | |
| `status` | text | NOT NULL | `active`, `inactive` |

**القيود:**
- `UNIQUE (id, school_id)`
- `FOREIGN KEY (stage_id, school_id) REFERENCES stages (id, school_id)`
- `UNIQUE (school_id, name)`, `UNIQUE (school_id, sequence_no)`

---

### 2.25 `sections` — [S]

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK |
| `school_id` | uuid | NOT NULL | FK |
| `academic_year_id` | uuid | NOT NULL | FK — الشعبة خاصة بسنة |
| `grade_level_id` | uuid | NOT NULL | FK |
| `name` | text | NOT NULL | **ليس فريداً عالمياً** (ERD §4.19) |
| `capacity` | integer | NULL | NULL = بلا حد |
| `gender_policy` | text | NOT NULL DEFAULT `'mixed'` | `mixed`, `male_only`, `female_only` |
| `status` | text | NOT NULL | `active`, `inactive` |

**القيود:**
- `UNIQUE (id, school_id)`
- `UNIQUE (id, school_id, academic_year_id, grade_level_id)` — **Gate B:** هدف FK من `enrollments`
- `FOREIGN KEY (academic_year_id, school_id) REFERENCES academic_years (id, school_id)`
- `FOREIGN KEY (grade_level_id, school_id) REFERENCES grade_levels (id, school_id)`
- `UNIQUE (school_id, academic_year_id, grade_level_id, name)` — نطاق التفرد الصحيح
- `CHECK (capacity IS NULL OR capacity > 0)`
- `CHECK (gender_policy IN ('mixed','male_only','female_only'))`

> السعة وسياسة الجنس **لا** تُفرضان هنا؛ تُفرضان عند التسجيل في المرحلة 4 لأنهما قاعدتا أعمال لا قيد صف.

---

### 2.26 `audit_log` — [A]

**لا يجوز للتطبيق حذف أو تعديل أي صف** (ERD §4.20).

| العمود | النوع | NULL | ملاحظات |
|---|---|---|---|
| `id` | bigint | NOT NULL | `GENERATED ALWAYS AS IDENTITY` — ترتيب زمني طبيعي وحجم أصغر |
| `platform_tenant_id` | uuid | NULL | NULL لأحداث المنصة الصرفة |
| `school_id` | uuid | NULL | حسب ملكية الكيان |
| `actor_type` | text | NOT NULL | `tenant_user`, `platform_admin`, `system` |
| `actor_id` | uuid | NULL | `profiles.id` أو `system_users.id` حسب النوع |
| `action` | text | NOT NULL | `insert`, `update`, `delete`, `archive`, `approve`, `export`, `login`, … |
| `entity_type` | text | NOT NULL | اسم الجدول |
| `entity_id` | text | NOT NULL | نص لاستيعاب المفاتيح غير uuid |
| `old_values` | jsonb | NULL | |
| `new_values` | jsonb | NULL | |
| `reason` | text | NULL | إلزامي تطبيقياً لبعض العمليات |
| `source` | text | NOT NULL | `web`, `mobile`, `api`, `system` |
| `ip_address` | inet | NULL | |
| `created_at` | timestamptz | NOT NULL DEFAULT `now()` | |

**القيود:**
- `CHECK (actor_type IN ('tenant_user','platform_admin','system'))`
- `CHECK (source IN ('web','mobile','api','system'))`
- `CHECK (actor_type = 'system' OR actor_id IS NOT NULL)`
- **بلا FK على `actor_id` و`entity_id`** — عمداً: سجل التدقيق يجب أن يبقى صالحاً حتى لو أُرشف الكيان، وFK هنا يخلق تبعية عكسية خطرة.

**الحماية من التعديل:**
```sql
REVOKE UPDATE, DELETE, TRUNCATE ON audit_log FROM authenticated, anon, service_role;
CREATE TRIGGER audit_log_immutable
  BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION app.tg_reject_mutation();
CREATE TRIGGER audit_log_no_truncate
  BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION app.tg_reject_mutation();
```
الطبقتان معاً: صلاحيات + trigger. الأولى وحدها لا تمنع مالك الجدول. **و`TRUNCATE` يحتاج trigger على مستوى الجملة** — trigger الصف لا يعمل عنده، و`service_role` في Supabase يملك `TRUNCATE` (M02، 2026-09-24).

**الفهارس:** `(platform_tenant_id, created_at DESC)`, `(entity_type, entity_id)` (ERD §8)، `(actor_id, created_at DESC)`

---

## 3. ملخص الفهارس (ERD §8)

| الجدول | الفهرس | الغرض |
|---|---|---|
| `schools` | `(platform_tenant_id, group_id)` | تصفية النطاق |
| `profiles` | `(platform_tenant_id, auth_user_id)` | حل الهوية عند كل طلب |
| `memberships` | `(platform_tenant_id, profile_id)` | حل التفويض |
| `membership_scopes` | `(membership_id, scope_type)` | `app.can_access_*()` |
| `membership_scopes` | `(school_id)`, `(group_id)` | الاتجاه العكسي |
| `staff` | `(platform_tenant_id, employee_code)` | |
| `students` | `(identity_scope_id, official_id)` | كشف التكرار (قرار A4) |
| `students` | `(student_profile_id)` | مسار `app.student_is_self()` |
| `enrollments` | `(school_id, academic_year_id, student_id)` | |
| `enrollments` | `(school_id, academic_year_id, section_id)` | كشوف الشعبة |
| `enrollments` | `(student_id)` | **حرج** — سياسة RLS على `students` |
| `student_guardians` | `(guardian_id, student_id)` | مسار ولي الأمر |
| `academic_years` | `(school_id, status)` | |
| `audit_log` | `(platform_tenant_id, created_at DESC)`, `(entity_type, entity_id)` | |

**قاعدة:** كل FK له فهرس. لا فهارس إضافية بلا قياس أداء فعلي بعد Foundation (ERD §8).

---

## 4. القيود التي تحتاج Trigger

القاعدة المتبعة: **كل قيد يمكن التعبير عنه بـFK مركّب أو `CHECK` أو `EXCLUDE` أو فهرس فريد جزئي — يُنفَّذ كذلك.** ما تبقى فقط يصبح trigger. القائمة التالية هي الحد الأدنى الذي لا يمكن تجنبه:

| # | القيد | السبب |
|---|---|---|
| ~~**T1**~~ | ~~الدور من نفس Tenant العضوية~~ | **أُلغي في Gate B** — `roles.owner_key` + FK مركّب |
| ~~**T2**~~ | ~~تفرد `official_id` للطالب بلا Group~~ | **أُلغي بقرار A4** — أصبح قيداً إعلانياً عبر `identity_scope_id` |
| ~~**T3**~~ | ~~اتساق الشعبة مع التسجيل~~ | **أُلغي في Gate B** — FK مركّب إلى `sections` |
| ~~**T4**~~ | ~~الفصل داخل السنة~~ | **أُلغي في Gate B** — FK مركّب بتواريخ + `ON UPDATE CASCADE` + CHECK |
| **T5** | `audit_log`: رفض UPDATE/DELETE | حماية مطلقة |
| **T6** | ختم `created_by`/`updated_at`/`updated_by` | عام؛ يتجاهل قيم العميل فيمنع تزوير النسب (Gate B) |
| **T7** | تسجيل التغييرات الحساسة في `audit_log` | trigger عام معمم (Gate C9) |
| **T8** | `membership_roles` و`role_permissions` (INSERT و DELETE): الصلاحيات ⊆ صلاحيات الفاعل | يعتمد على هوية الفاعل. **Gate B (F5):** كان على `membership_roles` فقط، فيُلتف عليه بإسناد دور فارغ ثم ملئه — `RLS_MODEL_v1.md` §10.2.1 |
| **T9** | إنشاء `identity_scopes` تلقائياً للمجموعة وللمدرسة المستقلة | ✅ G9 — وجود صف تابع إلزامي |

**القائمة النهائية بعد Gate B: T5، T6، T7، T8، T9** — خمسة فقط. كل trigger يحتاج اختبار pgTAP. التصنيف الكامل لكل invariant وآليته: `DB_IMPLEMENTATION_SPEC_v1.md` §3.

---

## 5. القرارات المحسومة — 2026-09-22

| # | البند | القرار | الموضع |
|---|---|---|---|
| **O1** | نطاق تفرد `profiles.auth_user_id` | **`UNIQUE (auth_user_id)` عالمياً** — نفس Auth User لا يعبر Tenantين. الشخص العامل في Tenantين يحتاج حسابي دخول منفصلين | §2.7 |
| **O2** | `students.gender` و`birth_date` | **قابلان لـNULL.** OCR ليس شرطاً لإنشاء الطالب ولا مصدراً نهائياً لبياناته؛ اكتمال البيانات قاعدة أعمال في المرحلة 4 لا قيد صف | §2.17 |
| **O3** | توليد `temporary_id` | **`TMP-{YEAR}-{SEQUENCE}`** بتوليد ذري عبر `nextval()` وبلا إعادة استخدام؛ الفجوات مقبولة | §2.17.1 |

**سلسلة الأثر لقرار O1** — وهو الأثقل لأنه يمس نموذج التفويض كله:

```text
UNIQUE (auth_user_id)
   ↓
Profile واحد لكل Auth User
   ↓
app.current_tenant_id() حتمية (صف واحد دائماً)
   ↓
Tenant Isolation مضمون من الجذر
   ↓
app.can_access_*() + app.has_permission() تبني عليه
```

لا يوجد بند معلّق. **Gate C مفتوح من ناحية Data Dictionary.**

---

## 6. ما تم استبعاده عمداً من Foundation

- `subjects`, `grade_subjects`, `bell_schedules`, `periods`, `holidays` — المرحلة 2
- `teaching_assignments`, `class_teacher_assignments`, `staff_specialties` — المرحلة 3 (لكن `teaching_assignments` يؤثر على سياسة RLS للمعلم في ERD §7.5 → تُكتب السياسة بشكل يستوعبه لاحقاً دون تعديل الجداول)
- `student_documents`, `student_notes`, `section_transfers`, `student_transfers` — المرحلة 4
- كل جداول Attendance / Assessment / Finance / Communication / Timetable

---

## 7. حالة الاعتماد

| البند | الحالة |
|---|---|
| تغطية الجداول | ✅ **29/29** — 28 من ERD §4 + `auth_identities` (G10) |
| إعلان مستوى الملكية لكل جدول (§3.3 بند 14) | ✅ |
| `school_id NOT NULL` على كل School-level (§3.3 بند 1) | ✅ |
| لا `school_id` على `students` (§10 بند 5) | ✅ |
| تغطية قيود ERD §5 (1–15) | ✅ عدا المؤجلة للـtriggers §4 |
| قرارات معلّقة | ✅ لا يوجد — O1–O3 محسومة (§5) |

**مُطابَق في Gate B (2026-09-23).** المواصفة التنفيذية: `docs/DB_IMPLEMENTATION_SPEC_v1.md`.
