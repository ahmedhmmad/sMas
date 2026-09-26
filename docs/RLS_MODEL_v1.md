# RLS Model v1 — Foundation

**التاريخ:** 2026-09-22
**الحالة:** A3 — مُصحَّح في Gate B (2026-09-23): F1–F6، F10، F11. انظر `DB_IMPLEMENTATION_SPEC_v1.md` §4.4
**المرجع:** `CLAUDE.md` §1.1 (الصياغة الملزمة) + `AUTHORIZATION_MATRIX_v1.md` §11–§12 + `docs/ROLE_PERMISSION_SEED_v1.md` (73 مفتاحاً مجمَّداً) + `docs/DATA_DICTIONARY_v1.md`

> هذا الملف مواصفة تُترجم حرفياً إلى migrations في Gates D و E. أي سياسة لا ترد هنا لا تُكتب.

---

## 0. الطبقات بالترتيب

```text
auth.uid()   (عبر app.auth_uid() داخل الدوال — §4.5)
   ↓
Profile / Platform Admin Identity
   ↓
Tenant Resolution
   ↓
Role → Permission
   ↓
Scope
   ↓
Business Relationship
   ↓
RLS Policy
```

**القاعدة الحاكمة:** RLS **ليست** `school_id IN (...)`.

| نوع الجدول | قرار الوصول |
|---|---|
| School-level | Tenant isolation **AND** Scope **AND** Permission |
| Identity (`students`, `guardians`, `staff`) | Tenant isolation **AND** Permission **AND** **علاقة تشغيلية** تثبت الوصول |

وضع `school_id` على `students` كان سيجعل الحالة الثانية تبدو كالأولى — وهو بالضبط ما نقضه القرار المقفل في `PLAN_v3.md` §10 بند 5: **الطالب هوية مستقلة عن `enrollment` وعن المدرسة**.

---

## 1. Identity & Tenant Resolution

### 1.1 هوية مستخدم Tenant

```sql
create or replace function app.current_profile_id()
returns uuid
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select p.id
  from public.profiles p
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active';
$$;

create or replace function app.current_tenant_id()
returns uuid
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select p.platform_tenant_id
  from public.profiles p
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active';
$$;
```

> **✅ M21b (2026-09-25):** الدالتان تشترطان أيضاً `platform_tenants.status = 'active'` (join) — الـTenant الموقوف يفقد كل مسار Tenant. يجب أن تكون الاثنتان: `has_permission`/`can_access_*` تقرأ `current_profile_id`.

**حتمية الدالتين مضمونة بقرار O1** (`UNIQUE (profiles.auth_user_id)`). بدونه تعيد الدالة أكثر من صف ويفشل الاستعلام أو يعيد قيمة عشوائية — ولهذا رُفع O1 إلى شرط جذر في `CLAUDE.md` §1.1.

`status = 'active'` جزء من الشرط: تعليق الـprofile يُسقط الوصول فوراً دون حذف بيانات.

### 1.2 هوية Platform Admin

```sql
create or replace function app.current_system_user_id()
returns uuid
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select su.id
  from public.system_users su
  where su.auth_user_id = app.auth_uid()
    and su.status = 'active';
$$;

create or replace function app.is_platform_admin()
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select app.current_security_context() = 'platform'
     and exists (
       select 1
       from public.platform_admin_assignments paa
       join public.system_users su on su.id = paa.system_user_id
       where su.auth_user_id = app.auth_uid()
         and su.status = 'active'
         and paa.status = 'active'
     );
$$;
```

**`is_platform_admin()` اختبار هوية فقط ولا يمنح أي صلاحية** (قرار C3). لا تُستعمل وحدها في أي `USING` أو `WITH CHECK`؛ تُستعمل دائماً مقترنة بـ`has_permission()`.

### 1.3 حصرية المسارين

المستخدم إما profile في Tenant أو system_user — لا الاثنان. **مفروض إعلانياً بقرار G10:** جدول `auth_identities (auth_user_id PK, kind)` + FK مركّب `(auth_user_id, 'tenant')` من `profiles` و`(auth_user_id, 'platform')` من `system_users`. الحساب الذي يحتاج الدورين (مثل مشغّل المنصة ومدير مدرسة التجربة) يستعمل **حسابي دخول منفصلين** — وهو امتداد مباشر لـO1.

---

## 2. Permission Resolution — سياقان منفصلان (G10، 2026-09-23)

**القرار المعتمد:** لا دالة عامة تجمع المسارين بـ`OR`. يُحدَّد **السياق الأمني** أولاً، ثم تُقيَّم الصلاحية داخل ذلك السياق وحده.

```text
Tenant request   → Tenant roles / scopes / permissions   → app.has_permission()
Platform request → Platform roles / permissions          → app.has_platform_permission()
```

> **مُستبدَل:** الصيغة الأولى لهذا القسم (قرار C3، 2026-09-22) عرّفت `has_permission()` واحدة توحّد المسارين بـ`OR`. تلك الصيغة كانت تسمح لحساب يجمع الهويتين بأن يستعمل صلاحية Tenant لتلبية شرط سياسة Platform Admin.

### 2.1 السياق الأمني

```sql
-- 'tenant' | 'platform' | NULL — من auth_identities.kind، حصري بحكم المفتاح الأساسي (G10)
create or replace function app.current_security_context()
returns text
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select ai.kind from public.auth_identities ai where ai.auth_user_id = app.auth_uid();
$$;
```

`auth_identities.auth_user_id` مفتاح أساسي، فلكل حساب **سياق واحد بالضبط** أو لا شيء. الحصرية مفروضة إعلانياً من المحرك (G10) — لا يمكن أن يحمل حساب واحد السياقين.

### 2.2 صلاحية سياق Tenant

```sql
create or replace function app.has_permission(p_code text)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select app.current_security_context() = 'tenant'
     and exists (
       select 1
       from public.memberships m
       join public.membership_roles mr on mr.membership_id = m.id
       join public.roles r              on r.id = mr.role_id
       join public.role_permissions rp  on rp.role_id = mr.role_id
       join public.permissions perm     on perm.id = rp.permission_id
       where m.profile_id = app.current_profile_id()
         and m.status = 'active'
         and r.status  = 'active'
         and perm.code = p_code
     );
$$;
```

الاسم `has_permission` باقٍ كما في عقد Matrix §12 لأن كل سياسات Tenant تستعمله، لكن **معناه الآن سياق Tenant حصراً**.

### 2.3 صلاحية سياق Platform

```sql
create or replace function app.has_platform_permission(p_code text)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select app.current_security_context() = 'platform'
     and exists (
       select 1
       from public.platform_admin_assignments paa
       join public.platform_admin_role_permissions parp
            on parp.platform_admin_role_id = paa.platform_admin_role_id
       join public.permissions perm on perm.id = parp.permission_id
       where paa.system_user_id = app.current_system_user_id()
         and paa.status = 'active'
         and perm.code = p_code
     );
$$;
```

### 2.4 قواعد ملزمة

- **سياسات Tenant** تستعمل `has_permission()` فقط. **سياسات Platform** تستعمل `has_platform_permission()` فقط. لا سياسة تستعمل الاثنتين بـ`OR`.
- **دفاع بطبقتين:** حتى لو فشلت حصرية G10 لسبب ما، كل دالة تتحقق من السياق أولاً، فلا تُرضي صلاحية Tenant سياسة Platform أبداً.
- الدالة تجيب عن **«هل يملك هذه الصلاحية؟»** فقط، لا عن **«أين؟»** — ذلك عمل `can_access_*`.
- الدور المعطَّل (`roles.status <> 'active'`) يُسقط صلاحياته فوراً.
- `T8` يقيس صلاحيات الفاعل بـ`has_permission()` — سياق Tenant. سياق service (`app.auth_uid() IS NULL`) مُعفى (✅ G7).

---

## 3. Scope Resolution

```sql
create or replace function app.can_access_tenant(p_tenant_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select p_tenant_id is not null
     and p_tenant_id = app.current_tenant_id()
     and exists (
       select 1
       from public.memberships m
       join public.membership_scopes ms on ms.membership_id = m.id
       where m.profile_id = app.current_profile_id()
         and m.platform_tenant_id = p_tenant_id
         and m.status = 'active'
         and ms.scope_type = 'tenant'          -- ← تصحيح F1 (Gate B)
     );
$$;
```

