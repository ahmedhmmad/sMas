# Role → Permission Seed v1 — Foundation

**التاريخ:** 2026-09-22
**الحالة:** A2.1 + A2.2 — إغلاق البند المفتوح في `AUTHORIZATION_MATRIX_v1.md` §17
**المرجع:** `AUTHORIZATION_MATRIX_v1.md` §4 (الكتالوج) و§5 (الأدوار) + `docs/DATA_DICTIONARY_v1.md` §2.9–2.11
**النطاق:** Foundation فقط — 10 أدوار × كتالوج §4. لا تُفتح صلاحيات الوحدات المؤجلة.

---

## 1. القاعدة الحاكمة للبذر

> **Role يمنح Permission؛ Scope يحدد أين؛ Business Relationship يحدد على أي سجل؛ وRLS يفرض الثلاثة.**

نتائج عملية لهذه القاعدة في هذا الملف:

1. **لا تُمنح صلاحية لمجرد أن اسم الدور واسع.** `bus_supervisor` لا يأخذ `student.read` في Foundation لأن العلاقة التي تُضيّقه (خط الباص) غير موجودة قبل المرحلة 7.
2. **لا تُمنح صلاحية لأن الدور سيحتاجها لاحقاً.** الصلاحية تُضاف في migration المرحلة التي تُنشئ علاقتها.
3. **الصلاحية الواسعة + غياب العلاقة = ثغرة**، لا "راحة تشغيلية".
4. `sensitive_read` و`*.export` لا تُمنحان ضمناً مع `read` أبداً (Matrix §8).
5. الأدوار **لا تحمل Scope**. عمود "Scope المعتاد" في أي جدول هنا وصفي، والـScope الفعلي يُسنَد للعضوية في `membership_scopes`.

---

## 2. قرارات تثبيت المفاتيح (A2.2)

ثلاثة تعديلات على كتالوج §4 **يجب** أن تُثبَّت قبل A3، لأن سياسات RLS ستُكتب على هذه المفاتيح حرفياً.

### K1 — تصادم `grade.*` ⚠️

`AUTHORIZATION_MATRIX_v1.md` يستعمل البادئة `grade` بمعنيين مختلفين:

| الموضع | المفتاح | المعنى |
|---|---|---|
| §4.8 | `grade.manage` | إدارة **الصفوف الدراسية** (`grade_levels`) |
| §7 و§10 | `grade.enter` / `grade.approve` | إدخال واعتماد **الدرجات** (scores) |

موردان مختلفان تماماً تحت بادئة واحدة. لو بقي كذلك، فإن `app.has_permission('grade.read')` تصبح غامضة، وأي سياسة RLS تُبنى عليها تُصبح خطأ أمنياً صامتاً.

**القرار:** `grade.manage` → **`grade_level.manage`** (يطابق اسم الجدول `grade_levels` في Data Dictionary §2.24).
البادئة `grade.*` **محجوزة حصراً للدرجات** في المرحلة 6.

### K2 — نقص `.read` في البنية الأكاديمية

§4.8 يعرّف `academic_year.read` لكنه يعرّف للبقية `.manage` فقط. والنتيجة أن السكرتارية والمعلم لا يملكان مفتاحاً لقراءة الشعب والصفوف — وهي قراءة يحتاجها التسجيل والكشوف يومياً، والبديل الوحيد منحهم `.manage` وهو تصعيد صلاحية غير مبرر.

**القرار:** تُضاف أربعة مفاتيح قراءة داخل نفس موارد §4.8 (لا وحدات جديدة):

`term.read`, `stage.read`, `grade_level.read`, `section.read`

### K3 — `tenant.manage` و`tenant.suspend`

| المفتاح | القرار |
|---|---|
| `tenant.suspend` | **لا يُمنح لأي دور Tenant.** تعليق Tenant عملية مشغِّل منصة (`PLAN_v3.md` §10 بند 2) |
| `tenant.manage` | **يُحذف من الكتالوج.** مبهم ومتداخل كلياً مع `tenant.update`؛ وجود مفتاحين للعملية نفسها يفتح باب منح غير مقصود |

### K4 — `tenant.create`

مفقود من §4.1 رغم أن إنشاء Tenant عملية حقيقية. يُضاف ويُمنح لـ`platform_admin` وحده (§6).

**الكتالوج بعد K1–K4:** 69 − 1 (`tenant.manage`) + 4 (K2) + 1 (K4) = **73 مفتاحاً**.

### 2.1 قواعد التسمية المجمّدة

