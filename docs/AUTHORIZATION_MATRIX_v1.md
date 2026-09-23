# Authorization Matrix v1 — School Management System

**التاريخ:** 2026-09-22  
**الحالة:** Foundation / A2 — جاهز للمراجعة قبل SQL migrations  
**المرجع:** PLAN_v3.md + ERD_CORE_v1.md + قرارات O1–O3 المعتمدة

---

## 1. قاعدة التفويض النهائية

التفويض ليس Role وحده. القرار الفعلي للوصول هو:

```text
Authenticated User
        ↓
Profile → Platform Tenant
        ↓
Membership
        ↓
Role(s) → Permission(s)
        ↓
Scope(s): Tenant / Group / School
        ↓
Target ownership + relationship rules
        ↓
ALLOW / DENY
```

ويجب أن تتحقق RLS من العزل قبل أي قرار صلاحية تشغيلي:

1. المستخدم مرتبط بـPlatform Tenant واحد فقط.
2. الهدف يقع داخل نفس Platform Tenant.
3. المستخدم يملك Scope مناسباً للهدف.
4. لديه Permission المطلوبة للعملية.
5. توجد أي علاقة تشغيلية إضافية مطلوبة (مثلاً تكليف المعلم بالشعبة/المادة).

Frontend visibility ليست Security Boundary.

---

## 2. أنواع الـScope

| Scope | المعنى | أمثلة |
|---|---|---|
| `tenant` | جميع المدارس داخل Tenant | مدير المجموعة/التنفيذي المصرح له |
| `group` | جميع مدارس Group محدد | Group Manager |
| `school` | مدرسة محددة | School Admin / Teacher |

`membership_scopes` تحدد **أين** يمكن استعمال الصلاحية، ولا تمنح الصلاحية بذاتها.

عدة مدارس = عدة `school` scope rows، ولا نحتاج Scope type خاصاً باسم `multi_school`.

---

## 3. مبادئ المنح

- لا يمكن لأي مدير منح Permission لا يملكها هو نفسه.
- يمكن تضييق Scope فقط؛ لا يمكن توسيعه خارج Scope المانح.
- `read` و`export` صلاحيتان منفصلتان.
- `create/update` لا يعني `approve`.
- العمليات الحساسة قد تتطلب Permission إضافية حتى لو كان المستخدم يستطيع القراءة.
- Platform Admin ليس Tenant member ولا يرث صلاحيات Tenant تلقائياً.
- الوصول إلى بيانات Tenant من Platform Admin يحتاج Permission/مسار إداري صريح، ويجب أن يكون قابلاً للتدقيق.
- تعطيل/أرشفة Tenant أو School يمنع العمليات الجديدة وفق الحالة، لكنه لا يحذف التاريخ.

---

## 4. Permission Catalog — Foundation

الصيغة الموحدة:

```text
<resource>.<operation>
```

**الكتالوج مجمَّد عند 73 مفتاحاً** بعد قرارات K1–K4. **`docs/ROLE_PERMISSION_SEED_v1.md` §2 هو المصدر الرسمي للكتالوج**، وهذا القسم يعكسه حرفياً؛ عند أي اختلاف يُرجَّح الـseed. قواعد التسمية والمفاتيح المحجوزة للوحدات المؤجلة (`attendance.*`, `grade.*`, `admission.*`, `fee.*` …) في `docs/ROLE_PERMISSION_SEED_v1.md` §2. أي مفتاح جديد بعد هذه النقطة يحتاج قراراً في `PLAN_v3.md` §9.

### 4.1 Tenancy

| Permission | العملية |
|---|---|
| `tenant.create` | إنشاء Tenant — **Platform Admin حصراً** (K4) |
| `tenant.read` | قراءة Tenant |
| `tenant.update` | تعديل إعدادات Tenant |
| `tenant.suspend` | تعليق Tenant — **Platform Admin حصراً، لا يُمنح لأي دور Tenant** (K3) |
| `tenant.export` | تصدير بيانات Tenant |

> `tenant.manage` **حُذف** (K3): مبهم ومتداخل كلياً مع `tenant.update`، ووجود مفتاحين للعملية نفسها يفتح باب منح غير مقصود.

### 4.2 Groups

| Permission | العملية |
|---|---|
| `group.read` | قراءة Group |
| `group.create` | إنشاء Group |
| `group.update` | تعديل Group |
| `group.archive` | تعطيل/أرشفة Group |
| `group.export` | تصدير بيانات Group |