> **🔴 تصحيح F1 — Gate B (2026-09-23):** النسخة الأولى من هذه الدالة كانت تُرجع true لأي **عضو نشط** في الـTenant، لا لمن **يملك نطاق Tenant**. بما أن `school_admin` يملك `scope.assign`، كان يستطيع عبر فرع `scope_type='tenant'` في سياسة `membership_scopes` (§10.2) أن يمنح **نفسه** نطاق Tenant كاملاً؛ و`group_manager` كان يستطيع إنشاء مدرسة في أي مجموعة عبر فرع `OR can_access_tenant` في سياسة `schools` (§7).
>
> **دلالتان منفصلتان لا يجوز خلطهما:**
>
> | الحاجة | التعبير |
> |---|---|
> | عزل Tenant المجرد — «هل هذا الصف في Tenant الخاص بي؟» | `platform_tenant_id = (select app.current_tenant_id())` |
> | نطاق Tenant — «هل أملك سلطة على الـTenant كله؟» | `app.can_access_tenant(platform_tenant_id)` |
>
> هذا مطابق لـ`AUTHORIZATION_MATRIX_v1.md` §11: `tenant_match AND scope_match` حيث `tenant_scope` أحد فروع `scope_match`.

```sql
create or replace function app.can_access_group(p_group_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.memberships m
    join public.membership_scopes ms on ms.membership_id = m.id
    join public.groups g on g.id = p_group_id
    where m.profile_id = app.current_profile_id()
      and m.status = 'active'
      and g.platform_tenant_id = m.platform_tenant_id   -- عزل Tenant داخل الدالة
      and (
            ms.scope_type = 'tenant'
         or (ms.scope_type = 'group' and ms.group_id = g.id)
      )
  );
$$;
```

```sql
create or replace function app.can_access_school(p_school_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.memberships m
    join public.membership_scopes ms on ms.membership_id = m.id
    join public.schools s on s.id = p_school_id
    where m.profile_id = app.current_profile_id()
      and m.status = 'active'
      and s.platform_tenant_id = m.platform_tenant_id   -- عزل Tenant داخل الدالة
      and (
            ms.scope_type = 'tenant'
         or (ms.scope_type = 'group'  and ms.group_id = s.group_id and s.group_id is not null)
         or (ms.scope_type = 'school' and ms.school_id = s.id)
      )
  );
$$;
```

**ثلاث نقاط حرجة:**

1. **عزل Tenant داخل الدالة نفسها** (`s.platform_tenant_id = m.platform_tenant_id`). لا يُترك للسياسة وحدها — دفاع بطبقتين.
2. **`group` scope لا يطابق مدرسة مستقلة.** شرط `s.group_id is not null` يمنع حالة `NULL = NULL` من التسبب بمطابقة عرضية.
3. **Platform Admin تُرجع له الثلاث `false`** — ليس له `memberships`. نطاقه platform-level ويُعالَج بسياسات منفصلة (§11)، تطبيقاً لقرار C3.

### 3.1 `app.user_school_ids()` — تحسين أداء فقط

```sql
-- يُستدعى من التطبيق للقوائم، لا من داخل أي policy
create or replace function app.user_school_ids() returns setof uuid ...
```

**ممنوع استعمالها في `USING`/`WITH CHECK`** (`CLAUDE.md` §1.1 بند 6).

---

## 4. منع الـRecursion — التعارض الحقيقي وحلّه ⚠️

هذه أخطر نقطة في A3، وفيها تعارض مباشر مع Gate D2.

### 4.1 المشكلة

سياسة `profiles` ستستدعي `app.current_profile_id()`، وهي تقرأ من `profiles` → تقييم السياسة يستدعي السياسة → **recursion**.

الحل المعتاد `SECURITY DEFINER` يعمل لأن **RLS لا تُطبَّق على مالك الجدول**. لكن Gate D2 ينص على `ENABLE + FORCE ROW LEVEL SECURITY`، و**`FORCE` يطبّق السياسات على المالك أيضاً** — فينهار الحل وتعود الـrecursion.

### 4.2 القرار

| الفئة | القاعدة |
|---|---|
| السلوك | `FORCE RLS` يستثني فقط الأدوار ذات صفة `BYPASSRLS` (والـsuperuser)، ولا يستثني المالك |
| الحل | دوال §1–§3 تُملَّك للدور المخصص **`app_owner`** (`NOLOGIN`, `BYPASSRLS`)، فتتجاوز RLS حتى مع `FORCE` — **R2، مُثبت في M00 V2 (17/17)** |
| الهوية | `app_owner` لا يصل إلى schema `auth`، فكل دالة يملكها تقرأ الفاعل عبر **`app.auth_uid()`** لا `auth.uid()` مباشرة — §4.5 |
| التحقق | **إلزامي**: اختبار pgTAP يثبت أن الدوال تعمل بعد تفعيل `FORCE` على `profiles` و`memberships` |
| دفاع ثانٍ | سياسة `profiles` للصف الذاتي تُكتب بـ`auth_user_id = auth.uid()` **مباشرة بلا أي helper** — فلا تعتمد على تجاوز RLS أصلاً |

### 4.5 `app.auth_uid()` — سلسلة الهوية (R2، 2026-09-23)

```text
SECURITY DEFINER app functions
        ↓
app_owner (NOLOGIN, BYPASSRLS)
        ↓
app.auth_uid()      ← يملكها postgres
        ↓
auth.uid()
        ↓
real caller identity
```

```sql
create function app.auth_uid() returns uuid
language sql stable security definer set search_path = ''
as $$ select auth.uid() $$;
revoke execute on function app.auth_uid() from public, anon, authenticated;
grant  execute on function app.auth_uid() to app_owner;
```

**استثناء R2 — قائمة مغلقة مسمّاة (M25، 2026-09-26):** `app.auth_uid()` + `app.auth_user_updated_at(uid)` + `app.auth_password_changed_by_self_after(uid, ts)` — ملك `postgres`، `search_path` فارغ، EXECUTE لـ`app_owner` وحده، تعيد لحظة/قيمة منطقية لا صفاً؛ لأن `app_owner` لا يصل إلى schema `auth` و`postgres` لا يملك grant option عليه. أي إضافة للقائمة قرار جديد

**قاعدة الاستعمال — أين `app.auth_uid()` وأين `auth.uid()`:**

| الموضع | يُنفَّذ بدور | يستعمل |
|---|---|---|
| جسم دالة `SECURITY DEFINER` يملكها `app_owner` (مساعدة، متحكَّم بها، T8) | `app_owner` | **`app.auth_uid()`** |
| تعبير سياسة RLS (`USING` / `WITH CHECK`) | المستدعي | `auth.uid()` |

الخلط في الاتجاه الأول يفشل صراحةً (`permission denied for schema auth`)؛ الخلط في الاتجاه الثاني يفشل صراحةً أيضاً (`authenticated` لا يملك `EXECUTE` على الوسيط). لا يوجد خلط صامت.

**لماذا لا يصبح الوسيط قناة التفاف — مُثبت في M00 V2:**

| الخاصية | الدليل |
|---|---|
| لا يستدعيه `anon` ولا `authenticated` | `permission denied for function auth_uid` |
| بلا معاملات، `search_path` فارغ، `auth.uid()` مؤهَّل | لا مدخل يؤثر في ما يُرجعه |
| يُرجع هوية المستدعي فقط، و`NULL` في سياق service | لا يكشف شيئاً لا يملكه المستدعي أصلاً عبر `auth.uid()` |
| `app_owner` لا يستطيع استبداله ولا حذفه | `must be owner of function` — لأن الوسيط ملك `postgres` **والـschema `app` ملك `postgres`** |

**قاعدة الإنشاء:** كل دالة `SECURITY DEFINER` في `app` تُنشأ تحت `set local role app_owner` — فتولد ملكاً له، ولا `EXECUTE` لأحد بحكم `ALTER DEFAULT PRIVILEGES FOR ROLE app_owner` (M01). الاستثناء الوحيد: `app.auth_uid()` نفسها تُنشأ بهوية `postgres`.