```text
<resource>.<operation>
```

- `resource`: اسم مفرد بـ`snake_case`، مطابق لاسم الجدول/المجال (`grade_level` لا `grade_levels`).
- `operation` من المجموعة المغلقة التالية:

| العملية | المعنى |
|---|---|
| `read` | عرض داخل النظام |
| `sensitive_read` | عرض الحقول المصنفة حساسة |
| `create` / `update` | إنشاء / تعديل |
| `archive` | أرشفة (لا يوجد `delete` في الكتالوج إطلاقاً) |
| `export` | إخراج البيانات خارج النظام |
| `approve` | اعتماد — **لا يُشتق من `create`/`update` أبداً** (Matrix §7) |
| `enter` | إدخال تشغيلي متكرر (درجات/حضور) |
| `assign` / `link` / `unlink` | إسناد وربط وفك ربط |
| `transfer` | نقل |
| `activate` / `close` / `suspend` / `end` | تحولات حالة |
| `manage` | إدارة كاملة لمورد إعدادات بسيط |

**قاعدة:** `manage` لا تُستعمل لمورد يحمل بيانات شخصية أو مالية. تلك تُفصَّل دائماً إلى `read/create/update/archive/export`.

### 2.2 مفاتيح محجوزة للوحدات المؤجلة — **لا تُبذَر الآن**

تُثبَّت أسماؤها هنا فقط كي يشير إليها A3 وما بعده بأسماء نهائية. **لا يُدرج أي منها في `permissions` قبل migration مرحلته.**

| الوحدة | المرحلة | المفاتيح المحجوزة |
|---|---|---|
| الحضور | 5 | `attendance.read`, `attendance.create`, `attendance.update`, `attendance.export` |
| الدرجات | 6 | `grade.read`, `grade.enter`, `grade.update`, `grade.approve`, `grade.export` |
| القبول | 4 | `admission.read`, `admission.create`, `admission.review`, `admission.approve` |
| المالية | 7 | `fee.*`, `payment.*`, `discount.*`, `receipt.*` |
| الواجبات | 6 | `homework.create`, `homework.send` |
| التقارير | 10 | `report.create`, `report.publish`, `report.export` |

> **ملاحظة على `student.approve`:** لا يوجد مفهوم "اعتماد طالب" — المُعتمَد هو **طلب الالتحاق**. لذلك المفتاح الصحيح `admission.approve` في المرحلة 4، لا `student.approve`. `students` جدول هوية لا يمر بدورة اعتماد.

---

## 3. الأدوار العشرة

| # | الكود | Scope المعتاد | تُضيَّق أيضاً بـ |
|---|---|---|---|
| 1 | `tenant_admin` | `tenant` | — |
| 2 | `group_manager` | `group` | — |
| 3 | `school_admin` | `school` | — |
| 4 | `secretary` | `school` | — |
| 5 | `accountant` | `school` | — |
| 6 | `teacher` | `school` | `teaching_assignments` (م3) |
| 7 | `counselor` | `school` | تصنيف الملاحظة (م4) |
| 8 | `bus_supervisor` | `school` | خط الباص (م7) |
| 9 | `guardian` | مشتق | `student_guardians` |
| 10 | `student` | مشتق | `enrollments` (سجله وحده) |

`platform_admin` ليس منها — انظر §6.

---

## 4. خريطة Role → Permission

### 4.1 `tenant_admin` — 71 صلاحية

أعلى دور داخل Tenant. يملك كل شيء داخل Tenant **عدا** عمليات مشغِّل المنصة.

| المجموعة | الصلاحيات |
|---|---|
| Tenancy | `tenant.read`, `tenant.update`, `tenant.export` |
| Groups | `group.read`, `group.create`, `group.update`, `group.archive`, `group.export` |
| Schools | `school.read`, `school.create`, `school.update`, `school.archive`, `school.export` |
| Identity | `profile.read`, `profile.update`, `membership.read`, `membership.create`, `membership.update`, `membership.end` |
| AuthZ | `role.read`, `role.create`, `role.update`, `role.assign`, `scope.assign`, `permission.read` |
| Students | `student.read`, `student.create`, `student.update`, `student.archive`, `student.transfer`, `student.export`, `student.sensitive_read` |
| Guardians | `family.read`, `family.update`, `guardian.read`, `guardian.create`, `guardian.update`, `guardian.link`, `guardian.unlink`, `guardian.sensitive_read`, `guardian.export` |
| Staff | `staff.read`, `staff.create`, `staff.update`, `staff.archive`, `staff.assign`, `staff.export` |
| Academic | `academic_year.read/create/update/activate/close/export`, `term.read`, `term.manage`, `stage.read`, `stage.manage`, `grade_level.read`, `grade_level.manage`, `section.read`, `section.manage` |
| Enrollment | `enrollment.read/create/update/transfer/archive/export` |
| Audit | `audit.read`, `audit.sensitive_read`, `security.manage`, `security.export` |