### 4.3 Schools

| Permission | العملية |
|---|---|
| `school.read` | قراءة مدرسة |
| `school.create` | إنشاء مدرسة |
| `school.update` | تعديل إعدادات المدرسة |
| `school.archive` | إغلاق/أرشفة مدرسة |
| `school.export` | تصدير بيانات المدرسة |

### 4.4 Profiles / Memberships / Roles

| Permission | العملية |
|---|---|
| `profile.read` | قراءة الملف الشخصي الإداري |
| `profile.update` | تعديل البيانات المسموح بها |
| `membership.read` | قراءة العضويات |
| `membership.create` | إنشاء عضوية |
| `membership.update` | تعديل عضوية |
| `membership.end` | إنهاء عضوية |
| `role.read` | قراءة الأدوار |
| `role.create` | إنشاء Role مخصص |
| `role.update` | تعديل Role مخصص |
| `role.assign` | إسناد Role لعضوية |
| `scope.assign` | إسناد/تضييق Scope |
| `permission.read` | قراءة Permission catalog |

### 4.5 Students

| Permission | العملية |
|---|---|
| `student.read` | قراءة بيانات الطالب |
| `student.create` | إنشاء طالب |
| `student.update` | تعديل بيانات الطالب |
| `student.archive` | أرشفة الطالب |
| `student.transfer` | بدء/تنفيذ نقل وفق قواعد النقل |
| `student.export` | تصدير بيانات الطلاب |
| `student.sensitive_read` | قراءة الحقول المصنفة حساسة |

### 4.6 Guardians / Families

| Permission | العملية |
|---|---|
| `family.read` | قراءة الأسرة |
| `family.update` | تعديل الأسرة |
| `guardian.read` | قراءة ولي الأمر |
| `guardian.create` | إنشاء ولي أمر |
| `guardian.update` | تعديل بيانات ولي الأمر المسموح بها |
| `guardian.link` | ربط ولي أمر بطالب |
| `guardian.unlink` | فك الربط وفق الصلاحية |
| `guardian.sensitive_read` | قراءة بيانات حساسة لولي الأمر |
| `guardian.export` | تصدير بيانات أولياء الأمور |

### 4.7 Staff

| Permission | العملية |
|---|---|
| `staff.read` | قراءة الموظفين |
| `staff.create` | إنشاء موظف |
| `staff.update` | تعديل موظف |
| `staff.archive` | أرشفة موظف |
| `staff.assign` | إسناد الموظف إلى مدرسة/تكليف |
| `staff.export` | تصدير الموظفين |

### 4.8 Academic Setup

| Permission | العملية |
|---|---|
| `academic_year.read` | قراءة السنة |
| `academic_year.create` | إنشاء سنة |
| `academic_year.update` | تعديل سنة قبل الإغلاق وفق القيود |
| `academic_year.activate` | تفعيل سنة |
| `academic_year.close` | إغلاق سنة |
| `academic_year.export` | تصدير بيانات السنة |
| `term.read` | قراءة الفصول الدراسية |
| `term.manage` | إدارة الفصول الدراسية |
| `stage.read` | قراءة المراحل |
| `stage.manage` | إدارة المراحل |
| `grade_level.read` | قراءة الصفوف |
| `grade_level.manage` | إدارة الصفوف |
| `section.read` | قراءة الشعب |
| `section.manage` | إدارة الشعب |

> **K1 — تصادم بادئة `grade`:** كان هذا المفتاح `grade.manage` بمعنى "إدارة الصفوف"، بينما §7 و§10 يستعملان `grade.enter`/`grade.approve` بمعنى **الدرجات**. موردان مختلفان تحت بادئة واحدة يجعلان `app.has_permission('grade.*')` غامضة وأي سياسة RLS تُبنى عليها خطأ أمنياً صامتاً.
> **القرار:** `grade.manage` → `grade_level.manage` (مطابق لجدول `grade_levels`)، والبادئة `grade.*` **محجوزة حصراً للدرجات** في المرحلة 6.
>
> **K2 — مفاتيح القراءة:** كانت البنية الأكاديمية تعرّف `.manage` فقط، فلا يجد المعلم والسكرتارية مفتاحاً لقراءة الشعب والصفوف إلا بمنحهم `.manage` — تصعيد صلاحية غير مبرر. أُضيفت `term.read`, `stage.read`, `grade_level.read`, `section.read`.