**لماذا schema `app` ملك `postgres` لا `app_owner`:** مالك الـschema يستطيع حذف أي كائن داخله ولو لم يملكه — كان `app_owner` سيستطيع حذف الوسيط وإعادة إنشائه ليُرجع هوية مزوَّرة. `app_owner` يُمنح `USAGE, CREATE` فقط: `CREATE` تكفي لنقل ملكية الدوال إليه، ولا تسمح بحذف ما يملكه غيره.

### 4.3 الجداول التي تقرأها الدوال

`auth_identities`, `profiles`, `memberships`, `membership_roles`, `membership_scopes`, `roles`, `role_permissions`, `permissions`, `system_users`, `platform_admin_assignments`, `platform_admin_role_permissions`, `schools`, `groups`.

**قاعدة:** أي سياسة على هذه الجداول لا يجوز أن تستدعي دالة تقرأ الجدول نفسه، إلا عبر مسار BYPASSRLS مُتحقَّق منه.

### 4.4 الأداء

كل الدوال `STABLE`، فتُقيَّم مرة لكل جملة لا لكل صف. في السياسات تُلفّ في `(select ...)` لإجبار Postgres على `InitPlan`:

```sql
using (platform_tenant_id = (select app.current_tenant_id()))
```

الفرق بين الصيغتين على جدول بعشرات الآلاف من الصفوف فرق رتبة، لا تحسيناً هامشياً.

---

## 5. `USING` مقابل `WITH CHECK`

| العملية | `USING` | `WITH CHECK` |
|---|---|---|
| `SELECT` | ✅ | — |
| `INSERT` | — | ✅ |
| `UPDATE` | ✅ الصف **قبل** التعديل | ✅ الصف **بعد** التعديل |
| `DELETE` | ✅ | — |

### 5.1 الفخ الذي يجب ألا يقع فيه أحد

سياسة `UPDATE` بـ`USING` فقط تسمح للمستخدم بـ**نقل الصف خارج نطاقه**:

```sql
-- ثغرة: مصرح له بمدرسة A، فيعدّل school_id إلى B
update enrollments set school_id = '<school B>' where id = '<row in A>';
```

`USING` تنجح (الصف في A)، ولا شيء يفحص النتيجة. **لذلك كل سياسة `UPDATE` في هذا الملف تحمل `WITH CHECK` تفحص الحالة الجديدة، بلا استثناء.**

### 5.2 المنع الافتراضي

`ENABLE ROW LEVEL SECURITY` بلا سياسة = **منع كامل**. نعتمد ذلك عمداً:

- **لا توجد سياسة `DELETE` على جداول Foundation** — تطبيق لقاعدة "لا hard delete" (`PLAN_v3.md` §3.3 بند 7 و17). الأرشفة عبر دوال انتقال الحالة.
- **استثناء Gate B (✅ G2):** `membership_roles`, `membership_scopes`, `role_permissions` (أدوار مخصصة) — بدونه **لا يمكن سحب دور أو نطاق** عبر النظام. التاريخ محفوظ في `audit_log` عبر T7، وT8 يفحص السحب كما يفحص المنح.
- `audit_log` بلا سياسة `INSERT` للمستخدمين — الكتابة عبر trigger `SECURITY DEFINER` فقط.

---

## 6. النماذج الثلاثة للسياسات

### 6.1 Tenant-level

```sql
-- SELECT
using (
      app.can_access_tenant(platform_tenant_id)
  and app.has_permission('<resource>.read')
)

-- INSERT
with check (
      app.can_access_tenant(platform_tenant_id)
  and app.has_permission('<resource>.create')
)

-- UPDATE
using (
      app.can_access_tenant(platform_tenant_id)
  and app.has_permission('<resource>.update')
)
with check (
      app.can_access_tenant(platform_tenant_id)   -- يمنع نقل الصف إلى Tenant آخر
  and app.has_permission('<resource>.update')
)
```

### 6.2 Group-level

نفس النمط بـ`app.can_access_group(group_id)`.

### 6.3 School-level

```sql
using (
      app.can_access_school(school_id)
  and app.has_permission('<resource>.read')
)
```

`can_access_school` تتحقق من Tenant داخلياً (§3)، فلا حاجة لشرط Tenant إضافي — لكن الجداول التي تحمل `platform_tenant_id` مكرراً تُضيفه كطبقة ثانية.

---

## 7. سياسات الكيانات — Tenant / Group / School

| الجدول | SELECT | INSERT | UPDATE |
|---|---|---|---|
| `platform_tenants` | `can_access_tenant(id) AND has_permission('tenant.read')` | Platform Admin فقط (§11) | `can_access_tenant(id) AND has_permission('tenant.update')` |
| `groups` | `can_access_group(id) AND has_permission('group.read')` | `can_access_tenant(platform_tenant_id) AND has_permission('group.create')` | `can_access_group(id) AND has_permission('group.update')` + WITH CHECK مطابق |
| `schools` | `can_access_school(id) AND has_permission('school.read')` | `(can_access_group(group_id) OR can_access_tenant(platform_tenant_id)) AND has_permission('school.create')` | `can_access_school(id) AND has_permission('school.update')` + WITH CHECK مطابق |
| `stages`, `grade_levels`, `sections` | `can_access_school(school_id) AND has_permission('<res>.read')` | `… AND has_permission('<res>.manage')` | نفسه + WITH CHECK |
| `academic_years` (✅ M16: مفاتيح الكتالوج) | `… AND has_permission('academic_year.read')` | `… AND has_permission('academic_year.create')` | `… AND has_permission('academic_year.update')` + WITH CHECK؛ activate/close بدوال M21 |
| `terms` | `can_access_school(school_id) AND has_permission('term.read')` | `… AND has_permission('term.manage')` | نفسه + WITH CHECK |
| `staff_school_assignments` | `can_access_school(school_id) AND has_permission('staff.read')` | `… AND has_permission('staff.assign')` | نفسه + WITH CHECK |

**✅ تعديل معتمد (M14، 2026-09-25) — `WITH CHECK` في UPDATE لـ`groups` و`schools`:** يضاف `platform_tenant_id = (select app.current_tenant_id())` على قيم الصف الجديد. السبب مُثبت تجريبياً: `can_access_group(id)`/`can_access_school(id)` تقرأ الجدول بلقطة الجملة فترى Tenant الصف **القديم**؛ بالنص الأصلي تجاوزت RLS نقل مجموعة/مدرسة إلى Tenant آخر، ولم يوقفه إلا FK `identity_scopes`. العزل يُفرض في RLS نفسها لا بالاعتماد على قيد آخر.

**ملاحظة على `schools` INSERT:** الشرط يقبل مسارين — `group_manager` داخل مجموعته، و`tenant_admin` على مستوى Tenant (`PLAN_v3.md` §7.9). `WITH CHECK` يمنع إنشاء مدرسة في Group من Tenant آخر، ويدعمه FK المركّب في قاعدة البيانات.

**الأرشفة** `UPDATE` بصلاحية `<res>.archive` لا `.update` — تُفصل بسياسة مستقلة أو بفحص في طبقة الأعمال، **وقرار الفصل مؤجل إلى Gate D3** لأن RLS لا تميز الأعمدة المتغيرة. الفصل الحقيقي يتم بـ`GRANT UPDATE (column list)` أو trigger.

---

## 8. `students` — السياسة الأهم ⚠️

`students` بلا `school_id`. الوصول يثبت بعلاقة، وله **ثلاثة مسارات منفصلة**.

### 8.1 دالة العلاقة التشغيلية

```sql
-- H2 (M12b): المدرسة التشغيلية الحالية = مدرسة أحدث تسجيل، أياً كانت حالته، حتى يظهر أحدث منه
create or replace function app.student_in_scope(p_student_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from (select e.school_id
          from public.enrollments e
          where e.student_id = p_student_id
          order by e.effective_from desc
          limit 1) cur
    where app.can_access_school(cur.school_id)
  );
$$;
```