**لا يملك:** `tenant.suspend` (K3).

### 4.2 `group_manager` — 62 صلاحية

مثل `tenant_admin` داخل Group، **ناقصاً إنشاء البنى فوق مستواه**.

**الفروق عن `tenant_admin`:**

| لا يملك | السبب |
|---|---|
| `tenant.*` كلها | خارج مستواه |
| `group.create`, `group.archive` | لا يُنشئ مجموعات ولا يؤرشف مجموعته |
| `role.create`, `role.update` | الأدوار المخصصة **على مستوى Tenant** (`roles.platform_tenant_id`)؛ إنشاؤها من Group يتجاوز النطاق — تطبيق مباشر لقاعدة `grant.scope ⊆ actor.scope` (Matrix §13) |
| `security.manage`, `security.export` | إعدادات أمنية على مستوى Tenant/School لا Group |

**يملك:** `group.read`, `group.export`, `school.create/read/update/archive/export` (داخل مجموعته — `PLAN_v3.md` §7.9)، و`role.read`, `role.assign`, `scope.assign`، وكل صلاحيات Students/Guardians/Staff/Academic/Enrollment الواردة في 4.1، و`audit.read`, `audit.sensitive_read`.

### 4.3 `school_admin` — 59 صلاحية

**الفروق عن `tenant_admin`:**

| لا يملك | السبب |
|---|---|
| `tenant.*`, `group.*` | خارج مستواه |
| `school.create`, `school.archive` | إنشاء وأرشفة المدارس من مستوى Group/Tenant |
| `role.create`, `role.update` | نفس سبب 4.2 |

**يملك:** `school.read`, `school.update`, `school.export`؛ Identity وAuthZ (`role.read`, `role.assign`, `scope.assign`, `permission.read`)؛ Students/Guardians/Staff/Academic/Enrollment كاملة كما في 4.1؛ `audit.read`, `audit.sensitive_read`, `security.manage`, `security.export`.

> `security.manage` على مستوى المدرسة يغطي إعدادات مثل نمط أول دخول لولي الأمر A/B/C (`PLAN_v3.md` §7.8).

### 4.4 `secretary` — 19 صلاحية

القبول والتسجيل وبيانات الطلاب وأولياء الأمور.

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |
| Students | `student.read`, `student.create`, `student.update` |
| Guardians | `family.read`, `family.update`, `guardian.read`, `guardian.create`, `guardian.update`, `guardian.link` |
| Academic | `academic_year.read`, `term.read`, `stage.read`, `grade_level.read`, `section.read` |
| Enrollment | `enrollment.read`, `enrollment.create`, `enrollment.update` |

**لا تملك — وكلها مقصودة:**

| المفتاح | السبب |
|---|---|
| `student.archive`, `student.transfer` | قرار إداري يحتاج اعتماد الإدارة (`PLAN_v3.md` §7.10: النقل يحتاج موافقة المدرستين) |
| `student.export`, `guardian.export` | التصدير منفصل عن القراءة (Matrix §8)؛ إخراج قوائم الطلاب وأولياء الأمور قرار إداري |
| `student.sensitive_read`, `guardian.sensitive_read` | الحقول الحساسة ليست من عمل السكرتارية |
| `guardian.unlink` | فك الربط عملية يجب أن تُعتمد |
| `enrollment.transfer`, `enrollment.archive` | كما أعلاه |
| `*.manage` الأكاديمية | السكرتارية تقرأ البنية ولا تعدّلها |

### 4.5 `accountant` — 11 صلاحية

صلاحياته المالية الفعلية تُضاف في المرحلة 7. في Foundation يقرأ فقط ما تحتاجه الفوترة.

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |
| Students | `student.read` |
| Guardians | `family.read`, `guardian.read` |
| Staff | `staff.read` |
| Academic | `academic_year.read`, `grade_level.read`, `section.read` |
| Enrollment | `enrollment.read` |
| Audit | `audit.read` |