### 4.9 Enrollment

| Permission | العملية |
|---|---|
| `enrollment.read` | قراءة التسجيل |
| `enrollment.create` | إنشاء تسجيل |
| `enrollment.update` | تعديل التسجيل ضمن القيود التاريخية |
| `enrollment.transfer` | نقل الطالب |
| `enrollment.archive` | إنهاء/أرشفة التسجيل |
| `enrollment.export` | تصدير التسجيلات |

### 4.10 Audit / Security

| Permission | العملية |
|---|---|
| `audit.read` | قراءة سجل التدقيق ضمن Scope |
| `audit.sensitive_read` | قراءة أحداث حساسة |
| `security.manage` | إدارة إعدادات أمنية محددة |
| `security.export` | تصدير سجل أمني |

---

## 5. Role Baseline

الأدوار التالية **قوالب مرجعية** وليست بديلاً عن Permission + Scope.

| Role | Scope المعتاد | الوظيفة الأساسية |
|---|---|---|
| Platform Admin | System | إدارة المنصة؛ ليس Tenant member |
| Tenant Admin | Tenant | إدارة Tenant وفق الصلاحيات الممنوحة |
| Group Manager | Group | إدارة مدارس Group وفق الصلاحيات |
| School Admin | School | إدارة مدرسة |
| Accountant | School | المالية وفق الصلاحيات المالية |
| Teacher | School | التدريس والبيانات التعليمية المصرح بها |
| Guardian | School(s) عبر علاقات الأبناء | بيانات أبنائه فقط |
| Student | School الحالية + التاريخ المسموح | بياناته فقط |

هذه الأدوار لا تعني أن كل Permission في الجدول ممنوحة تلقائياً؛ الـbaseline النهائي يثبت عند تعريف seed roles.

**الأدوار المبذورة فعلياً — 10 أدوار:** `tenant_admin`, `group_manager`, `school_admin`, `secretary`, `accountant`, `teacher`, `counselor`, `bus_supervisor`, `guardian`, `student`.
الثلاثة الأخيرة من `PLAN_v3.md` §2 ولم تكن مذكورة في الجدول أعلاه لأن تركيزه على Foundation؛ و`tenant_admin`/`group_manager` إضافة يوجبها §7.9.

`Platform Admin` في الجدول أعلاه **عرض مفاهيمي فقط**: لا يُبذَر في `roles` بل في `platform_admin_roles` (`PLAN_v3.md` §10 بند 2).

**الخريطة النهائية Role → Permission في `docs/ROLE_PERMISSION_SEED_v1.md` §4** — وهي المرجع الملزم لبذر `role_permissions`، لا الجدول المختصر في §6 أدناه.

---

## 6. Matrix الأساسية حسب Role

`R` = Read، `W` = Create/Update، `A` = Approve، `X` = Export، `—` = لا صلاحية افتراضية.

| Resource | Tenant Admin | Group Manager | School Admin | Accountant | Teacher |
|---|---:|---:|---:|---:|---:|
| Tenant settings | RW | R | R | — | — |
| Groups | RW | R | — | — | — |
| Schools | RW | RW ضمن Group | R/W ضمن School | R | R |
| Profiles/Memberships | RW | RW ضمن Group | RW ضمن School | R | R محدود |
| Roles/Scopes | RW | RW ضمن Scope | RW ضمن School | — | — |
| Students | RWX | RWX ضمن Group | RWX ضمن School | R | R محدود |
| Guardians | RWX | RWX ضمن Group | RWX ضمن School | R محدود | R محدود |
| Staff | RWX | RWX ضمن Group | RWX ضمن School | R | R محدود |
| Academic setup | RW | RW ضمن Group | RW | R | R |
| Enrollment | RWX | RWX ضمن Group | RWX | R | R |
| Audit | R | R ضمن Scope | R ضمن School | R مالي | R ضمن Scope |

> هذا الجدول baseline عالي المستوى. لا يستخدم مباشرة كسياسات SQL؛ القرار النهائي هو Permission code + Scope + target ownership + business rule.

**انحرافان موثقان في الـseed النهائي عن صف `Audit` أعلاه** (`docs/ROLE_PERMISSION_SEED_v1.md` §4.5 و§4.6):