> **✅ H2 (2026-09-25، M12b) — النص أعلاه نهائي؛ حلّ محل «أي enrollment» (M12):** A school is operationally in scope for a student only through the student's current/authorized enrollment in that school. Historical enrollments provide historical access only where a specific permission/policy explicitly permits historical records; they do not grant operational access to the student's current account or guardian account.
>
> **أحدث تسجيل** بـ`effective_from` — فريد لكل طالب بحكم G6. الحالة **لا** تحدد المدرسة الحالية: `completed` في نهاية السنة و`withdrawn` بالخطأ لا يسحبان الوصول؛ يسحبه فقط تسجيل أحدث في مدرسة أخرى. المدرسة السابقة ترى سجلات `enrollments` و`audit_log` الخاصة بها (بنطاق المدرسة)، لا صف هوية الطالب — عرض الهوية التاريخية مؤجل للمرحلة 4.

`SECURITY DEFINER` هنا ضروري: بدونه تُطبَّق RLS الخاصة بـ`enrollments` داخل الاستعلام الفرعي، فيصبح التقييم متداخلاً ومكلفاً، وقد تختلف النتيجة عن المقصود.

### 8.2 مسار ولي الأمر

```sql
create or replace function app.student_linked_to_guardian(p_student_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.student_guardians sg
    join public.guardians g on g.id = sg.guardian_id
    where sg.student_id = p_student_id
      and sg.status = 'active'
      and g.profile_id = app.current_profile_id()
      and g.status = 'active'
  );
$$;
```

### 8.3 مسار الطالب نفسه

```sql
create or replace function app.student_is_self(p_student_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.students s
    join public.profiles p on p.id = app.current_profile_id()
    where s.id = p_student_id
      and s.student_profile_id = p.id
  );
$$;
```

### 8.4 السياسة

```sql
-- SELECT
using (
  platform_tenant_id = (select app.current_tenant_id())
  and app.has_permission('student.read')
  and (
        app.student_in_scope(id)                -- موظف ضمن نطاق مدرسة للطالب
     or app.student_linked_to_guardian(id)      -- ولي أمر مرتبط
     or app.student_is_self(id)                 -- الطالب نفسه
  )
)

-- INSERT
with check (
  platform_tenant_id = (select app.current_tenant_id())
  and app.has_permission('student.create')
)

-- UPDATE
using (
  platform_tenant_id = (select app.current_tenant_id())
  and app.has_permission('student.update')
  and app.student_in_scope(id)
)
with check (
  platform_tenant_id = (select app.current_tenant_id())   -- يمنع نقل الطالب إلى Tenant آخر
  and app.has_permission('student.update')
)
```

> **Gate B (✅ G4):** إن اعتُمد G4 لا يُمنح `authenticated` صلاحية INSERT على `students`، وتنتقل الفحوص أدناه (`student.create` + `can_access_identity_scope`) إلى رأس `app.provision_student()`. السياسة تبقى موثقة كمرجع للفحوص المطلوبة.

**لماذا `INSERT` بلا شرط علاقة:** الطالب الجديد بلا `enrollment` بعد، فـ`student_in_scope` ستُرجع false دائماً وتمنع كل إنشاء. الحماية هنا = Tenant + `student.create`، والربط بالمدرسة يقع عند `enrollments`.

**⚠️ ثغرة `INSERT` وسدّها (قرار A4):** الشرط أعلاه يسمح لمن يملك `student.create` بإنشاء طالب في **أي نطاق هوية داخل Tenant**، حتى نطاق مجموعة لا يملك عليها صلاحية. يُضاف إلى `WITH CHECK`:

```sql
and exists (
  select 1 from identity_scopes isc
  where isc.id = identity_scope_id
    and (
          (isc.scope_kind = 'group'  and app.can_access_group(isc.group_id))
       or (isc.scope_kind = 'school' and app.can_access_school(isc.school_id))
    )
)
```

يُغلَّف في `app.can_access_identity_scope(uuid)` بنفس نمط دوال §3، ويُستعمل في `INSERT` و`UPDATE WITH CHECK` معاً.

> **✅ H1 (2026-09-24) يحلّ محل هذا الفحص في الإنشاء:** `provision_student` لا تقبل `identity_scope_id` من العميل؛ تشتقه من المدرسة الهدف وتفحص `student.create` + `enrollment.create` + `can_access_school(target_school)`. الثغرة التي سُدّت أعلاه تبقى مسدودة لأن النطاق لم يعد مُدخلاً، و**G3** يرفض أي نطاق ≠ مالك مدرسة التسجيل. سبب التغيير: الفحص أعلاه كان يمنع سكرتير مدرسة ضمن مجموعة من التسجيل إلا بمنحه نطاق المجموعة — خرقاً لأقل صلاحية. `can_access_identity_scope` باقية لسياسة قراءة `identity_scopes` (§10.6).

### 8.5 ✅ `students.student_profile_id` — مغلق بقرار A4

أُضيف بـ`NOT NULL UNIQUE` + FK مركّب `(student_profile_id, platform_tenant_id) → profiles (id, platform_tenant_id)`، فعلاقة الطالب بحسابه 1:1 إلزامية و`app.student_is_self()` قابلة للكتابة كما في §8.3.

**أثر `NOT NULL` على السياسات:** لا فرع `NULL` في `student_is_self` — كل طالب له حساب، فالدالة تُرجع نتيجة حتمية دائماً.

### 8.6 ما تمنعه هذه السياسة صراحةً

| المحاولة | النتيجة |
|---|---|
| موظف يقرأ طالباً بلا enrollment في مدارسه | ❌ |
| ولي أمر يقرأ طالباً آخر في نفس مدرسة ابنه | ❌ |
| طالب يقرأ زميله | ❌ |
| مستخدم Tenant آخر يقرأ الطالب | ❌ (شرط Tenant) |
| موظف بلا `student.read` ولو كان نطاقه صحيحاً | ❌ |
| نقل الطالب إلى Tenant آخر بـUPDATE | ❌ (`WITH CHECK`) |

---

## 9. `enrollments`

جدول School-level، لكنه **جسر الوصول إلى الهوية** فيستحق حذراً إضافياً.

```sql
-- SELECT
using (
      app.can_access_school(school_id)
  and app.has_permission('enrollment.read')
  or (
      -- مسار ولي الأمر والطالب
      app.has_permission('enrollment.read')
      and (app.student_linked_to_guardian(student_id) or app.student_is_self(student_id))
  )
)

-- INSERT
with check (
      app.can_access_school(school_id)
  and app.has_permission('enrollment.create')
)

-- UPDATE
using (
      app.can_access_school(school_id)
  and app.has_permission('enrollment.update')
)
with check (
      app.can_access_school(school_id)     -- ⚠️ يمنع نقل التسجيل إلى مدرسة خارج النطاق
  and app.has_permission('enrollment.update')
)
```

> **✅ M17 (2026-09-25، H2):** enrollments INSERT و UPDATE تشترطان أيضاً `app.student_in_scope(student_id)`. تحت H2 التسجيل الأحدث يحدد المدرسة التشغيلية، وبالنص أعلاه وحده تستطيع مدرسة أخرى في نطاق الهوية إدراج تسجيل لاحق فتنتزع الطالب دون موافقة مدرسته، وتستطيع المدرسة السابقة تعديل صفها التاريخي — مُثبت بضابط سلبي في `17_relationship`. النقل بين المدارس: دالة M21؛ التسجيل الأول: `provision_student` (M22). SELECT بلا تغيير.

**`WITH CHECK` هنا ليست شكلية:** بدونها يستطيع `school_admin` في المدرسة A تعديل `school_id` إلى المدرسة B ونقل الطالب إلى مدرسة لا يملك عليها أي صلاحية. هذا مثال §5.1 بالضبط.

**النقل بين المدارس** لا يتم بـ`UPDATE school_id`؛ يتم بإغلاق `effective_to` وإنشاء سجل جديد بصلاحية `enrollment.transfer` وبموافقة المدرستين (`PLAN_v3.md` §7.10) — منطق أعمال في طبقة مستقلة لا في RLS.

---

## 10. `profiles` و`memberships` و`membership_*`

### 10.0 دوال الرؤية والإدارة للعضويات — Gate B (F2–F4)