**لا يملك:** `student.export` ولا `guardian.export` — كشوف التحصيل تأتي من تقارير المرحلة 7 بصلاحية `report.export` الخاصة بها، لا من تصدير سجلات الطلاب.

> **انحراف موثق عن Matrix §6:** الجدول هناك يعطي المحاسب `Audit: R مالي`. تقييد Audit بالنوع المالي غير قابل للتعبير في كتالوج Foundation (لا يوجد `audit.financial_read`). بُذر `audit.read` مقيداً بـschool scope، والتضييق المالي يُضاف في المرحلة 7.

### 4.6 `teacher` — 11 صلاحية

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |
| Students | `student.read` |
| Guardians | `family.read`, `guardian.read` |
| Academic | `academic_year.read`, `term.read`, `grade_level.read`, `section.read` |
| Enrollment | `enrollment.read` |
| Staff | `staff.read` |

**تضييق إلزامي (Matrix §10):** `student.read` لا يعطي المعلم كل طلاب المدرسة. RLS تُضيّقه بـ`teaching_assignments` + `class_teacher_assignments` عند وصول المرحلة 3. **حتى ذلك الحين يبقى تضييقه school scope فقط، وهذا يُسجَّل كدين تقني في §7.**

**لا يملك:** أي `*.export`، ولا `student.sensitive_read`, ولا `guardian.sensitive_read`، ولا أي `create/update` على الطلاب.

> **انحراف موثق عن Matrix §6:** الجدول هناك يعطي المعلم `Audit: R ضمن Scope`. **لم يُبذَر.** `audit.read` تكشف تصرفات مستخدمين آخرين داخل المدرسة (تعديلات الإدارة على الدرجات والمالية والصلاحيات)، وهذا يتجاوز حاجة المعلم التشغيلية ويخالف مبدأ أقل قدر من البيانات (`PLAN_v3.md` §8). يحتاج قراراً صريحاً إن أُريد منحه.

### 4.7 `counselor` — 10 صلاحيات

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |
| Students | `student.read`, `student.sensitive_read` |
| Guardians | `family.read`, `guardian.read` |
| Academic | `academic_year.read`, `grade_level.read`, `section.read` |
| Enrollment | `enrollment.read` |
| Audit | — |

`student.sensitive_read` هنا مبرَّرة: الملاحظات السلوكية والاجتماعية هي عمل الدور نفسه. تُضيَّق لاحقاً بمصفوفة تصنيف الملاحظة في المرحلة 4 (`PLAN_v3.md` §7.2).

**لا يملك:** أي `export` — تصدير الملاحظات الحساسة صلاحية إدارية مستقلة.

### 4.8 `bus_supervisor` — صلاحيتان ⚠️

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |

**لا يملك `student.read` ولا `guardian.read` في Foundation — وهذا مقصود.**

كشف الباص يحتاج الطلاب المرتبطين **بخطه** فقط. العلاقة التي تُضيّق ذلك (`bus_routes` / `student_bus_assignments`) غير موجودة قبل المرحلة 7. منحه `student.read` الآن يعني — بحكم school scope — قراءة **كل طلاب المدرسة**، وهو بالضبط ما تمنعه القاعدة الحاكمة في §1. تُضاف صلاحياته مع migration المرحلة 7.

### 4.9 `guardian` — 6 صلاحيات

الوصول يُثبَت بالعلاقة لا بالـScope (Matrix §9).

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |
| Students | `student.read` |
| Guardians | `guardian.read`, `family.read` |
| Enrollment | `enrollment.read` |

**تضييق إلزامي:** `student.read` مقيدة بسلسلة `guardian → student_guardians → student`. ولي الأمر لا يقرأ طالباً آخر في نفس المدرسة مهما كان Scope.

**لا يملك أي `*.export`** — قرار v1 صريح: العرض داخل التطبيق فقط بلا تحميل أو طباعة (`PLAN_v3.md` §7.8).

**G1 (2026-09-23):** لا `profile.update` لولي الأمر. تغيير الهاتف مسار OTP في FastAPI، وكلمة المرور عبر Supabase Auth، وبقية بياناته الشخصية تعدّلها المدرسة (`PLAN_v3.md` §7.8). قراءة الملف الذاتي لا تحتاج صلاحية (`RLS_MODEL_v1.md` §10.1).

### 4.10 `student` — 4 صلاحيات

| المجموعة | الصلاحيات |
|---|---|
| Schools | `school.read` |
| Identity | `profile.read` |
| Students | `student.read` |
| Enrollment | `enrollment.read` |