| الصف | الجدول أعلاه | الـseed | السبب |
|---|---|---|---|
| Accountant / Audit | `R مالي` | `audit.read` بلا تضييق نوعي | لا يوجد `audit.financial_read` في كتالوج Foundation؛ التضييق المالي يُضاف في المرحلة 7 |
| Teacher / Audit | `R ضمن Scope` | **لم تُمنح** | `audit.read` تكشف تصرفات مستخدمين آخرين داخل المدرسة (تعديلات الإدارة على الدرجات والمالية والصلاحيات) — يتجاوز حاجة المعلم التشغيلية ويخالف مبدأ أقل قدر من البيانات |

---

## 7. Approval Separation

العمليات التالية لا يجوز اعتبارها متاحة لمجرد امتلاك Permission الإدخال:

```text
entry permission ≠ approval permission
```

ويجب أن يكون لكل مجال يحتاج اعتماد Permission مستقلة، مثل:

- `grade.enter` مقابل `grade.approve`
- `fee.enter` مقابل `fee.adjust_approve`
- `payment.enter` مقابل `payment.refund_approve`
- `transfer.request` مقابل `transfer.approve`
- `report.create` مقابل `report.publish`

هذا يمنع أن يقوم الشخص نفسه بإدخال واعتماد العملية عندما تفرض سياسة المدرسة الفصل بين المهام.

---

## 8. Export Separation

التصدير مستقل عن القراءة:

```text
student.read    → يستطيع عرض البيانات
student.export  → يستطيع استخراجها خارج النظام
```

وهذا ينطبق على كل Resource حساس، بما في ذلك:

- الطلاب
- أولياء الأمور
- الموظفين
- الحضور
- الدرجات
- المالية
- التقارير
- Audit/Security

وجود `read` لا يمنح `export` تلقائياً.

---

## 9. Guardian Authorization

Guardian لا يعتمد على Role + School Scope وحدهما.

حتى مع وجود صلاحية عامة، يجب أن يثبت النظام علاقة فعالة:

```text
Guardian Account
      ↓
student_guardians
      ↓
Student
      ↓
Current / authorized enrollment
      ↓
Allowed guardian fields
```

لذلك ولي الأمر لا يستطيع قراءة طالب آخر في نفس المدرسة لمجرد امتلاكه `student.read` في الواجهة أو API.

والحقول التي تظهر لولي الأمر تخضع أيضاً لسياسة المدرسة لكل نوع بيانات.

---

## 10. Teacher Authorization

Teacher يمكن أن يمتلك `student.read` ضمن المدرسة، لكن الوصول إلى بعض العمليات التعليمية يجب أن يمر بعلاقة التكليف:

```text
Teacher
  ↓
Staff / Staff School Assignment
  ↓
Teaching Assignment
  ↓
Section / Subject
```

مثلاً:

- `grade.enter` يجب أن يتحقق من أن المعلم مخول للمادة/الشعبة.
- `homework.create` يجب أن يتحقق من أن الشعبة ضمن نطاق المعلم.
- لا يكفي أن يكون للمعلم `school` scope عاماً إذا كانت العملية مقيدة بالتكليف.

---

## 11. Scope Evaluation

المنطق المفاهيمي:

```text
can_access(target):
    tenant_match = target.platform_tenant_id == current_tenant_id()
    scope_match  = tenant_scope
                OR group_scope(target.group_id)
                OR school_scope(target.school_id)

    return tenant_match AND scope_match
```

ثم:

```text
can(action, target):
    return can_access(target)
       AND has_permission(action)
       AND business_relationship_allows(action, target)
```

ولا يجوز أن يعاد تعريف هذا المنطق بشكل مختلف في كل endpoint أو policy.

---

## 12. RLS Helper Contract

الدوال الأساسية التي يجب أن تستعملها السياسات:

```text
app.current_tenant_id()
app.can_access_tenant(tenant_id)
app.can_access_group(group_id)
app.can_access_school(school_id)
app.has_permission(permission_code)            -- سياق Tenant حصراً
app.has_platform_permission(permission_code)   -- سياق Platform حصراً (G10)
app.current_security_context()                 -- 'tenant' | 'platform'
```

وقد يوجد helper أداء:

```text
app.user_school_ids()
```

لكن هذا helper **ليس مصدر الصلاحية الوحيد**.

`app.current_tenant_id()` يعتمد على حقيقة O1: `auth_user_id` مرتبط بـProfile واحد وTenant واحد، ولذلك لا يحتاج Tenant claim في JWT ولا subdomain لتحديد Tenant الأمني.

---

## 13. Delegation Rules

عند منح Role أو Scope:

```text
grant.permission ⊆ actor.permissions
AND
grant.scope ⊆ actor.scope
```

أمثلة:

- Group Manager لا يمنح Tenant-wide Scope إذا كان Scope الخاص به Group.
- School Admin لا يمنح مستخدماً Scope لمدرسة أخرى.
- المستخدم الذي لا يملك `student.export` لا يستطيع منحها لغيره.
- تعديل Role مخصص لا يسمح بإضافة Permission أعلى من صلاحيات المانح.

---

## 14. Sensitive Access / Audit

العمليات التالية قابلة للتدقيق حتى لو كانت قراءة فقط:

- قراءة الحقول الحساسة.
- تصدير البيانات.
- تغيير الصلاحيات والأدوار.
- تغيير Scope.
- الوصول الإداري من Platform Admin إلى بيانات Tenant.
- العمليات المالية الحساسة.
- تصحيح الدرجات بعد الاعتماد.

Audit لا يمنح Permission؛ هو سجل لما حدث.

---

## 15. قواعد منع تجاوز العزل

يجب أن تفشل العمليات التالية:

1. استخدام `school_id` من Browser للوصول إلى مدرسة غير مصرح بها.
2. تغيير `platform_tenant_id` في payload لتجاوز Tenant الحالي.
3. تمرير Group من Tenant آخر إلى endpoint.
4. قراءة Student ليس له Enrollment داخل المدارس المصرح بها.
5. قراءة Guardian/Student relationship خارج نطاق المستخدم.
6. استخدام Platform Admin identity كوسيلة تلقائية لتجاوز RLS.
7. الاعتماد على إخفاء زر Export بدلاً من `*.export` permission.
8. الاعتماد على Role name بدلاً من Permission code.
9. الاعتماد على JWT/subdomain كمصدر نهائي للعزل.

---

## 16. Required pgTAP / Security Tests

قبل Foundation Gate يجب أن توجد اختبارات على الأقل لـ:

- Tenant A cannot read Tenant B.
- Tenant scope sees all authorized schools but no other Tenant.
- Group scope sees all schools in Group and no school outside Group.
- School scope sees only that school.
- Multiple school scopes work simultaneously.
- Same user cannot have two Tenant profiles بسبب O1.
- `current_tenant_id()` returns exactly one Tenant.
- Read does not imply Export.
- Permission without Scope does not grant access.
- Scope without Permission does not grant access.
- Guardian sees only linked students.
- Teacher operation requires required teaching assignment where applicable.
- Platform Admin has no implicit Tenant data access.
- Cross-tenant foreign-key combinations are rejected.
- Archived/closed entities obey operational-state rules without exposing deleted data.

---

## 17. A2 Gate

قبل الانتقال إلى A3 / RLS implementation يجب أن تكون العناصر التالية مثبتة:

- [x] Role + Permission + Scope model.
- [x] Tenant / Group / School scope hierarchy.
- [x] Export permission separate from Read.
- [x] Approval permission separate from Entry.
- [x] Platform Admin boundary separate.
- [x] Guardian relationship constraint.
- [x] Teacher operational-assignment constraint.
- [x] Delegation cannot expand authority.
- [x] O1 single Tenant per Auth User.
- [x] RLS helper contract.
- [x] Permission keys frozen (K1–K3) — 73 مفتاحاً، وقواعد تسمية ومفاتيح محجوزة للوحدات المؤجلة.
- [x] Final seed Role → Permission mappings — `docs/ROLE_PERMISSION_SEED_v1.md` §4.
- [ ] Exact permission catalog for all modules — **مؤجل بقصد**: Foundation مثبَّت، وبقية الوحدات محجوزة الأسماء وتُضاف في migration مرحلتها.
- [ ] SQL/RLS implementation and pgTAP tests — Gates C/D/E.

- [x] **Platform Admin authorization (قرار C3، 2026-09-22):** `platform_admin_roles → platform_admin_role_permissions → permissions`. نفس الكتالوج، assignments مستقلة عن Tenant Roles. `is_platform_admin()` اختبار هوية فقط ولا يمنح صلاحية. **G10 (2026-09-23):** سياقان منفصلان — `has_permission()` لـTenant و`has_platform_permission()` لـPlatform، والسياق يُحدَّد أولاً؛ لا `OR` بينهما. التفاصيل: `docs/RLS_MODEL_v1.md` §2.

**Next:** A3 — RLS Model & Policy Specification.