```sql
-- هل يستطيع الفاعل رؤية عضوية (وبالتالي profile صاحبها)؟
create or replace function app.can_see_membership(p_membership_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.memberships m
    where m.id = p_membership_id
      and m.platform_tenant_id = app.current_tenant_id()
      and (
            -- نطاق للعضوية الهدف يقع ضمن نطاق الفاعل
            exists (
              select 1 from public.membership_scopes ms
              where ms.membership_id = m.id
                and (   (ms.scope_type = 'tenant' and app.can_access_tenant(ms.platform_tenant_id))
                     or (ms.scope_type = 'group'  and app.can_access_group(ms.group_id))
                     or (ms.scope_type = 'school' and app.can_access_school(ms.school_id)))
            )
            -- أو صاحبها هوية مرتبطة بعلاقة ضمن نطاق الفاعل
         or exists (select 1 from public.students s  where s.student_profile_id = m.profile_id and app.student_in_scope(s.id))
         or exists (select 1 from public.guardians g where g.profile_id = m.profile_id and app.guardian_in_scope(g.id))
         or exists (select 1 from public.staff st    where st.profile_id = m.profile_id and app.staff_in_scope(st.id))
      )
  );
$$;

-- هل يملك الفاعل سلطة على العضوية كلها؟ (منح/سحب أدوار، إنهاء، تعديل profile)
create or replace function app.can_manage_membership(p_membership_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.memberships m
    where m.id = p_membership_id
      and m.platform_tenant_id = app.current_tenant_id()
      and m.profile_id <> app.current_profile_id()          -- لا إدارة ذاتية
      -- كل نطاقات الهدف ⊆ نطاقات الفاعل
      and not exists (
        select 1 from public.membership_scopes ms
        where ms.membership_id = m.id
          and not (   (ms.scope_type = 'tenant' and app.can_access_tenant(ms.platform_tenant_id))
                   or (ms.scope_type = 'group'  and app.can_access_group(ms.group_id))
                   or (ms.scope_type = 'school' and app.can_access_school(ms.school_id)))
      )
      -- عضوية بلا نطاقات (ولي أمر/طالب): تُدار بالعلاقة أو بنطاق tenant
      and (
            exists (select 1 from public.membership_scopes ms where ms.membership_id = m.id)
         or app.can_access_tenant(m.platform_tenant_id)
         or exists (select 1 from public.students s  where s.student_profile_id = m.profile_id and app.student_in_scope(s.id))
         or exists (select 1 from public.guardians g where g.profile_id = m.profile_id and app.guardian_in_scope(g.id))
      )
  );
$$;
```

**لماذا «كل» لا «أي» في الإدارة:** `can_see` = تقاطع (أرى زميلي في مدرستي). `can_manage` = احتواء: `school_admin` في A لا يُدير عضوية نطاقها A و B معاً، لأن منحه دوراً عليها يسري في B أيضاً.

**`m.profile_id <> current_profile_id()`:** لا يُسند الفاعل لنفسه دوراً ولا يسحب من نفسه. يغلق مسار «إسناد دور فارغ للذات ثم ملؤه» (F5) من جهة ثانية.

### 10.1 `profiles` — مصحّح (F2)

> **✅ M15 (2026-09-25):** الاستعلام الفرعي `(select m.id from public.memberships m where m.profile_id = …)` أدناه استُبدل بـ`app.membership_id_of(…)` (SECURITY DEFINER، داخل Tenant الفاعل فقط). النص الحرفي يخالف §1.1 بند 6 ويمر بـRLS العضويات، فيُحجب profile عن من يملك `profile.read` بلا `membership.read` (المعلم) — مُثبت بضابط سلبي في `15_escalation`. وكذلك فرع الذات في `membership_roles`/`membership_scopes`.

```sql
-- SELECT
using (
      auth_user_id = auth.uid()                                   -- الذات، بلا صلاحية ولا helper (§4.2)
   or (    platform_tenant_id = (select app.current_tenant_id())
       and app.has_permission('profile.read')
       and app.can_see_membership(
             (select m.id from public.memberships m where m.profile_id = profiles.id)))
)

-- UPDATE — لا مسار ذاتي (✅ G1)
using (
      platform_tenant_id = (select app.current_tenant_id())
  and app.has_permission('profile.update')
  and app.can_manage_membership(
        (select m.id from public.memberships m where m.profile_id = profiles.id))
)
with check (platform_tenant_id = (select app.current_tenant_id()))
```

**الثغرة المصحَّحة:** كانت الرؤية Tenant + `profile.read` — وكل الأدوار العشرة تملكها، فولي الأمر كان يقرأ كل profiles الـTenant.

**INSERT:** لا سياسة — دوال الإنشاء فقط (`DB_IMPLEMENTATION_SPEC_v1.md` §5.2).
**أعمدة UPDATE:** `display_name` فقط.

### 10.2 `memberships` و`membership_roles` و`membership_scopes` — مصحّح (F3–F5)

```sql
-- memberships SELECT
using (
      profile_id = (select app.current_profile_id())
   or (app.has_permission('membership.read') and app.can_see_membership(id))
)
-- memberships INSERT / UPDATE: لا سياسة — دوال الإنشاء و app.end_membership

-- membership_roles SELECT
using (
      membership_id = (select m.id from public.memberships m where m.profile_id = app.current_profile_id())
   or (app.has_permission('membership.read') and app.can_see_membership(membership_id))
)

-- membership_roles INSERT  (F4) + T8
with check (
      app.has_permission('role.assign')
  and app.can_manage_membership(membership_id)
)

-- membership_roles DELETE  (✅ G2) + T8
using (
      app.has_permission('role.assign')
  and app.can_manage_membership(membership_id)
)

-- membership_scopes SELECT: مطابق لـmembership_roles

-- ✅ M15 (2026-09-25): INSERT و DELETE يشترطان أيضاً app.can_manage_membership(membership_id) — كـmembership_roles (F4).
--    بدونه: school_admin في SA1 يمنح SA1 لعضوية لا يديرها (محاسب SB1) فتسري صلاحيات أدوارها في SA1 — مُثبت بضابط سلبي.
-- membership_scopes INSERT — النطاق الممنوح ⊆ نطاق الفاعل
with check (
      app.has_permission('scope.assign')
  and platform_tenant_id = (select app.current_tenant_id())
  and (   (scope_type = 'tenant' and app.can_access_tenant(platform_tenant_id))   -- بعد F1: يلزم نطاق tenant
       or (scope_type = 'group'  and app.can_access_group(group_id))
       or (scope_type = 'school' and app.can_access_school(school_id)))
)

-- membership_scopes DELETE (✅ G2) — لا تسحب إلا نطاقاً تملكه
using (
      app.has_permission('scope.assign')
  and (   (scope_type = 'tenant' and app.can_access_tenant(platform_tenant_id))
       or (scope_type = 'group'  and app.can_access_group(group_id))
       or (scope_type = 'school' and app.can_access_school(school_id)))
)
```

**F4:** قبل التصحيح كان `school_admin` في A يسند `school_admin` لعضوية نطاقها B — يصعّد **غيره** إلى مدرسة لا سلطة له عليها. T8 لا يلتقطها لأن الصلاحيات ⊆ صلاحياته. `can_manage_membership` تسدّها.

**F1 هنا:** فرع `tenant` كان يقبل أي عضو؛ بعد تصحيح `can_access_tenant` لا يمنح نطاق tenant إلا من يملكه.

### 10.2.1 Trigger T8 — المواصفة الكاملة (F5)

> **✅ M22 (2026-09-26):** إعفاء ضيق إضافي لـ`bootstrap_tenant`: سياق المنصة + `has_platform_permission('tenant.create')`، على INSERT في `membership_roles`/`membership_scopes` فقط.
>
> **✅ M19 (2026-09-25):** نُفّذ `app.tg_authz_integrity()` كـtrigger **AFTER** (لا BEFORE: BEFORE يسبق `WITH CHECK` فيحجب رفض RLS برسالة T8)، بالمتطلبات الثلاثة المعتمدة — الثالث: `membership_scopes` INSERT يرفض إن كانت أي صلاحية في أدوار الهدف (فعّالة أو معطّلة) خارج `has_permission()` للفاعل. الرفض `42501` برسالة `T8: …` تسمّي الصلاحيات. سحب النطاق غير مفحوص بـT8 (لا يوسّع سلطة).

| الحدث | الجدول | الشرط |
|---|---|---|
| INSERT, DELETE | `membership_roles` | `perms(role_id) ⊆ perms(actor)` |
| INSERT, DELETE | `role_permissions` (دور مخصص) | `permission_id ∈ perms(actor)` |
| UPDATE | الجدولان | ممنوع — لا GRANT UPDATE |