**تضييق إلزامي:** `student.read` و`enrollment.read` على **سجله هو فقط** عبر `enrollments`. قراءة فقط (`PLAN_v3.md` §2).

**لا يملك أي `*.export`.**

---

## 5. ملخص التوزيع

> **✅ تصحيح M23 (2026-09-26):** الأعداد هنا وفي عناوين §4 كانت متقادمة (سابقة لـK2 و G1) ولا تطابق القوائم الصريحة. **القوائم هي المرجع** (قرار 2026-09-26) — وهي مطابقة حرفياً لكتالوج Matrix §4 (73 = قائمة `tenant_admin` الـ71 + `tenant.create` + `tenant.suspend`). `group_manager` و`school_admin` بقاعدتي الطرح في §4.2 و§4.3. المجموع 255 ربطاً؛ `23_reference_data` يثبت كل مجموعة حرفياً.
>
> **نتيجة T8 على الأدوار المبذورة (موثّقة، لا قرار جديد):** `group_manager` **لا يستطيع إسناد `school_admin`** — لأن الأخير يحمل `security.manage`/`security.export` التي لا يملكها. `tenant_admin` يسند الأدوار التسعة الأخرى كلها؛ `group_manager` و`school_admin` يسندان `secretary`, `accountant`, `teacher`, `counselor`, `bus_supervisor`, `guardian`, `student`.

| الدور | عدد الصلاحيات | `sensitive_read` | `export` |
|---|---:|:---:|:---:|
| `tenant_admin` | 71 | ✅ student + guardian | ✅ كامل |
| `group_manager` | 62 | ✅ student + guardian | ✅ عدا security |
| `school_admin` | 59 | ✅ student + guardian | ✅ كامل |
| `secretary` | 19 | ❌ | ❌ |
| `accountant` | 11 | ❌ | ❌ |
| `teacher` | 11 | ❌ | ❌ |
| `counselor` | 10 | ✅ student فقط | ❌ |
| `bus_supervisor` | 2 | ❌ | ❌ |
| `guardian` | 6 | ❌ | ❌ |
| `student` | 4 | ❌ | ❌ |

**G1 (2026-09-23):** `profile.update` لم تعد لأي دور غير `tenant_admin`/`group_manager`/`school_admin`. معناها الآن «تعديل profiles الآخرين ضمن نطاق يحتوي عضويتهم» (`can_manage_membership`)، ولا يوجد تعديل ذاتي. `profile.read` باقية للجميع ومعناها «رؤية profiles ضمن النطاق»؛ ولي الأمر والطالب بلا نطاقات فلا يرون إلا أنفسهم عبر مسار الذات الذي لا يحتاج صلاحية.

**قراءة الجدول:** أربعة أدوار فقط من عشرة تملك `sensitive_read`، وثلاثة تملك `export`. هذا هو الأثر الملموس لقاعدة فصل `read` عن `export` وعن `sensitive_read`.

---

## 6. Platform Admin Authorization — قرار C3 المعتمد (2026-09-22)

`AUTHORIZATION_MATRIX_v1.md` §3 و§15 بند 6 يوجبان: **لا وصول ضمني لـPlatform Admin إلى بيانات Tenant، والوصول الحساس يحتاج Permission صريحة + Audit.**

لكن ERD §4.4 و`DATA_DICTIONARY_v1.md` §2.5–2.6 يعرّفان `platform_admin_roles` و`platform_admin_assignments` **بلا أي ربط بجدول `permissions`**. النتيجة أن `app.is_platform_admin()` تصبح boolean بلا تفصيل، وهو ما يقود عملياً إلى أحد أمرين — كلاهما مرفوض:

- منح شامل ضمني (يخالف §15 بند 6)، أو
- ترميز القدرات في كود التطبيق (يخالف "Frontend/Backend ليس مصدر الصلاحية").

**القرار المعتمد:** جدول `platform_admin_role_permissions (platform_admin_role_id, permission_id)` يعيد استخدام كتالوج `permissions` نفسه.

```text
platform_admin_roles
        ↓
platform_admin_role_permissions
        ↓
permissions
```

القاعدة تصبح:

```text
Platform Admin → Role → Permission + Platform-level scope
```

وليس:

```text
is_platform_admin = true → full access
```

**النتائج الملزمة:**