```sql
-- perms(actor): اتحاد صلاحيات الفاعل الفعّالة عبر has_permission
-- الإعفاء: app.auth_uid() IS NULL — سياق service (✅ G7)
if app.auth_uid() is not null and exists (
     select 1 from role_permissions rp join permissions p on p.id = rp.permission_id
     where rp.role_id = NEW.role_id and not app.has_permission(p.code))
then raise exception 'T8: role grants permissions the actor does not hold';
end if;
```

**F5 — مسار الالتفاف الذي كان مفتوحاً:** T8 على `membership_roles` وحده يسمح بـ: (1) إسناد دور مخصص **فارغ** للذات — يجتاز T8؛ (2) إضافة صلاحيات لا يملكها الفاعل إلى ذلك الدور عبر `role_permissions` — بلا فحص. تغطية `role_permissions` + منع الإدارة الذاتية في `can_manage_membership` يغلقانه من جهتين. Matrix §13 نص عليه صراحةً: «تعديل Role مخصص لا يسمح بإضافة Permission أعلى من صلاحيات المانح».

### 10.3 `roles` و`permissions` و`role_permissions`

| الجدول | SELECT |
|---|---|
| `permissions` | `has_permission('permission.read')` — كتالوج عالمي بلا Tenant |
| `roles` | `(platform_tenant_id IS NULL OR platform_tenant_id = current_tenant_id()) AND has_permission('role.read')` |
| `role_permissions` | يتبع رؤية `roles` |

`roles` INSERT/UPDATE: `platform_tenant_id = current_tenant_id() AND has_permission('role.create'/'role.update')` — و`WITH CHECK` يمنع تعديل أدوار النظام (`platform_tenant_id IS NULL`) وهو ما يفرضه أيضاً قيد `CHECK (is_system = (platform_tenant_id IS NULL))`.

---

**تصحيح Gate B على كتابة الأدوار:** `roles` INSERT/UPDATE و`role_permissions` INSERT/DELETE تشترط أيضاً `app.can_access_tenant(platform_tenant_id)` — الأدوار المخصصة Tenant-level، ودور مخصص يمنح `role.update` لمستخدم بنطاق مدرسة يجب ألا يجعله يعدّل أدوار الـTenant كله.

### 10.4 دوال العلاقة لجداول الهوية — Gate B (F6)

```sql
-- موظف مرئي: له تكليف نشط في مدرسة ضمن النطاق (H2، M12b)
create or replace function app.staff_in_scope(p_staff_id uuid) returns boolean
language sql stable security definer set search_path = app, public, pg_temp as $$
  select exists (select 1 from public.staff_school_assignments a
                 where a.staff_id = p_staff_id and a.status = 'active' and app.can_access_school(a.school_id));
$$;

-- ولي أمر مرئي: ارتباط نشط بطالب ضمن النطاق الحالي (H2، M12b)
create or replace function app.guardian_in_scope(p_guardian_id uuid) returns boolean
language sql stable security definer set search_path = app, public, pg_temp as $$
  select exists (select 1 from public.student_guardians sg
                 where sg.guardian_id = p_guardian_id and sg.status = 'active' and app.student_in_scope(sg.student_id));
$$;

-- أسرة مرئية: فيها طالب ضمن النطاق
create or replace function app.family_in_scope(p_family_id uuid) returns boolean
language sql stable security definer set search_path = app, public, pg_temp as $$
  select exists (select 1 from public.students s
                 where s.family_id = p_family_id and app.student_in_scope(s.id));
$$;

-- نطاق هوية يمكن الإنشاء فيه
create or replace function app.can_access_identity_scope(p_scope_id uuid) returns boolean
language sql stable security definer set search_path = app, public, pg_temp as $$
  select exists (select 1 from public.identity_scopes i
                 where i.id = p_scope_id
                   and (   (i.scope_kind = 'group'  and app.can_access_group(i.group_id))
                        or (i.scope_kind = 'school' and app.can_access_school(i.school_id))));
$$;

-- هوية الفاعل كولي أمر
create or replace function app.current_guardian_id() returns uuid
language sql stable security definer set search_path = app, public, pg_temp as $$
  select g.id from public.guardians g where g.profile_id = app.current_profile_id() and g.status = 'active';
$$;
```

**✅ H2 (2026-09-25، M12b) — الفقرة التالية مُلغاة (superseded):** الطالب ← أحدث تسجيل؛ ولي الأمر ← ارتباط نشط + الطالب في النطاق الحالي؛ الموظف ← تكليف نشط. `family_in_scope` و`can_see/can_manage_membership` ترث الدلالة لأنها تستدعي هذه الدوال.

~~**التكليفات والارتباطات المنتهية تُحسب في الرؤية:** مثل `student_in_scope` التي تقبل أي enrollment. المدرسة ترى تاريخ من عمل أو درس فيها — هذا مطابق لقاعدة «المدرسة القديمة لا تعدل التاريخ الأصلي» (`PLAN_v3.md` §7.10): الرؤية باقية، والتعديل محكوم بصلاحيات منفصلة.~~

### 10.5 سياسات جداول الهوية — Gate B (F6)

**INSERT على الأربعة الأولى: لا سياسة** — تُنشأ بدوال `DB_IMPLEMENTATION_SPEC_v1.md` §5.2 فقط (✅ G4).

```sql
-- staff
select using (
      profile_id = (select app.current_profile_id())
   or (    platform_tenant_id = (select app.current_tenant_id())
       and app.has_permission('staff.read') and app.staff_in_scope(id)));
update using      (app.has_permission('staff.update') and app.staff_in_scope(id))
       with check (platform_tenant_id = (select app.current_tenant_id()));

-- guardians
select using (
      profile_id = (select app.current_profile_id())
   or (    platform_tenant_id = (select app.current_tenant_id())
       and app.has_permission('guardian.read') and app.guardian_in_scope(id)));
update using      (app.has_permission('guardian.update') and app.guardian_in_scope(id))
       with check (platform_tenant_id = (select app.current_tenant_id()));

-- families
select using (
      platform_tenant_id = (select app.current_tenant_id())
  and app.has_permission('family.read')
  and (   app.family_in_scope(id)
       or exists (select 1 from public.students s           -- ولي الأمر يرى أسرة أبنائه
                  where s.family_id = families.id
                    and app.student_linked_to_guardian(s.id))));
update using      (app.has_permission('family.update') and app.family_in_scope(id))
       with check (platform_tenant_id = (select app.current_tenant_id()));

-- student_guardians
select using (
      guardian_id = (select app.current_guardian_id())
   or (app.has_permission('guardian.read') and app.student_in_scope(student_id))
   or app.student_is_self(student_id));
insert with check (app.has_permission('guardian.link') and app.student_in_scope(student_id));
update using      (app.has_permission('guardian.link') and app.student_in_scope(student_id))
       with check (app.student_in_scope(student_id));
-- إنهاء الارتباط: app.unlink_guardian (guardian.unlink) — status خارج GRANT
```

**`guardians.phone_e164` خارج سياسة UPDATE وخارج GRANT:** يتغير عبر مسار OTP في FastAPI فقط (`PLAN_v3.md` §7.8: «يعتمد الرقم الجديد مباشرة بعد نجاح OTP دون موافقة المدرسة»، والمدرسة تعدّل البيانات «باستثناء رقم الهاتف»).

**`student_guardians` INSERT لا يشترط رؤية ولي الأمر:** قد يكون ولي الأمر مرتبطاً بأبناء في مدرسة أخرى داخل الـTenant (§7.1 من الخطة). المطابقة عبر الهاتف دالة بحث تُرجع أقل قدر من البيانات — المرحلة 4.

### 10.6 `identity_scopes` وجداول Platform Admin — Gate B (F6)

```sql
-- identity_scopes: قراءة فقط لمن يستطيع الوصول للنطاق — ✅ نُفذت نهائية في M14 (لا تمسّها M17)
select using (
      platform_tenant_id = (select app.current_tenant_id())
  and app.has_permission('school.read')
  and app.can_access_identity_scope(id));
-- INSERT/UPDATE: لا سياسة — T9 ينشئها (✅ G9)

-- system_users: الذات فقط
select using (auth_user_id = auth.uid());

-- platform_admin_assignments: الذات فقط
select using (system_user_id = (select app.current_system_user_id()));

-- platform_admin_roles و platform_admin_role_permissions
-- ✅ قرار 2026-09-25 (M14): service فقط — بلا سياسة SELECT.
-- (كان هنا: select using (app.is_platform_admin()) — يخالف §11 و C3؛ ولا مفتاح في البذر يحكم قراءة هذا الكتالوج.)
```

**لا INSERT/UPDATE على جداول Platform Admin لـ`authenticated`:** إدارة Platform Admins لا مفتاح لها في الكتالوج المجمَّد، فتبقى service role فقط في v1 (✅ G8).

---

## 11. سياسات Platform Admin

تطبيقاً لقرار C3 وقرار G10: **سياسات منفصلة بسياق Platform، لا استثناء boolean ولا صلاحية Tenant.**

```sql
-- على platform_tenants
create policy platform_tenants_admin_select on platform_tenants for select
  using (app.has_platform_permission('tenant.read'));

-- ✅ M20b (2026-09-25): سياسة INSERT حُذفت — لا أعمدة INSERT لـauthenticated (§4.6)؛ الإنشاء عبر bootstrap_tenant (§5.2) حصراً

create policy platform_tenants_admin_update on platform_tenants for update
  using      (app.has_platform_permission('tenant.update'))
  with check (app.has_platform_permission('tenant.update'));
```

`has_platform_permission()` تتضمن فحص السياق، فلا حاجة لإقرانها بـ`is_platform_admin()`.

نفس النمط على `groups` و`schools` و`audit_log`.

**ما لا يوجد — عمداً:**

| ❌ | السبب |
|---|---|
| سياسة Platform Admin على `students` / `guardians` / `staff` | لا وصول لبيانات العملاء بلا دور مخصص بصلاحياته (المرحلة 13) |
| `using (app.is_platform_admin())` بلا `has_platform_permission` | يخالف C3 و Matrix §15 بند 6 |
| `has_permission(...) OR has_platform_permission(...)` في سياسة واحدة | يخالف G10 — يعيد خلط السياقين |
| اعتماد `service_role` كبديل | `PLAN_v3.md` §3.3 بند 12 |

**Audit إلزامي:** كل قراءة Platform Admin لبيانات Tenant تُسجَّل. لا يمكن لـRLS تسجيل القراءات، فيُنفَّذ في طبقة FastAPI — **دين مسجَّل، Gate F4**.

---

## 12. حالات INSERT / UPDATE / DELETE

| العملية | القاعدة العامة |
|---|---|
| `INSERT` | `WITH CHECK` فقط. الصف الجديد يجب أن يقع داخل نطاق المُنشئ |
| `UPDATE` | `USING` + `WITH CHECK` **دائماً**. الثانية تمنع نقل الصف خارج النطاق |
| `DELETE` | **لا سياسة على أي جدول Foundation** = منع كامل |
| الأرشفة | `UPDATE` على `archived_at`/`status`، بصلاحية `.archive` |

### 12.1 جدول الصلاحية لكل عملية

| الجدول | read | create | update | archive |
|---|---|---|---|---|
| `groups` | `group.read` | `group.create` | `group.update` | `group.archive` |
| `schools` | `school.read` | `school.create` | `school.update` | `school.archive` |
| `students` | `student.read` | `student.create` | `student.update` | `student.archive` |
| `guardians` | `guardian.read` | `guardian.create` | `guardian.update` | — |
| `staff` | `staff.read` | `staff.create` | `staff.update` | `staff.archive` |
| `enrollments` | `enrollment.read` | `enrollment.create` | `enrollment.update` | `enrollment.archive` |
| `academic_years` | `academic_year.read` | `academic_year.create` | `academic_year.update` | `academic_year.close` |
| `sections` | `section.read` | `section.manage` | `section.manage` | `section.manage` |

### 12.2 ما لا تستطيع RLS فعله — يُنفَّذ في مكان آخر

| القيد | المكان |
|---|---|
| `read` مقابل `export` | RLS تحكم الصفوف لا القناة. `*.export` تُفرض في FastAPI/الواجهة وتُسجَّل في Audit |
| `sensitive_read` (حقول لا صفوف) | ~~`GRANT SELECT (columns)`~~ — **لا يعمل** (انظر أدناه). ✅ G5: لا أعمدة حساسة في Foundation؛ الحساس في جداول مستقلة من المرحلة 4 |
| منع تعديل عمود **على كل المستخدمين** | `GRANT UPDATE (columns)` — سجل الأعمدة في `DB_IMPLEMENTATION_SPEC_v1.md` §4.6 |
| تعديل عمود **بصلاحية بعينها** (`.archive`, `.activate`, `.close`, `.unlink`) | دوال انتقال حالة `SECURITY DEFINER` — `DB_IMPLEMENTATION_SPEC_v1.md` §5.3 |

**🔴 تصحيح Gate B:** صلاحيات الأعمدة في Postgres تُمنح **لدور DB** (`authenticated`) لا لصلاحية تطبيق. كل مستخدمي النظام يشتركون في الدور نفسه، فـ`GRANT` لا يميّز من يملك `student.sensitive_read` عمن لا يملكها، ولا من يملك `student.archive` عمن يملك `student.update` فقط. الحل المقترح أصلاً لـN4/N6 كان سيُنتج إما منعاً للجميع أو إتاحة للجميع.
| `grant.permission ⊆ actor.permissions` | trigger T8 (§10.2) |
| تسجيل القراءات الحساسة | FastAPI، Gate F4 |

**هذا الجدول مهم بقدر السياسات نفسها:** الادعاء بأن RLS تكفي وحدها هو بالضبط ما ينتج ثغرات لاحقاً.

---

## 13. `audit_log`

```sql
-- SELECT فقط — مصحّح في Gate B (F10، F11)
using (
  (
    app.has_permission('audit.read')          -- سياق Tenant: الفروع (1)–(3)
    and (
        -- (1) صف مدرسي ضمن النطاق
        (school_id is not null and app.can_access_school(school_id))
        -- (2) كيان هوية مرئي للفاعل الآن
     or (platform_tenant_id = (select app.current_tenant_id()) and (
              (entity_type = 'students'  and app.student_in_scope(entity_id::uuid))
           or (entity_type = 'guardians' and app.guardian_in_scope(entity_id::uuid))
           or (entity_type = 'staff'     and app.staff_in_scope(entity_id::uuid))
           or (entity_type = 'families'  and app.family_in_scope(entity_id::uuid))))
        -- (3) صف tenant-level آخر: يلزم نطاق tenant
     or (school_id is null and app.can_access_tenant(platform_tenant_id))
    )
  )
        -- (4) Platform Admin: كيانات المنصة فقط، بصلاحية سياق Platform
     or (    app.has_platform_permission('audit.read')
         and entity_type in ('platform_tenants','groups','schools','system_users',
                             'platform_admin_roles','platform_admin_assignments',
                             'platform_admin_role_permissions'))
)
```

**F10 — الثغرة المصحَّحة:** الشرط القديم `platform_tenant_id = current AND school_id IS NULL` كان يعرض كل صفوف tenant-level لأي حامل `audit.read`. جداول الهوية بلا `school_id`، فصفوف تعديلاتها tenant-level — أي أن المحاسب (يملك `audit.read`) كان يرى **تعديلات كل الطلاب في كل مدارس الـTenant** كاملة في `old_values`/`new_values`.

**F11 — الثغرة المصحَّحة:** الفرع `is_platform_admin() AND has_permission('audit.read')` كان يعرض **كل** صفوف التدقيق لـPlatform Admin — وفيها بيانات الطلاب وأولياء الأمور كاملة. أي التفاف تام على قرار C3 عبر سجل التدقيق.

~~**حدود المسار (2):** الرؤية بالعلاقة **الحالية**، لا التاريخية — طالب انتقل خارج نطاقي تبقى تعديلاته السابقة مرئية لأن `student_in_scope` تقبل أي enrollment.~~