| البند | الأثر |
|---|---|
| `app.is_platform_admin()` | اختبار **هوية/عضوية فقط**؛ لا يمنح وحده أي صلاحية تشغيلية |
| `app.has_permission()` / `app.has_platform_permission()` | **سياقان منفصلان (G10، 2026-09-23):** الأولى لسياق Tenant حصراً، والثانية لسياق Platform حصراً؛ السياق يُحدَّد أولاً من `auth_identities`. لا `OR` بين المسارين على مستوى الصلاحية |
| Platform Admin محدود الصلاحيات | ممكن — دور دعم يقرأ metadata بلا بيانات عملاء |
| البيانات الحساسة | لا وصول تلقائي؛ يلزم امتلاك الـPermission المناسب |
| Scope | Platform-level، **منفصل تماماً** عن Group/School scopes الخاصة بمستخدمي Tenant؛ `can_access_group/school` لا تُرجع true لـPlatform Admin |
| Audit | كل عملية قابلة للتسجيل بنفس آلية Tenant |

**بذرة دور `platform_admin`:** `tenant.read`, `tenant.create`, `tenant.update`, `tenant.suspend`, `group.read`, `group.create`, `school.read`, `school.create`, `audit.read`.
**بلا** `student.*` ولا `guardian.*` ولا `staff.*` ولا أي `*.export` لبيانات العملاء — تلك تحتاج دوراً منفصلاً بمسار اعتماد وتدقيق (المرحلة 13).

> `tenant.create` غير موجود في كتالوج §4 الحالي ويلزم إضافته مع هذا الجدول.

---

## 7. دين تقني مسجَّل

| # | البند | يُسدَّد في |
|---|---|---|
| D1 | `teacher.student.read` مضيَّق بـschool scope فقط حتى تُنشأ `teaching_assignments` | المرحلة 3 |
| D2 | `counselor.student.sensitive_read` بلا تضييق بتصنيف الملاحظة | المرحلة 4 |
| D3 | `bus_supervisor` بلا صلاحيات تشغيلية | المرحلة 7 |
| D4 | `accountant.audit.read` بلا تضييق مالي | المرحلة 7 |
| D5 | ~~`platform_admin_role_permissions` غير موجود~~ — **حُسم 2026-09-22 (§6)**، يُنفَّذ في Gate C3 | ✅ |

**قاعدة:** كل بند هنا يُذكر في اختبار pgTAP معلَّم `TODO` يفشل عمداً عند وصول مرحلته، حتى لا يُنسى.

---

## 8. أثر التنفيذ

### 8.1 على Gate C5

```text
1. INSERT permissions      ← 73 صفاً (§2)، is_system = true
2. INSERT roles            ← 10 أدوار، platform_tenant_id IS NULL, is_system = true
3. INSERT role_permissions ← الخريطة في §4
```

بذر الأدوار بـ`platform_tenant_id IS NULL` يجعلها قوالب نظام مشتركة، والمدرسة تنشئ أدواراً مخصصة بنسخها (`DATA_DICTIONARY_v1.md` §2.9، قيد `is_system = (platform_tenant_id IS NULL)`).

### 8.2 على A3

كل مفتاح في §2 و§4 **مجمَّد**. سياسات A3 تكتب `app.has_permission('student.read')` بثقة أن الاسم لن يتغير. أي مفتاح جديد بعد هذه النقطة يحتاج قرار في سجل `PLAN_v3.md` §9.

### 8.3 اختبارات مطلوبة (تُضاف إلى Gate E)

| الاختبار | يثبت |
|---|---|
| `secretary` بلا `student.export` لا يصدّر رغم امتلاكه `student.read` | Matrix §8 |
| `teacher` لا يقرأ طالباً خارج تكليفه | Matrix §10 / D1 |
| `guardian` لا يقرأ طالباً غير مرتبط به في نفس المدرسة | Matrix §9 |
| `student` لا يقرأ إلا سجله | §4.10 |
| `bus_supervisor` لا يقرأ أي طالب | §4.8 |
| `group_manager` لا ينشئ Role | Matrix §13 |
| لا دور Tenant يملك `tenant.suspend` | K3 |

---

## 9. حالة A2

| البند (Matrix §17) | الحالة |
|---|---|
| Final seed Role → Permission mappings | ✅ §4 |
| Exact permission catalog for all modules | ⬜ مؤجل بقصد — Foundation مثبَّت (§2)، والباقي محجوز الأسماء (§2.2) |
| SQL/RLS implementation and pgTAP tests | ⬜ Gates C/D/E |

**الخطوة التالية:** A2.3 — تطبيق K1–K3 على `AUTHORIZATION_MATRIX_v1.md`، ثم **A3 — RLS Model**.