**✅ M18 (2026-09-25) — نفّذ بثلاثة فروق عن النص أعلاه:** (أ) **H2:** المسار (2) بالعلاقة الحالية فعلاً؛ تدقيق هوية طالب انتقل ينتقل مع الطالب إلى مدرسته الجديدة، والمدرسة السابقة تبقى ترى صفوفها المدرسية (school_id) فقط. (ب) **G10:** الفرع (4) سياسة مستقلة `audit_log_platform_select` لا `OR` داخل سياسة واحدة (§2.4). (ج) التحويل `entity_id::uuid` داخل `CASE`: مفاتيح جداول الربط مركّبة (`a:b`) وPostgres لا يضمن ترتيب تقييم `AND`. SELECT على الجدول لـ`authenticated` في M20.

- **لا سياسة INSERT/UPDATE/DELETE** — الكتابة عبر trigger `SECURITY DEFINER` حصراً، و`REVOKE UPDATE, DELETE` + trigger الرفض (`DATA_DICTIONARY_v1.md` §2.26).
- `audit.sensitive_read` تُقيِّد أنواع أحداث بعينها — تُنفَّذ بشرط إضافي على `entity_type` عند تعريف قائمة الأحداث الحساسة في Gate D3.

---

## 14. ترتيب تنفيذ Gate D

```text
D1  schema app + الدوال (§1–§3) بمالك BYPASSRLS
D2  التحقق من BYPASSRLS ثم ENABLE + FORCE RLS على الجداول الـ29
D3  سياسات Tenant/Group/School (§7) + GRANT على مستوى الأعمدة (§12.2)
D4  سياسات students / enrollments (§8, §9) + دوال العلاقة
D5  سياسات profiles/memberships (§10) + trigger T8
D6  سياسات Platform Admin (§11)
D7  سياسة audit_log (§13)
```

**D2 قبل D3 مقصود:** تفعيل `FORCE` قبل كتابة السياسات يجعل أي خطأ recursion يظهر فوراً لا بعد عشرات السياسات.

---

## 15. اختبارات pgTAP المطلوبة

تُضاف إلى قائمة `AUTHORIZATION_MATRIX_v1.md` §16.

### 15.1 العزل

| # | الاختبار |
|---|---|
| I1 | Tenant A لا يقرأ أي صف من Tenant B في جداول Foundation الـ29 |
| I2 | عضو مدرسة A **داخل نفس Tenant** لا يقرأ مدرسة B |
| I3 | `group` scope يرى كل مدارس مجموعته ولا شيء خارجها |
| I4 | `group` scope **لا** يرى مدرسة مستقلة (`group_id IS NULL`) — يختبر شرط §3 نقطة 2 |
| I5 | عدة `school` scopes تعمل معاً |
| I6 | `current_tenant_id()` تُرجع صفاً واحداً بالضبط (O1) |
| I7 | لا يوجد `auth_user_id` في `profiles` و`system_users` معاً |

### 15.2 الفصل بين Permission و Scope

| # | الاختبار |
|---|---|
| P1 | Permission بلا Scope ⇒ لا وصول |
| P2 | Scope بلا Permission ⇒ لا وصول |
| P3 | `student.read` بلا `student.export` ⇒ القراءة تعمل والتصدير يُرفض |
| P4 | دور معطَّل (`roles.status='inactive'`) يُسقط صلاحياته فوراً |

### 15.3 العلاقة التشغيلية

| # | الاختبار |
|---|---|
| R1 | ولي الأمر يرى أبناءه فقط، ولا يرى طالباً آخر في نفس المدرسة |
| R2 | الطالب يرى سجله فقط |
| R3 | موظف لا يرى طالباً بلا enrollment في مدارسه |
| R4 | `bus_supervisor` لا يرى أي طالب (Seed §4.8) |
| R5 | المعلم — علامة `TODO` تفشل حتى تُضاف `teaching_assignments` (دين D1) |

### 15.4 منع التصعيد ⚠️

| # | الاختبار |
|---|---|
| E1 | `UPDATE enrollments SET school_id` إلى مدرسة خارج النطاق ⇒ **رفض** (§5.1) |
| E2 | `UPDATE students SET platform_tenant_id` ⇒ رفض |
| E3 | `school_admin` يمنح `membership_scope` لمدرسة أخرى ⇒ رفض |
| E4 | `school_admin` يسند دور `tenant_admin` ⇒ رفض (trigger T8) |
| E5 | لا دور Tenant يملك `tenant.suspend` |
| E6 | `DELETE` على أي جدول Foundation ⇒ رفض |
| E7 | Platform Admin بلا `student.read` لا يقرأ أي طالب |
| E8 | `is_platform_admin()` وحدها لا تمنح أي وصول |
| E9 | 🔴 `school_admin` يمنح نفسه أو غيره نطاق `tenant` ⇒ **رفض** (F1) |
| E10 | 🔴 `group_manager` ينشئ مدرسة في مجموعة أخرى ⇒ **رفض** (F1) |
| E11 | 🔴 ولي أمر يقرأ profile غير profile ه ⇒ صفر صفوف (F2) |
| E12 | `group_manager` لا يرى عضويات مجموعة أخرى (F3) |
| E13 | 🔴 `school_admin` A يسند دوراً لعضوية نطاقها B ⇒ **رفض** (F4) |
| E14 | 🔴 إسناد دور مخصص فارغ للذات ثم إضافة صلاحية لا يملكها الفاعل ⇒ **رفض** في الخطوتين (F5) |
| E15 | 🔴 المحاسب لا يرى تدقيق طالب خارج مدرسته (F10) |
| E16 | 🔴 Platform Admin لا يرى أي صف تدقيق `entity_type = 'students'` (F11) |
| E17 | حساب واحد لا يملك profile و system_user معاً (G10) |

### 15.5 السلامة التقنية

| # | الاختبار |
|---|---|
| T1 | كل الدوال تعمل بعد `FORCE RLS` بلا recursion (§4.2) |
| T2 | كل جدول من الـ**29** (28 + `auth_identities`، G10) عليه `relrowsecurity = true` و`relforcerowsecurity = true` — بالاسم، وأي جدول غير مدرج يُفشل الاختبار (`13_rls_enable`، M13) |
| T3 | لا جدول Foundation بلا سياسة SELECT (منع نسيان صامت) — **هذا الاختبار كان سيفشل على 9 جداول في A3 الأصلي (F6)** |
| T4 | `audit_log` يرفض UPDATE و DELETE من كل الأدوار |

---

## 16. ملخص البنود المعلّقة الناتجة عن A3

| # | البند | يُسدّ في |
|---|---|---|
| ~~**N1**~~ | ~~`students.student_profile_id` مفقود~~ | ✅ **مغلق بقرار A4** — `NOT NULL UNIQUE` |
| **N2** | trigger **T8**: `grant.permission ⊆ actor.permissions` (§10.2) | Gate D5 |
| **N3** | التحقق العملي من `BYPASSRLS` لمالك الدوال (§4.2) | Gate D1 |
| **N4** | `GRANT` على مستوى الأعمدة لـ`profiles` و`sensitive_read` (§12.2) | Gate D3 |
| **N5** | تسجيل قراءات Platform Admin الحساسة في Audit (§11) | Gate F4 |
| **N6** | فصل `.archive` عن `.update` على مستوى العمود (§7) | Gate D3 |

**N1 و N2 يجب أن يُغلقا قبل Gate D:** الأول يمنع كتابة `student_is_self`، والثاني ثغرة تصعيد صلاحية فعلية.

---

## 17. حالة A3

| البند | الحالة |
|---|---|
| Identity & Tenant Resolution | ✅ §1 |
| Permission Resolution | ✅ §2 |
| Scope Resolution | ✅ §3 |
| `can_access_tenant/group/school` | ✅ §3 |
| `has_permission` | ✅ §2 |
| سياسات Tenant/Group/School | ✅ §7 |
| سياسات `students` و`enrollments` | ✅ §8, §9 |
| سياسات `profiles`/`memberships` | ✅ §10 |
| سياسات Platform Admin | ✅ §11 |
| منع الـrecursion | ✅ §4 |
| `USING` مقابل `WITH CHECK` | ✅ §5 |
| INSERT/UPDATE/DELETE | ✅ §12 |
| اختبارات pgTAP | ✅ §15 |
| بنود معلّقة | ⚠️ 6 بنود (§16) |

**الخطوة التالية:** A4 — مراجعة A1–A3 مقابل `ERD_CORE_v1.md`، مع حسم N1 و N2.
