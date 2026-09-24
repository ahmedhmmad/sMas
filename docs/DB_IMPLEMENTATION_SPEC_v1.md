# Database Implementation Specification v1 — Foundation (Gate B)

**التاريخ:** 2026-09-23
**الحالة:** ✅ **Gate B مغلق (2026-09-23)** — G1–G10 معتمدة. التالي: Gate I / M00
**المرجع:** A1–A5 المعتمدة: `ERD_CORE_v1.md` + `docs/DATA_DICTIONARY_v1.md` + `AUTHORIZATION_MATRIX_v1.md` + `docs/ROLE_PERMISSION_SEED_v1.md` + `docs/RLS_MODEL_v1.md`

> **الهدف:** مواصفة تتحول إلى migrations **دون اتخاذ أي قرار معماري أثناء الكتابة**. كل قرار لم يُحسم بعد مُعلَّم **⏳ G#** ومجمَّع في §11. كل افتراض تقني يحتاج تحققاً عملياً مُعلَّم **🔬 V#** ومجمَّع في §12.

---

## 0. قاعدة اختيار آلية الإنفاذ

لكل invariant تُختار **أول آلية قادرة** في هذا الترتيب. الانتقال إلى آلية أدنى يحتاج سبباً مكتوباً في §3.

| # | الآلية | تُستعمل حين |
|---|---|---|
| 1 | `NOT NULL` / `CHECK` | القاعدة داخل صف واحد |
| 2 | `UNIQUE` (كامل أو جزئي، `NULLS NOT DISTINCT` عند الحاجة) | تفرد |
| 3 | `FK` / FK مركّب | ارتباط، بما فيه سلامة Tenant |
| 4 | `EXCLUDE` | عدم تداخل (زمني أو غيره) |
| 5 | عمود محسوب `GENERATED` + FK مركّب | قاعدة عابرة للجداول قابلة للتعبير بمفتاح مشتق |
| 6 | `GRANT` على مستوى العمود | ما **لا يجوز لأي مستخدم نهائي** كتابته مباشرة — موحّد لكل دور DB |
| 7 | RLS | **رؤية الصفوف والتفويض فقط** — لا invariants بيانات |
| 8 | Trigger | القاعدة تعتمد على **هوية الفاعل**، أو تجميع عبر صفوف، أو ختم، أو إنشاء صف تابع إلزامي |
| 9 | دالة SQL `SECURITY DEFINER` مغلقة | عملية ذرية متعددة الجداول، أو انتقال حالة محكوم بصلاحية بعينها |
| 10 | FastAPI | أنظمة خارجية (Auth API، OTP، WhatsApp)، تسجيل القراءات، التصدير، سير العمل |

**قاعدتان لا تُخرقان:**
- RLS لا تُستعمل لفرض invariant لا يخص رؤية الصف أو تفويض الفاعل.
- `GRANT` العمود **موحّد لكل مستخدمي `authenticated`**؛ لا يستطيع التمييز بين من يملك `student.archive` ومن لا يملكها. التمييز بالصلاحية على مستوى العمود = دالة انتقال حالة (آلية 9). هذا يصحّح افتراضاً خاطئاً في `RLS_MODEL_v1.md` §12.2 (انظر §4.6).

---

## B1 — مطابقة ERD النهائية

### 1.1 الجداول — 28 (+1 معلّق على G10)

| # | الجدول | الملكية | الحالة في ERD قبل B1 |
|---|---|---|---|
| 1 | `platform_tenants` | P | ✅ |
| 2 | `groups` | T | ✅ |
| 3 | `schools` | T | ⚠️ ينقصه `is_standalone`, `scope_owner_id` |
| 4 | `system_users` | P | ✅ |
| 5 | `platform_admin_roles` | P | ✅ |
| 6 | `platform_admin_role_permissions` | P | ❌ **غائب** رغم اعتماد C3 |
| 7 | `platform_admin_assignments` | P | ✅ |
| 8 | `profiles` | T | ✅ بعد A4 |
| 9 | `memberships` | T | ✅ |
| 10 | `roles` | T/P | ✅ |
| 11 | `permissions` | P | ✅ |
| 12 | `role_permissions` | يتبع roles | ✅ |
| 13 | `membership_roles` | يتبع memberships | ⚠️ ينقصه `platform_tenant_id`, `role_owner_key` (§3) |
| 14 | `membership_scopes` | يتبع memberships | ✅ |
| 15 | `staff` | I | ✅ |
| 16 | `staff_school_assignments` | S | ✅ |
| 17 | `families` | I | ✅ |
| 18 | `identity_scopes` | T | ⚠️ مذكور في 4.15 والمخطط فقط، **بلا قسم تعريف** |
| 19 | `students` | I | ✅ بعد A4 |
| 20 | `guardians` | I | ✅ |
| 21 | `student_guardians` | يتبع students | ✅ |
| 22 | `enrollments` | S | ⚠️ ✅ G3 |
| 23 | `academic_years` | S | ✅ |
| 24 | `terms` | S | ⚠️ ينقصه `year_start_date`, `year_end_date` (§3) |
| 25 | `stages` | S | ✅ |
| 26 | `grade_levels` | S | ✅ |
| 27 | `sections` | S | ✅ |
| 28 | `audit_log` | A | ✅ |
| (29) | `auth_identities` | P | ✅ G10 |

### 1.2 ما صُحِّح في ERD ضمن B1

| البند | التصحيح |
|---|---|
| `platform_admin_role_permissions` | أُضيف §4.4 + المخطط (قرار C3) |
| `identity_scopes` | قسم تعريف مستقل §4.15a |
| §10 ترتيب التنفيذ | استُبدل بإشارة إلى B9/B10 من هذه المواصفة |

---

## B2 — مطابقة Data Dictionary النهائية

| # | عدم الاتساق | التصحيح |
|---|---|---|
| D1 | خريطة الملكية §1 مرقّمة `16b`, `5b` خارج الترتيب | أعيد ترقيمها 1–28 |
| D2 | §0.6 قائمة آباء `UNIQUE (id, platform_tenant_id)` تنقصها `identity_scopes` | أُضيفت؛ وأُضيفت قائمة المفاتيح المركّبة الإضافية (§4.2 هنا) |
| D3 | §0.7 قائمة `CASCADE` تنقصها `platform_admin_role_permissions` | أُضيفت |
| D4 | `schools.is_standalone` معرَّف داخل قسم `identity_scopes` لا في قسم `schools` | نُقل إلى §2.3 |
| D5 | §2.5.1 ما زال يصف `tenant.create` كمطلوب و«مقترح» | حُدِّث: معتمد (C3/K4) |
| D6 | `families`, `guardians` تحمل `status = archived` بلا قيد يربطه بـ`archived_at` | أُضيف `CHECK ((status = 'archived') = (archived_at IS NOT NULL))` كبقية الجداول |
| D7 | §7 «تغطية 26/26» | 28/28 |
| D8 | `membership_scopes`: `UNIQUE (membership_id, scope_type, group_id, school_id)` | **خطأ فعلي:** Postgres يعامل `NULL` كقيم مختلفة، فالقيد **لا يمنع** تكرار نطاق `tenant` (العمودان NULL) ولا تكرار نطاق `group`. التصحيح: `UNIQUE NULLS NOT DISTINCT` (PG15+) |
| D9 | `memberships`: التفرد `(platform_tenant_id, profile_id)` | بما أن الـprofile في Tenant واحد (O1)، أُضيف `UNIQUE (profile_id)` صراحةً — العلاقة 1:1 |
| D10 | `effective_to >= effective_from` في ثلاثة جداول | `>` — انظر B6 (فترات نصف مفتوحة) |
| D11 | §4 قائمة الـtriggers | استُبدلت بالقائمة النهائية في §3.3 هنا |

---

## B3 — القيود والفهارس النهائية

### 3.1 سجل الـInvariants وآلية كل منها

**Tenancy**

| # | Invariant | الآلية | ملاحظة |
|---|---|---|---|
| I1 | `tenant_code` فريد عالمياً | UNIQUE | |
| I2 | `group_code`/`school_code`/`slug` فريدة داخل Tenant | UNIQUE مركّب | |
| I3 | صيغ الأكواد والـslug | CHECK | |
| I4 | `status` ↔ `archived_at`/`suspended_at` | CHECK | |
| I5 | مدرسة → مجموعة من نفس Tenant | FK مركّب | |
| I6 | الأكواد ثابتة | GRANT (لا UPDATE على العمود) | service role موثوق |
| I7 | نطاق هوية واحد على الأكثر لكل Group/مدرسة مستقلة | UNIQUE جزئي | |
| I8 | نطاق هوية **واحد على الأقل** لكل Group/مدرسة مستقلة | **Trigger T9** | وجود صف تابع لا يُفرض إعلانياً إلا بـFK دائري؛ ✅ G9 |
| I9 | مدرسة داخل Group لا تملك نطاقاً خاصاً | GENERATED `is_standalone` + FK مركّب | |

**Identity & AuthZ**

| # | Invariant | الآلية | ملاحظة |
|---|---|---|---|
| I10 | `auth_user_id` فريد عالمياً في `profiles` (O1) | UNIQUE | |
| I11 | Auth user إما Tenant profile أو System user، لا الاثنان | ✅ **G10**: جدول `auth_identities` + FK مركّب (إعلاني، بلا race) — البديل trigger يحتاج قفلاً | انظر §4.4 لماذا هذا أمني لا تنظيمي |
| I12 | Profile ↔ Membership 1:1 | UNIQUE (`profile_id`) | D9 |
| I13 | شكل `membership_scopes` | CHECK | |
| I14 | عدم تكرار النطاق | UNIQUE NULLS NOT DISTINCT | D8 |
| I15 | النطاق من Tenant العضوية | FK مركّب ×3 | |
| I16 | الدور المُسنَد: دور نظام أو من Tenant العضوية | **GENERATED `roles.owner_key` + FK مركّب + CHECK** | **يُلغي trigger T1** — §3.2 |
| I17 | `is_system ↔ platform_tenant_id IS NULL` | CHECK | |
| I18 | `permissions.code = resource.operation` | CHECK | |
| I19 | صلاحيات الدور المُسنَد/المُعدَّل ⊆ صلاحيات الفاعل | **Trigger T8** | يعتمد على هوية الفاعل — لا بديل إعلاني |
| I20 | النطاق الممنوح ⊆ نطاق الفاعل | RLS `WITH CHECK` | تفويض |
| I21 | الفاعل يملك سلطة على العضوية الهدف | RLS (`app.can_manage_membership`) | **جديد** — §4.4 F4 |

**People**

| # | Invariant | الآلية |
|---|---|---|
| I22 | `employee_code` فريد داخل Tenant | UNIQUE |
| I23 | حساب ↔ موظف/ولي أمر 1:1 | UNIQUE جزئي |
| I24 | مدرسة أساسية نشطة واحدة للموظف | UNIQUE جزئي |
| I25 | هاتف ولي الأمر فريد داخل Tenant + E.164 | UNIQUE + CHECK |
| I26 | ولي أمر أساسي نشط واحد للطالب | UNIQUE جزئي |
| I27 | الطالب/ولي الأمر/الأسرة/النطاق من نفس Tenant | FK مركّب |
| I28 | `official_id` فريد داخل نطاق الهوية | UNIQUE جزئي |
| I29 | الطالب يحمل معرفاً واحداً على الأقل | CHECK |
| I30 | `student_profile_id` 1:1 إلزامي | NOT NULL + UNIQUE |
| I31 | `temporary_id` يولّده النظام ولا يُدخَل يدوياً | يُولَّد داخل دالة الإنشاء (§5) + GRANT (لا INSERT/UPDATE على العمود) + CHECK صيغة |
| I32 | `full_name` | GENERATED |

**Academic**

| # | Invariant | الآلية |
|---|---|---|
| I33 | سنة نشطة واحدة لكل مدرسة | UNIQUE جزئي |
| I34 | لا تداخل بين سنوات المدرسة | EXCLUDE |
| I35 | الفصل داخل حدود السنة | **FK مركّب يحمل تاريخي السنة `ON UPDATE CASCADE` + CHECK** — **يُلغي trigger T4** — §3.2 |
| I36 | لا تداخل بين فصول السنة | EXCLUDE |
| I37 | المرحلة/الصف/الشعبة من نفس المدرسة | FK مركّب |

**Enrollment**

| # | Invariant | الآلية |
|---|---|---|
| I38 | تسجيل نشط واحد لكل طالب/مدرسة/سنة | UNIQUE جزئي |
| I39 | السنة والصف والشعبة متسقة | **FK مركّب واحد إلى `sections (id, school_id, academic_year_id, grade_level_id)`** — **يُلغي trigger T3** |
| I40 | المدرسة داخل نطاق هوية الطالب | ✅ **G3**: GENERATED owner keys + FK مركّبان |
| I41 | لا تداخل زمني في تسجيلات الطالب | ✅ **G6**: EXCLUDE |
| I42 | `status` ↔ `effective_to` | CHECK — B6 |
| I43 | سعة الشعبة وسياسة الجنس | FastAPI / المرحلة 4 — تجميع عددي + override إداري |

**Audit / Stamping**

| # | Invariant | الآلية |
|---|---|---|
| I44 | `audit_log` غير قابل للتعديل أو الحذف | REVOKE + **Trigger T5** |
| I45 | كل تغيير يُسجَّل | **Trigger T7** |
| I46 | `created_by`/`updated_by` لا يُزوَّران | **Trigger T6** (يكتب القيمة ويتجاهل ما يرسله العميل) |

### 3.2 التحويلات من Trigger إلى إعلاني

**T1 → I16 (`membership_roles`):**

```sql
-- roles
owner_key uuid GENERATED ALWAYS AS
  (coalesce(platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)) STORED,
UNIQUE (id, owner_key)

-- membership_roles
platform_tenant_id uuid NOT NULL,
role_owner_key     uuid NOT NULL,
FOREIGN KEY (membership_id, platform_tenant_id) REFERENCES memberships (id, platform_tenant_id),
FOREIGN KEY (role_id, role_owner_key)           REFERENCES roles (id, owner_key),
CHECK (role_owner_key IN (platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid))
```

الدور إما نظامي (مفتاح صفري) أو من Tenant العضوية — ولا ثالث. الكاتب يزوّد `role_owner_key`؛ إن أخطأ رفضه المحرك.

**T3 → I39 (`enrollments`):**

```sql
-- sections
UNIQUE (id, school_id, academic_year_id, grade_level_id)

-- enrollments: FK واحد يحل محل الثلاثة السابقة
FOREIGN KEY (section_id, school_id, academic_year_id, grade_level_id)
  REFERENCES sections (id, school_id, academic_year_id, grade_level_id)
```

الشعبة نفسها مرتبطة بالسنة والصف بـFKs مركّبة، فالاتساق متعدٍّ. تُحذف FKs المباشرة من `enrollments` إلى `academic_years` و`grade_levels` (زائدة).

**T4 → I35 (`terms`):**

```sql
-- academic_years
UNIQUE (id, school_id, start_date, end_date)

-- terms
year_start_date date NOT NULL,
year_end_date   date NOT NULL,
FOREIGN KEY (academic_year_id, school_id, year_start_date, year_end_date)
  REFERENCES academic_years (id, school_id, start_date, end_date)
  ON UPDATE CASCADE,
CHECK (start_date >= year_start_date AND end_date <= year_end_date)
```

تعديل تاريخي السنة ينتشر إلى الفصول، فيُعاد تقييم الـCHECK — ويُرفض تعديل السنة إن أخرج فصلاً عن حدودها. 🔬 V3.

### 3.3 القائمة النهائية للـTriggers — 5 (+1 بديل)

| # | الـTrigger | على | لماذا لا يوجد بديل إعلاني |
|---|---|---|---|
| **T5** | رفض UPDATE/DELETE/**TRUNCATE** | `audit_log` (صف + جملة) | REVOKE لا يمنع مالك الجدول؛ و`TRUNCATE` لا يطلق trigger الصف |
| **T6** | ختم `created_*`/`updated_*` | كل الجداول ذات الأعمدة | لا «DEFAULT عند UPDATE» في Postgres؛ ومنع التزوير |
| **T7** | التقاط التدقيق | 27 جدولاً | — |
| **T8** | صلاحيات الدور ⊆ صلاحيات الفاعل | `membership_roles` (INSERT/DELETE)، `role_permissions` (INSERT/DELETE) | يعتمد على هوية الفاعل |
| **T9** | إنشاء نطاق الهوية تلقائياً | `groups` (INSERT)، `schools` (INSERT حين `group_id IS NULL`) | وجود صف تابع ✅ G9 |
| ~~T1–T4~~ | — | — | **ألغيت: T1/T3/T4 أصبحت إعلانية، T2 بقرار A4** |
| (T10) | حصرية الهوية | — | بديل G10 فقط إن رُفض |

### 3.4 الفهارس

**القاعدة:** كل FK له فهرس يبدأ بأعمدته. لا فهارس إضافية إلا ما تطلبه سياسة RLS أو دالة مساعدة.

| الجدول | الفهرس | السبب |
|---|---|---|
| `membership_scopes` | `(membership_id, scope_type)` | كل `can_access_*` |
| `membership_scopes` | `(school_id)`, `(group_id)` | FK + الاتجاه العكسي |
| `memberships` | `(profile_id) WHERE status='active'` | `has_permission` |
| `membership_roles` | `(role_id)` | T8 |
| `role_permissions` | `(permission_id)` | عكسي |
| `enrollments` | `(student_id)` | `student_in_scope` — **حرج** |
| `enrollments` | `(school_id, academic_year_id, section_id)` | الكشوف |
| `student_guardians` | `(guardian_id, student_id)` | مسار ولي الأمر |
| `staff_school_assignments` | `(staff_id)`, `(school_id, status)` | `staff_in_scope` |
| `students` | `(student_profile_id)`, `(family_id)`, `(identity_scope_id, official_id)` | |
| `guardians` / `staff` | `(profile_id)` | مسارا الذات |
| `audit_log` | `(platform_tenant_id, created_at DESC)`, `(entity_type, entity_id)` | |

---

## B4 — الملكية والـFK والتفرد وسلامة التفويض

### 4.1 الملكية — 28/28

كما في B1 §1.1. لا جدول بلا ملكية معلنة.

### 4.2 سجل المفاتيح المركّبة المرجعية

| الجدول الأب | المفتاح المرجعي | يستعمله |
|---|---|---|
| `groups`, `schools`, `profiles`, `memberships`, `staff`, `students`, `guardians`, `families`, `identity_scopes` | `(id, platform_tenant_id)` | سلامة Tenant |
| `roles` | `(id, owner_key)` | `membership_roles` |
| `academic_years` | `(id, school_id)`, `(id, school_id, start_date, end_date)` | `sections`, `terms` |
| `stages`, `grade_levels` | `(id, school_id)` | |
| `sections` | `(id, school_id, academic_year_id, grade_level_id)` | `enrollments` |
| `schools` | `(id, is_standalone)` | `identity_scopes` |
| `schools` | `(id, scope_owner_id)` ✅ G3 | `enrollments` |
| `identity_scopes` | `(id, owner_id)` ✅ G3 | `enrollments` |
| `students` | `(id, identity_scope_id)` ✅ G3 | `enrollments` |

### 4.3 سلوك الحذف

`ON DELETE RESTRICT` افتراضياً. `CASCADE` على جداول الربط الصرفة: `role_permissions`, `membership_roles`, `membership_scopes`, `platform_admin_role_permissions`.

**DELETE على مستوى التطبيق:** لا توجد سياسة DELETE إلا على `membership_roles` و`membership_scopes` و`role_permissions` (أدوار مخصصة) — ✅ **G2**. بدونها **لا يستطيع أحد سحب دور أو نطاق** عبر النظام، وهي عملية أمنية أساسية.

### 4.4 سلامة التفويض — تصحيحات A3 ⚠️

هذه ثغرات في `RLS_MODEL_v1.md` كما اعتُمد، لا قرارات جديدة: كلها خروج عن قواعد معتمدة في Matrix §11 و§13 و`CLAUDE.md` §1.1 بند 5. **صُحِّحت في `RLS_MODEL_v1.md` مباشرةً.**

| # | الخطورة | الثغرة | التصحيح |
|---|---|---|---|
| **F1** | 🔴 حرجة | `can_access_tenant` تعني «عضو نشط في الـTenant» لا «يملك نطاق Tenant». بما أن `school_admin` يملك `scope.assign`، يستطيع عبر فرع `scope_type='tenant'` منح **نفسه** نطاق Tenant كاملاً. و`group_manager` يستطيع إنشاء مدرسة في **أي** مجموعة عبر فرع `OR can_access_tenant` في سياسة `schools` | `can_access_tenant` = وجود `membership_scope` من نوع `tenant` (مطابق لـMatrix §11). العزل المجرد = `platform_tenant_id = (select app.current_tenant_id())` |
| **F2** | 🔴 | `profiles` SELECT/UPDATE = Tenant + `profile.read/update` بلا نطاق. **كل الأدوار العشرة** تملك الصلاحيتين في الـseed، فولي الأمر **يقرأ كل profiles الـTenant** ويعدّل أسماءهم | الرؤية عبر `app.can_see_membership()`؛ الصف الذاتي بلا صلاحية؛ لا تعديل ذاتي ✅ G1 |
| **F3** | 🟠 | `memberships` SELECT = Tenant + `membership.read` بلا نطاق → `group_manager` يرى عضويات المجموعات الأخرى | `app.can_see_membership()` |
| **F4** | 🔴 | `membership_roles` بلا فحص للعضوية الهدف. `school_admin` في A يسند `school_admin` لعضوية نطاقها B → **يصعّد غيره إلى مدرسة لا سلطة له عليها**. T8 لا يلتقط ذلك (الصلاحيات ⊆ صلاحياته) | `app.can_manage_membership()`: كل نطاقات العضوية الهدف ⊆ نطاقات الفاعل |
| **F5** | 🔴 | T8 على `membership_roles` فقط. **مسار التفاف:** يُسند الفاعل لنفسه دوراً مخصصاً **فارغاً** (يجتاز T8)، ثم يضيف إليه صلاحيات لا يملكها عبر `role_permissions` — بلا أي فحص | T8 يغطي `role_permissions` أيضاً، وINSERT و DELETE في الجدولين (Matrix §13 بنده الأخير نصاً) |
| **F6** | 🔴 | **9 من 28 جدولاً بلا أي سياسة** في A3: `staff`, `guardians`, `families`, `student_guardians`, `identity_scopes`, `system_users`, `platform_admin_roles`, `platform_admin_assignments`, `platform_admin_role_permissions`. مع `FORCE RLS` = النظام معطَّل، أو تُكتب سياسات ارتجالية أثناء الـmigration | أُضيفت كلها — `RLS_MODEL_v1.md` §10.4–§10.6 |
| **F10** | 🟠 | `audit_log`: الصفوف بلا `school_id` مرئية لكل من يملك `audit.read` في الـTenant. جداول الهوية بلا `school_id` → **كل تعديلات الطلاب في كل المدارس** مرئية للمحاسب (يملك `audit.read`) مع `old_values`/`new_values` | الرؤية = إمكانية رؤية الكيان نفسه + `audit.read` |
| **F11** | 🔴 | `audit_log`: Platform Admin بـ`audit.read` يرى **كل** صفوف التدقيق، وفيها بيانات الطلاب كاملة في `old_values`/`new_values` → التفاف كامل على قرار C3 | Platform Admin يرى تدقيق الكيانات platform-level فقط |

**لماذا G10 أمني (I11):** الصيغة الأولى لـC3 عرّفت `has_permission()` توحّد المسارين بـ`OR`. لو امتلك حساب واحد profile وsystem_user معاً، فإن `tenant.read` الممنوحة له من دور Tenant تُرضي سياسة Platform Admin → يقرأ **كل** الـTenants. أحمد مالك مدرسة التجربة ومشغّل المنصة معاً — الحالة واقعية لا نظرية.

**G10 كما اعتُمد (طبقتان):**
1. **حصرية الهوية إعلانياً:** `auth_identities (auth_user_id PK, kind)` — لكل حساب سياق واحد.
2. **فصل صريح للسياقين، لا `OR` على مستوى الصلاحية:** `app.current_security_context()` يحدد السياق أولاً؛ `app.has_permission()` لسياق Tenant حصراً، و`app.has_platform_permission()` لسياق Platform حصراً. سياسات كل سياق تستعمل دالتها وحدها (`RLS_MODEL_v1.md` §2).

الطبقة الثانية تحمي حتى لو فشلت الأولى: صلاحية Tenant لا تُرضي سياسة Platform بأي حال.

### 4.5 تغطية RLS — 28/28

| الجدول | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `platform_tenants` | tenant scope + `tenant.read` / PA | PA `tenant.create` | `tenant.update` | — |
| `groups` | `can_access_group` + `group.read` / PA | tenant scope + `group.create` / PA | `group.update` | — |
| `schools` | `can_access_school` + `school.read` / PA | group scope أو tenant scope + `school.create` / PA | `school.update` | — |
| `identity_scopes` | نطاق مرئي + `school.read` | T9 فقط | — | — |
| `system_users` | الذات (PA) | service | service | — |
| `platform_admin_roles` / `_role_permissions` | PA | service | service | — |
| `platform_admin_assignments` | الذات (PA) | service | service | — |
| `profiles` | الذات / `profile.read` + `can_see_membership` | دالة إنشاء | `profile.update` + `can_manage_membership` | — |
| `memberships` | الذات / `membership.read` + `can_see_membership` | دالة إنشاء | دالة حالة | — |
| `membership_roles` | كالعضوية | `role.assign` + `can_manage_membership` + T8 | — | ✅ G2 |
| `membership_scopes` | كالعضوية | `scope.assign` + نطاق ⊆ الفاعل | — | ✅ G2 |
| `roles` | نظام أو Tenant + `role.read` | tenant scope + `role.create` | tenant scope + `role.update` | — |
| `permissions` | `permission.read` | migration | — | — |
| `role_permissions` | كالدور | tenant scope + `role.update` + T8 | — | ✅ G2 |
| `staff` | الذات / `staff.read` + `staff_in_scope` | دالة إنشاء | `staff.update` + `staff_in_scope` | — |
| `staff_school_assignments` | `can_access_school` + `staff.read` | `staff.assign` | `staff.assign` | — |
| `families` | `family.read` + `family_in_scope` / ولي الأمر | دالة إنشاء | `family.update` + `family_in_scope` | — |
| `students` | المسارات الثلاثة | دالة إنشاء | `student.update` + `student_in_scope` | — |
| `guardians` | الذات / `guardian.read` + `guardian_in_scope` | دالة إنشاء | `guardian.update` + `guardian_in_scope` | — |
| `student_guardians` | `guardian.read` + `student_in_scope` / الذات | `guardian.link` + `student_in_scope` | `guardian.link` | — |
| `enrollments` | `can_access_school` + `enrollment.read` / ولي الأمر / الذات | `enrollment.create` + `can_access_school` | `enrollment.update` | — |
| `academic_years`..`sections` | `can_access_school` + `<res>.read` | `<res>.manage`/`.create` | نفسه | — |
| `audit_log` | F10/F11 | T7 / service | — | — |

PA = سياق Platform (`app.has_platform_permission(...)`) — G10. النص الكامل في `RLS_MODEL_v1.md`.

### 4.6 سجل صلاحيات الأعمدة (GRANT لـ`authenticated`)

**القاعدة:** ما لا يرد هنا لا يُكتب مباشرة من أي مستخدم. أعمدة `status`/`archived_at` مستبعدة حيث تحكم الانتقال صلاحية مستقلة (`.archive`, `.activate`, `.close`, `.end`, `.unlink`) — تُغيَّر بدوال §5.3.

| الجدول | INSERT | UPDATE |
|---|---|---|
| `platform_tenants` | — | `name` |
| `groups` | `platform_tenant_id, group_code, name` | `name` |
| `schools` | `platform_tenant_id, group_id, school_code, name, slug, timezone` | `name, slug, timezone` |
| `profiles` | — | `display_name` |
| `memberships` | — | — |
| `membership_roles` | كل الأعمدة عدا `granted_at, granted_by` | — |
| `membership_scopes` | كل الأعمدة عدا `created_*` | — |
| `roles` | `platform_tenant_id, code, name, description` | `name, description, status` |
| `role_permissions` | الكل | — |
| `staff` | — | الاسم الرباعي، `national_id, phone_e164, email, gender, birth_date, hire_date` |
| `staff_school_assignments` | كل أعمدة الأعمال | `job_title, is_primary, status, effective_to` |
| `families` | — | `family_code, family_name, address` |
| `students` | — | الاسم الرباعي، `gender, birth_date, nationality, family_id, official_id, official_id_type` |
| `guardians` | — | الاسم الرباعي، `alt_phone_e164, email, national_id, residence_country` |
| `student_guardians` | كل أعمدة الأعمال عدا `status, effective_to` | `relationship_type, is_primary, receives_whatsapp, can_pickup` |
| `enrollments` | كل أعمدة الأعمال عدا `status, effective_to, withdrawal_reason` | `enrollment_no` |
| `academic_years` | `school_id, name, start_date, end_date` | `name, start_date, end_date` |
| `terms`, `stages`, `grade_levels`, `sections` | كل أعمدة الأعمال | كل أعمدة الأعمال |

**ثوابت لا تُعدَّل إطلاقاً من المستخدم:** كل الأكواد، `students.identity_scope_id`, `students.student_profile_id`, `students.temporary_id`, `schools.group_id` (الانضمام لمجموعة = إجراء دمج §5.4)، `guardians.phone_e164` (مسار OTP في FastAPI — `PLAN_v3.md` §7.8)، حقول أمان ولي الأمر، `platform_tenant_id` في كل جدول.

**تصحيح `RLS_MODEL_v1.md` §12.2 (N4/N6):** كان الحل المقترح لـ`sensitive_read` وفصل `.archive` عن `.update` هو `GRANT` على الأعمدة. **هذا لا يعمل**: صلاحيات الأعمدة لكل دور DB (`authenticated`) لا لكل صلاحية تطبيق. الحل الصحيح: N6 → دوال انتقال حالة (§5.3)؛ `sensitive_read` → ✅ G5.

---

## B5 — حدود المعاملات

### 5.0 Controlled DB Functions — العقد الملزم (قرار 2026-09-23)

> **State-transition authorization and invariant validation are enforced inside the controlled PostgreSQL operation that performs the transition. FastAPI orchestrates and invokes the operation but is not the sole security boundary. Direct table writes remain protected by RLS.**

```text
Client
  ↓
FastAPI                         ← تنسيق فقط: JWT، Auth API، إعادة المحاولة، التعويض
  ↓
Controlled DB Function          ← حدّ الأمان
  ├── verify security context
  ├── verify permission
  ├── verify scope
  ├── verify current state
  ├── verify allowed transition
  ├── verify business invariants
  ├── perform transaction
  └── write audit
  ↓
PostgreSQL
```

**المبدأ:** RLS هي الحماية الافتراضية للبيانات؛ الدوال المتحكَّم بها حدود العمليات المميزة التي تحتوي business invariants.

#### 5.0.1 متى تُستعمل — قائمة مغلقة من أربع فئات

| الفئة | أمثلة Foundation |
|---|---|
| إنشاء الهوية والحسابات المركبة (G4) | §5.2 |
| انتقالات الحالة | §5.3 |
| عمليات مركبة يجب أن تكون ذرية | الدمج، النقل (مراحل لاحقة) |
| عمليات تتجاوز RLS داخلياً بعد تحقق صريح | البحث عن ولي أمر بالهاتف عبر الـTenant (المرحلة 4) |

**CRUD العادي خارجها:** `Direct table operation → RLS`. لا تُكتب دالة لمجرد تغليف INSERT/UPDATE بسيط.

(دوال RLS المساعدة في `RLS_MODEL_v1.md` §1–§3 و§10 فئة مستقلة: قراءة فقط، بلا آثار جانبية، ولا تُستدعى من العميل.)

#### 5.0.2 المتطلبات السبعة لكل دالة متحكَّم بها

| # | المتطلب | التنفيذ |
|---|---|---|
| 1 | **لا ثقة بمعرّف فاعل مُمرَّر** | لا معامل `p_actor_id` إطلاقاً. الفاعل = `auth.uid()` والسياق = `app.current_security_context()` (🔬 V3) |
| 2 | **فحص الصلاحية** | `app.has_permission()` أو `app.has_platform_permission()` بحسب السياق — لا الاثنتان |
| 3 | **فحص النطاق** | `app.can_access_*()` على الكيان الهدف بعد قراءته من الجدول، **لا** على قيمة مُمرَّرة من العميل |
| 4 | **فحص الحالة الحالية والانتقال المسموح** | قراءة الصف بـ`SELECT ... FOR UPDATE`، ثم مطابقة `(from_state, to_state)` مع **قائمة انتقالات صريحة معلنة داخل الدالة**. ما لا يرد فيها مرفوض — لا انتقال ضمني |
| 5 | **business invariants** | داخل المعاملة نفسها وقبل الكتابة |
| 6 | **Audit** | T7 يلتقط الصف القديم والجديد؛ الدالة تضبط `app.audit_action` و`app.audit_reason` قبل الكتابة. الحقول: actor، action، entity، old_state، new_state، school/tenant، timestamp، source |
| 7 | **`SECURITY DEFINER` آمن** | owner: **`app_owner`** (`NOLOGIN`, `BYPASSRLS`) — **R2 معتمد**؛ الفاعل عبر **`app.auth_uid()`** لا `auth.uid()` (`RLS_MODEL_v1.md` §4.5)؛ `postgres` احتياط فقط إن ظهر قيد غير متوقع؛ `SET search_path = app, public, pg_temp` ثابت؛ كل الكائنات مؤهَّلة باسم الـschema؛ لا SQL ديناميكي من مدخلات المستخدم؛ `REVOKE EXECUTE ... FROM PUBLIC, anon` ثم `GRANT EXECUTE ... TO authenticated`؛ **التفويض داخل الدالة إلزامي ولا يفترض أن المستدعي FastAPI** |

**ملاحظة تنفيذية على (7) — مُثبتة في M00 (V3c) واختبار M01:** Postgres يمنح `EXECUTE` لـ`PUBLIC` **افتراضياً** عند `CREATE FUNCTION`، وصلاحيات Supabase الافتراضية لا تغطي أي schema جديد — فكل دالة في `app` قابلة للتنفيذ من `anon` ما لم تُسحب. لذلك **في M01:**

```sql
alter default privileges for role app_owner revoke execute on functions from public;
```

**وكل دالة `SECURITY DEFINER` في `app` تُنشأ تحت `set local role app_owner`** فتولد ملكاً له وبلا `EXECUTE` لأحد، ويُمنح المسموح صراحةً.

> **تصحيح (اختبار M01، 2026-09-23):** الصيغة الأولى هنا كانت `ALTER DEFAULT PRIVILEGES IN SCHEMA app REVOKE ... FROM PUBLIC` — **بلا أثر**: الصلاحيات الافتراضية المقيّدة بـschema تضيف فقط ولا تسحب منح `PUBLIC` العالمي. الدليل: دالة أنشأها `postgres` بعدها بقيت `anon=true`. `FOR ROLE app_owner` + الإنشاء بهويته: `anon=false`، `authenticated=false`، ولا أثر على ما ينشئه `postgres` في `public`.

ويبقى في M20 اختبار يمرّ على كل دوال `app` ويتأكد أن `anon` لا يملك `EXECUTE` على أي منها (الاستعلام المُثبت في V3c).

**لماذا `EXECUTE` لـ`authenticated` لا لـFastAPI وحده:** FastAPI يستدعي الدالة بـJWT المستخدم (§5.4 الخطوة 4) كي تعمل RLS وT8 بهوية الفاعل الحقيقي — أي عبر الدور `authenticated` نفسه. حصر `EXECUTE` في service role كان سيُسقط هوية الفاعل ويجعل FastAPI الحدّ الأمني الوحيد، وهذا ما يرفضه القرار.

#### 5.0.3 مثال الهيكل

```sql
create or replace function app.archive_student(p_student_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  -- (1)(2) السياق والصلاحية — الفاعل داخل has_permission() عبر app.auth_uid()
  if not app.has_permission('student.archive') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- (3)(4) النطاق والحالة من الصف نفسه، مع قفل
  select s.status into v_status
    from public.students s
   where s.id = p_student_id
     and app.student_in_scope(s.id)
   for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if (v_status, 'archived') not in (('active','archived'), ('withdrawn','archived')) then
    raise exception 'invalid transition % -> archived', v_status using errcode = '22023';
  end if;
  -- (5) invariants
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'reason required' using errcode = '22023';
  end if;
  -- (6) سياق التدقيق ثم الكتابة
  perform set_config('app.audit_action', 'archive', true);
  perform set_config('app.audit_reason', p_reason, true);
  update public.students
     set status = 'archived', archived_at = now()
   where id = p_student_id;
end;
$$;

-- (تُنشأ الدالة أعلاه بين `set local role app_owner;` و `reset role;` فتولد ملكاً لـapp_owner بلا EXECUTE لأحد)
grant execute on function app.archive_student(uuid, text) to authenticated;
```

**عدم الكشف:** طالب خارج النطاق يُعامل كطالب غير موجود (`not found`)، لا `forbidden` — كي لا تكشف الدالة وجود صفوف خارج نطاق الفاعل.

### 5.1 مبدأ: صف الهوية يولد مع العلاقة التي تجعله مرئياً

`students`, `staff`, `guardians`, `families`, `profiles`, `memberships` لا تُمنح INSERT مباشر. السبب ليس تفضيلاً بل قيد تقني:

- رؤية هذه الصفوف مشتقة من علاقة (`enrollment`, `staff_school_assignment`, `student_guardians`). الصف المُنشأ وحده **غير مرئي لمنشئه** لحظة الإنشاء، فيفشل `INSERT ... RETURNING` (الذي يستعمله عميل Supabase افتراضياً) بخطأ RLS.
- **لذلك الدالة تُنشئ العلاقة التي تجعل الصف مرئياً في المعاملة نفسها:** للطالب هي الـenrollment، وللموظف التكليف، ولولي الأمر الارتباط بالطالب.
- `student_profile_id NOT NULL` يوجب وجود `auth.users` + `profile` + `membership` + دور `student` قبل صف الطالب، في وحدة ذرية واحدة.
- `families` بلا مفتاح `family.create` في الكتالوج المجمَّد — فتُنشأ فقط ضمن عملية الطالب/ولي الأمر.

✅ **G4:** هذه الصفوف تُنشأ **فقط** عبر دوال إنشاء متحكَّم بها (§5.0).

### 5.2 دوال الإنشاء — قائمة مغلقة

| الدالة | ينشئ ذرياً | يفحص |
|---|---|---|
| `app.provision_student(...)` | profile + membership + دور `student` + (family) + student + **enrollment** | `student.create` + `enrollment.create` + `can_access_identity_scope` + `can_access_school` |
| `app.provision_staff(...)` | staff + أول `staff_school_assignment` | `staff.create` + `staff.assign` + `can_access_school` |
| `app.provision_guardian(student_id, ...)` | guardian + `student_guardians` + (family) | `guardian.create` + `guardian.link` + `student_in_scope` |
| `app.provision_account(kind, id, auth_user_id)` | profile + membership + دور + (نطاق) لموظف/ولي أمر قائم | صلاحية المورد + علاقة في النطاق |
| `app.bootstrap_tenant(...)` | tenant + profile + membership + `tenant_admin` + نطاق tenant | PA `tenant.create` — service context |

**قواعد ملزمة لكل دالة في القائمة** (إضافة إلى المتطلبات السبعة في §5.0.2):
1. أول سطر: فحص الصلاحية والنطاق **بنفس الدوال المساعدة** (`has_permission`, `can_access_*`) — لا منطق تفويض جديد.
2. `auth.uid()` داخل `SECURITY DEFINER` يبقى هوية المستدعي (يُقرأ من JWT لا من `current_user`) — فـT8 وT6 وT7 تعمل بهوية الفاعل الحقيقي. 🔬 V5.
3. اختبار pgTAP لكل دالة: نجاح بالصلاحية، رفض بدونها، رفض خارج النطاق.
4. لا دالة `SECURITY DEFINER` خارج هذه القائمة وقائمة §5.3 ودوال RLS المساعدة. أي إضافة = قرار في `PLAN_v3.md` §9.

### 5.3 دوال انتقال الحالة

| الدالة | الصلاحية |
|---|---|
| `app.suspend_tenant` / `app.reactivate_tenant` | PA `tenant.suspend` |
| `app.archive_group` | `group.archive` |
| `app.archive_school` | `school.archive` |
| `app.end_membership` | `membership.end` + `can_manage_membership` |
| `app.archive_student` | `student.archive` |
| `app.set_staff_status` | `staff.archive` لـ`archived`، `staff.update` لغيرها |
| `app.archive_guardian` | ✅ G8 |
| `app.activate_academic_year` / `app.close_academic_year` | `academic_year.activate` / `.close` |
| `app.unlink_guardian` | `guardian.unlink` |
| `app.close_enrollment(id, status, effective_to, reason)` | `enrollment.archive` (withdrawn/completed) أو `enrollment.transfer` |

`reason` إلزامي في دوال الأرشفة والإغلاق ويُمرَّر إلى T7.

### 5.4 Saga إنشاء حساب الطالب (Auth خارج المعاملة)

`auth.users` يُنشأ عبر Supabase Admin API — **استدعاء HTTP مستقل لا يشارك معاملة قاعدة البيانات**. عبارة «في transaction واحدة» في قرار A4 تتحقق هكذا:

```text
1. العميل يولّد student_id (UUID) — يعمل كمفتاح idempotency
2. FastAPI يتحقق من JWT المستدعي
3. FastAPI (service) ينشئ auth user بمعرّف مشتق حتمياً من student_id
      ← إعادة المحاولة بنفس student_id تجد الحساب قائماً فتعيد استعماله
4. FastAPI (بـJWT المستدعي → RLS/T8 فعّالة) يستدعي app.provision_student(student_id, auth_user_id, ...)
      ← معاملة DB واحدة ذرية:
          profile → membership + دور student → (family) → student → enrollment
5. فشل 4 → FastAPI يحذف auth user (تعويض)
6. مهمة دورية: auth users بلا profile/system_user أقدم من 15 دقيقة → حذف + تنبيه
```

**تصحيح (2026-09-23):** النسخة الأولى من §5.2 أغفلت الـenrollment داخل `provision_student`، فكان الطالب المُنشأ **غير مرئي لمنشئه** — نفس المشكلة التي وُضع G4 لحلها. مخطط المراجعة (profile → student → enrollment داخل المعاملة) هو الصحيح.

**لا ربط معاملاتي بين Supabase Auth و PostgreSQL** — يبقى هذا قيداً ثابتاً على F2.

**قيد على F2:** معرّف Auth للطالب **لا يجوز** أن يعتمد على قيمة تُولَّد داخل معاملة DB (مثل `temporary_id`)، لأن الحساب يُنشأ قبلها. الدخول بـOfficial/Temporary ID يُحَل في FastAPI: بحث عن الطالب ← معرّف Auth المشتق ← تسجيل الدخول.

### 5.5 التزامن

| الحالة | الحماية |
|---|---|
| طالب مكرر بنفس `official_id` | UNIQUE — الثاني يفشل |
| تسجيلان نشطان | UNIQUE جزئي |
| سنتان نشطتان | UNIQUE جزئي |
| `temporary_id` | `nextval()` |
| T8 مع سحب صلاحية الفاعل في اللحظة نفسها | READ COMMITTED — نافذة سباق مقبولة وموثقة |
| دمج نطاق هوية (مدرسة تنضم لمجموعة) | إجراء إداري، `SERIALIZABLE`، قيود المفاتيح المعنية `DEFERRABLE` — خارج Foundation |

عزل المعاملات الافتراضي **READ COMMITTED**؛ لا حاجة لقفل صريح في Foundation لأن كل سباق حرج محمي بقيد تفرد.

---

## B6 — القواعد الزمنية

### 6.1 اصطلاحان — لا يُخلط بينهما

| النوع | الأعمدة | الدلالة | في EXCLUDE |
|---|---|---|---|
| **حدود تقويمية** | `start_date`, `end_date` | شاملة للطرفين — آخر يوم دراسي | `daterange(start, end, '[]')` |
| **فترات صلاحية** | `effective_from`, `effective_to` | نصف مفتوحة: `effective_to` أول يوم **خارج** الفترة؛ `NULL` = مفتوحة | `daterange(from, to, '[)')` |

**نتيجة:** إغلاق تسجيل ونقل في اليوم نفسه = `old.effective_to = new.effective_from = d` بلا تداخل ولا فجوة. و`effective_to > effective_from` (لا `>=`): الفترة الصفرية فارغة لا معنى لها (D10).

### 6.2 الحالة ↔ التاريخ

```sql
-- enrollments, student_guardians, staff_school_assignments
CHECK ((status = 'active') = (effective_to IS NULL))
```

الحالة **لا تُشتق من `now()`**: القيود في Postgres يجب أن تكون حتمية. انتهاء الفترة يحدث بدالة انتقال حالة (§5.3)، لا بمرور الوقت.

### 6.3 القواعد

| القاعدة | الآلية |
|---|---|
| لا تداخل بين سنوات المدرسة | EXCLUDE `[]` |
| لا تداخل بين فصول السنة | EXCLUDE `[]` |
| الفصل داخل السنة | FK مركّب + CHECK (§3.2) |
| لا تداخل في تسجيلات الطالب عبر الـTenant | ✅ **G6**: `EXCLUDE USING gist (student_id WITH =, daterange(effective_from, effective_to, '[)') WITH &&)` |
| المنطقة الزمنية | الأعمدة `date` تُفسَّر بـ`schools.timezone`؛ `timestamptz` بـUTC وتُعرض `Africa/Cairo` |

---

## B7 — متطلبات التدقيق

### 7.1 النطاق

T7 على **كل** جداول Foundation عدا `audit_log` (27 جدولاً). في Foundation كل جدول إما تفويض أو هوية أو إعداد مؤثر — لا جدول «غير حساس» يستحق الاستثناء.

### 7.2 محتوى الصف

| الحقل | المصدر |
|---|---|
| `action` | `insert` / `update` / `delete` من `TG_OP`؛ دوال §5.3 تمرر `archive`/`activate`/... عبر `app.audit_action` |
| `old_values` / `new_values` | `to_jsonb(OLD)` / `to_jsonb(NEW)` كاملة |
| `actor_type`, `actor_id` | `current_profile_id()` ← `tenant_user`؛ وإلا `current_system_user_id()` ← `platform_admin`؛ وإلا `system` |
| `platform_tenant_id`, `school_id` | من أعمدة الصف إن وُجدت؛ `role_permissions` تُحَل عبر `roles`؛ `membership_roles` من عمودها الجديد |
| `reason` | `current_setting('app.audit_reason', true)` — تضبطه دوال §5 و FastAPI |
| `source` | `current_setting('app.request_source', true)`، افتراضياً `api` |
| `ip_address` | `x-forwarded-for` من `current_setting('request.headers', true)` |

`reason` و`source` **بيانات وصفية غير موثوقة** يستطيع العميل التأثير فيها؛ لا يُبنى عليها قرار أمني.

### 7.3 الثبات

`REVOKE UPDATE, DELETE` من `authenticated`, `anon` + T5 الذي يرفض حتى service role. لا حذف ولا أرشفة لصفوف التدقيق في v1.

### 7.4 ما لا يلتقطه T7 — FastAPI

قراءة Platform Admin لبيانات Tenant (N5)، كل عملية `*.export`، قراءة المستندات والملاحظات الحساسة (المرحلة 4). FastAPI يكتب صفاً بـservice role.

### 7.5 الرؤية (F10، F11)

| الفاعل | يرى |
|---|---|
| مستخدم Tenant + `audit.read` | صف `school_id` ضمن `can_access_school`؛ أو صف كيان هوية يستطيع رؤيته الآن (`student_in_scope`...)؛ أو صف tenant-level بنطاق tenant |
| + `audit.sensitive_read` | يُطلب إضافياً لصفوف `entity_type` في قائمة حساسة تُعرَّف مع جداول المرحلة 4 |
| Platform Admin + `audit.read` | صفوف `entity_type` platform-level فقط: `platform_tenants`, `groups`, `schools`, `system_users`, `platform_admin_*` |

---

## B8 — عقد البيانات المرجعية والبذر

### 8.1 ثلاث فئات — ثلاثة أماكن

| الفئة | المحتوى | المكان | في Production |
|---|---|---|---|
| **مرجعية** | 73 permission، 10 أدوار نظام، `role_permissions`، دور `platform_admin` وصلاحياته التسع | **migration** (M23) | ✅ |
| **إقلاع** | أول `system_user` حقيقي لأحمد | سكربت تشغيلي بـservice role — **ليس في المستودع** | ✅ مرة واحدة |
| **تطوير** | Tenant + Group بمدرستين + مدرسة مستقلة + مستخدم لكل دور (E5) | `supabase/seed.sql` | ❌ أبداً |

**لماذا المرجعية في migration لا في seed:** `supabase/seed.sql` لا يعمل في Production إطلاقاً — يعمل عند `db reset` محلياً فقط. كتالوج في seed = نظام بلا صلاحيات في Production.

### 8.2 قواعد البيانات المرجعية

- تُعرَّف **بالكود** لا بالـUUID؛ الربط بـ`JOIN ... ON code`. لا UUID مكتوب يدوياً في أي migration.
- تُدرَج في سياق service (`auth.uid() IS NULL`) → T6 يترك `created_by` فارغاً، T7 يسجل `system`، T8 مُعفى ✅ G7.
- أي تعديل لاحق = migration جديدة + قرار في `PLAN_v3.md` §9.
- **كشف الانحراف:** اختبار pgTAP يؤكد عدد 73 بالضبط، والخريطة كاملة كما في `ROLE_PERMISSION_SEED_v1.md` §4 — أي اختلاف يُفشل CI.

### 8.3 بيانات الاختبار

كل ملف pgTAP ينشئ بياناته داخل `BEGIN ... ROLLBACK` ولا يعتمد على `seed.sql`. مساعدات الاختبار (إنشاء مستخدم وانتحال JWT) تُكتب في schema `tests` داخل المستودع — **لا dependency خارجية** (قاعدة «توقف واسأل قبل dependency»).

---

## B9 — مخطط اعتماديات الـMigrations

```text
extensions (btree_gist) ─┐
schema app ──────────────┼─► trigger fns T5, T6 (plpgsql: لا تتحقق من الجداول عند الإنشاء)
                         │
auth.users ─► [auth_identities G10] ─► platform_tenants ─► profiles
                                              │              │
                                              ▼              ▼
                                           groups ◄──── (created_by FK)
                                              │
                                              ▼
                                           schools (is_standalone, scope_owner_id)
                                              │
                                              ▼
                                        identity_scopes ─► T9 on groups/schools
system_users ─► platform_admin_roles ─► platform_admin_assignments
permissions ─► roles(owner_key) ─► role_permissions
          └──────────────────────► platform_admin_role_permissions
profiles ─► memberships ─► membership_roles(role_owner_key) , membership_scopes
schools ─► academic_years ─► terms , sections ◄─ grade_levels ◄─ stages
profiles, identity_scopes, families ─► students ─► student_guardians ◄─ guardians
staff ─► staff_school_assignments ◄─ schools
students, schools, sections ─► enrollments
all tables ─► audit_log ─► T7 attach
all tables ─► RLS helpers (sql: تتحقق من الجداول عند الإنشاء) ─► ENABLE+FORCE ─► policies ─► T8
helpers ─► state fns ─► provisioning fns ─► reference data
```

**تحليل الدوائر:** لا توجد دائرة FK. التصميم المبدئي `schools.identity_scope_id` كان سيخلق دائرة `schools ↔ identity_scopes`؛ مفاتيح المالك المشتقة (G3) تتجنبها.

**قيدان على الترتيب:**
1. دوال `language sql` تُتحقَّق أجسامها عند الإنشاء → بعد كل جداولها. دوال `plpgsql` لا → T5/T6 مبكراً.
2. البيانات المرجعية **آخراً**: إدراجها يطلق T6/T7/T8، وهذه تستدعي دوال الهوية.

---

## B10 — خطة Migrations الـFoundation

**التسمية:** طوابع زمنية يولّدها `supabase migration new` (ما يتوقعه CLI)؛ الأرقام M01–M23 ترتيب منطقي فقط. **كل migration بعد التطبيق ثابتة** (`PLAN_v3.md` §3.3 بند 19).

| # | الـMigration | المحتوى | اختبار pgTAP |
|---|---|---|---|
| **M00** | *spike — لا يُحفظ* | التحقق من V1–V8 على Supabase محلي | — |
| M01 ✅ | `setup` | `btree_gist` في schema `extensions`؛ schema `app` **ملك `postgres`**؛ الدور `app_owner` (`NOLOGIN BYPASSRLS`) + `grant app_owner to postgres` + `grant usage, create on schema app to app_owner` (R2)؛ **`app.auth_uid()`** ملك `postgres` و`EXECUTE` لـ`app_owner` وحده؛ **`ALTER DEFAULT PRIVILEGES FOR ROLE app_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`** (V3c — مُصحَّح) | `01_setup` ✅ 21/21 |
| M02 ✅ | `app_trigger_functions` | T5, T6؛ `app.temporary_id_seq`, `app.next_temporary_id()` (إصلاح `lpad`) | `02_app_trigger_functions` ✅ 26/26 |
| M03 ✅ | `identity_root` | `auth_identities` (G10)؛ `platform_tenants`؛ `profiles`؛ **`app.current_profile_id()`, `app.current_tenant_id()`** (نُقلتا من M12: اعتمادياتهما جاهزة وT6 تحتاج الأولى) | `03_identity_root` ✅ 28/28 |
| M04 ✅ | `tenancy` | `groups`؛ `schools` + أعمدة مشتقة؛ `identity_scopes` (+ FK Tenant للمدرسة)؛ T9 | `04_tenancy` ✅ 32/32 |
| M05 ✅ | `platform_admin_identity` | `system_users` (G10)؛ `platform_admin_roles`؛ `platform_admin_assignments`؛ **`current_security_context()`, `current_system_user_id()`, `is_platform_admin()`** (نُقلت من M12) | `05_platform_admin_identity` ✅ 27/27 |
| M06 ✅ | `permission_catalog_tables` | `permissions`؛ `roles` + `owner_key`؛ `role_permissions`؛ `platform_admin_role_permissions`؛ **`has_platform_permission()`** (نُقلت من M12) | `06_permission_catalog_tables` ✅ 26/26 |
| M07 ✅ | `memberships` | `memberships`؛ `membership_roles` (I16)؛ `membership_scopes` (I13–I15)؛ **`has_permission()`, `can_access_tenant/group/school()`** (نُقلت من M12؛ F1 مُطبَّق) | `07_memberships` ✅ 46/46 |
| M08 | `academic_structure` | `academic_years`؛ `terms` (I35)؛ `stages`؛ `grade_levels`؛ `sections` | `08_academic` (I33–I37) |
| M09 | `people` | `staff`؛ `staff_school_assignments`؛ `families`؛ `students`؛ `guardians`؛ `student_guardians` | `09_people` (I22–I32) |
| M10 | `enrollments` | `enrollments` (I38–I42) | `10_enrollments` |
| M11 | `audit` | `audit_log`؛ T7؛ ربطه بـ27 جدولاً | `11_audit` (I44–I46) |
| M12 | `authz_helpers` | **المتبقي فقط:** دوال العلاقة (`student_in_scope`, `student_linked_to_guardian`, `student_is_self`, `staff_in_scope`, `guardian_in_scope`, `family_in_scope`, `can_access_identity_scope`, `current_guardian_id`) و`can_see/can_manage_membership` — دوال الهوية والصلاحية والنطاق أُنشئت في M03 و M05 و M06 و M07 حين جهزت اعتمادياتها | `12_helpers` |
| M13 | `rls_enable` | **تحقق فقط:** كل الجداول مفعّلة ومفروضة منذ إنشائها (تنفيذياً: RLS يُفعَّل في migration كل جدول، لأن صلاحيات Supabase الافتراضية تمنح `anon` صلاحية ALL على جداول `public` فور إنشائها) | T2 من RLS §15 |
| M14 | `policies_tenancy_platform` | | `14_isolation` (I1–I7) |
| M15 | `policies_authz` | profiles، memberships، roles، scopes | `15_escalation` (E1–E8 + F1–F5) |
| M16 | `policies_academic` | | |
| M17 | `policies_people_enrollment` | | `17_relationship` (R1–R5) |
| M18 | `policies_audit` | F10/F11 | `18_audit_visibility` |
| M19 | `authz_integrity` | T8 | `19_t8` |
| M20 | `privileges` | سجل §4.6؛ REVOKE من `anon`؛ EXECUTE على الدوال | `20_column_grants` |
| M21 | `state_functions` | §5.3 | `21_state` |
| M22 | `provisioning_functions` | §5.2 | `22_provisioning` |
| M23 | `reference_data` | الكتالوج والأدوار والخرائط | `23_catalog_drift` |

**معيار الخروج من Gate C/D/E:** كل M01–M23 مطبَّقة على قاعدة نظيفة بـ`supabase db reset`، وكل ملفات pgTAP خضراء في CI.

---

## 11. قرارات Gate B — G1–G10 ✅ معتمدة كلها (2026-09-23)

| # | القرار | التوصية | البديل | أثر الرفض |
|---|---|---|---|---|
| **G1** ✅ معتمد | `profiles`: لا تعديل ذاتي؛ `profile.update` لـ`tenant_admin`/`group_manager`/`school_admin` فقط — **سحبها من 7 أدوار في الـseed** (طُبِّق في `ROLE_PERMISSION_SEED_v1.md`) | ✅ | إبقاء التعديل الذاتي لـ`display_name` | يتعارض مع §7.8: «بيانات ولي الأمر تعدلها المدرسة فقط» |
| **G2** ✅ معتمد | DELETE مسموح على `membership_roles`, `membership_scopes`, `role_permissions` (مخصصة) مع T7 وT8 | ✅ | سحب ناعم بـ`revoked_at` | بدونه لا يمكن سحب دور أو نطاق |
| **G3** ✅ معتمد | اتساق المدرسة مع نطاق هوية الطالب: `schools.scope_owner_id` و`identity_scopes.owner_id` مشتقان + `enrollments.identity_scope_id`, `scope_owner_id` + FKs مركّبة | ✅ إعلاني | trigger | **بدونه قرار A4 شكلي:** طالب نطاق المجموعة G يُسجَّل في مدرسة مستقلة S، فتنشئ S طالباً مكرراً بنفس `official_id` في نطاقها |
| **G4** ✅ معتمد | صفوف الهوية تُنشأ فقط بدوال §5.2 | ✅ | INSERT مباشر بـRLS | `RETURNING` يفشل؛ `student_profile_id NOT NULL` غير قابل للتحقيق من المتصفح |
| **G5** ✅ معتمد | لا أعمدة حساسة في جداول Foundation؛ `*.sensitive_read` تحكم جداول المرحلة 4 (ملاحظات، مستندات) كجداول مستقلة | ✅ | جداول جانبية 1:1 للأعمدة الحساسة الآن | لا يوجد تعريف لـ«الحقول المصنفة حساسة» في أي وثيقة؛ و`GRANT` الأعمدة لا يطبّقها |
| **G6** ✅ معتمد | لا تداخل زمني بين تسجيلات الطالب عبر الـTenant | ✅ | الاكتفاء بـI38 | يمكن أن يكون الطالب نشطاً في مدرستين في اليوم نفسه |
| **G7** ✅ معتمد | T8 مُعفى في سياق service (`auth.uid() IS NULL`) — service role جذر الثقة ومسجَّل كـ`system` | ✅ | لا إعفاء | البيانات المرجعية و`bootstrap_tenant` مستحيلة |
| **G8** ✅ معتمد | فجوات الكتالوج المجمَّد تُحَل بمفاتيح قائمة: أرشفة ولي الأمر ← `guardian.update`؛ الأسرة ← دوال الإنشاء فقط؛ إدارة Platform Admins ← service فقط | ✅ | إضافة `guardian.archive`, `family.create` | فتح الكتالوج المجمَّد |
| **G9** ✅ معتمد | T9 ينشئ نطاق الهوية تلقائياً — **يعكس** ملاحظتي السابقة في DD §2.16.1 «طبقة الأعمال لا trigger» | ✅ | دوال `create_group`/`create_school` | الـinvariant «كل مجموعة لها نطاق» يصبح معتمداً على مسار الإنشاء |
| **G10** ✅ معتمد | (1) حصرية الهوية بجدول `auth_identities (auth_user_id PK, kind)` + FK مركّب؛ (2) **فصل صريح للسياقين**: `has_permission()` لـTenant و`has_platform_permission()` لـPlatform، لا `OR` على مستوى الصلاحية | ✅ | trigger + قفل | §4.4: ثغرة قراءة كل الـTenants بحساب مزدوج |

---

## 12. M00 — Spike التحقق (Gate I6)

> **النتائج: `docs/M00_RESULTS.md`.** V1–V7 ✅ (V2 بإعداد R2 المعتمد: المالك المخصص عبر `app.auth_uid()`)؛ V8 جزء DB ✅ وجزء HTTP ⏳.

**النطاق مقيَّد عمداً:** يُثبت فقط ما يمكن أن **يغيّر التصميم**. ليس مشروعاً تجريبياً: جداول مصغّرة بالحد الأدنى من الأعمدة، ويُحذف كله بعد التحقق. **لا يبدأ Gate C قبل نجاحه.**

| # | يُثبت | الاختبار الأدنى | إن فشل |
|---|---|---|---|
| **V1** | `FORCE RLS` + `SECURITY DEFINER` بلا recursion | جدولان مصغّران، دالة تقرأ الأول من سياسة على الأول، مع `FORCE` | لا `FORCE` على جداول مصدر التفويض (RLS §4.3) فقط |
| **V2** ✅ R2 | صفات مالك الدوال: `BYPASSRLS` لـ`postgres` في Supabase، **وإمكانية إنشاء دور owner مخصص** يحمل `BYPASSRLS` (متطلب §5.0.2 رقم 7) | `select rolbypassrls from pg_roles where rolname = current_user`؛ ثم `create role app_owner nologin bypassrls` | إن تعذّر الدور المخصص: `postgres` مالكاً مع توثيق ذلك كاستثناء؛ وإن غاب `BYPASSRLS` كلياً: كما V1 |
| **V3** | أمان الدوال: `SET search_path` ثابت + `auth.uid()` داخل `SECURITY DEFINER` يبقى هوية المستدعي | دالة definer تُرجع `auth.uid()` مع JWT منتحل؛ محاولة تظليل كائن عبر `pg_temp` | دوال §5.2 تأخذ الفاعل صراحة وتتحقق منه |
| **V4** | عمود `GENERATED STORED` طرفاً في FK مركّب (مرجِعاً ومرجَعاً) | `schools.is_standalone` → `identity_scopes` | trigger بديل لـI9، I16، G3 |
| **V5** | `UNIQUE NULLS NOT DISTINCT` في نسخة Postgres المستعملة | `select version()` + صفّا نطاق `tenant` مكرران | فهارس فريدة جزئية لكل `scope_type` |
| **V6** | `ON UPDATE CASCADE` على FK مركّب بتواريخ + إعادة تقييم CHECK تحت `FORCE RLS` | تقليص سنة يُخرج فصلاً ← رفض؛ تمديدها ← نجاح | trigger T4 يعود |
| **V7** | سلوك RLS مع جدول بلا سياسة تحت `FORCE` (منع كامل صامت) + استعلام الكتالوج الذي يكشفه | جدول بلا سياسة + استعلام `pg_policies` | — (يُعتمد كاختبار T3) |
| **V8** | Saga حساب الطالب: Admin API ← دالة DB ← تعويض؛ `auth.uid() IS NULL` تحت service role؛ idempotency بإعادة المحاولة | Supabase Auth محلي: نجاح، فشل مع حذف تعويضي، إعادة محاولة بنفس المعرّف | إعادة تصميم §5.4 قبل F2 |

**ملاحظة على V7:** التحقق من أن **الجداول الـ28 كلها** لها سياسات لا يتم في M00، لأنها غير موجودة بعد. M00 يثبت **السلوك** (منع صامت) و**أداة الكشف** (استعلام `pg_policies`)؛ التغطية الكاملة يثبتها اختبار T3 بعد M13–M18، ويُفشل CI إن نقصت سياسة.

**أُسقطت من القائمة السابقة** (تفاصيل لا تغيّر التصميم): توافر `btree_gist` — يُفحص ضمنياً في M01؛ سلوك `INSERT ... RETURNING` مع RLS — سلوك Postgres موثّق، ويُغطّى باختبارات M22.

---

## 13. حالة Gate B

| البند | الحالة |
|---|---|
| B1 مطابقة ERD | ✅ |
| B2 مطابقة DD | ✅ |
| B3 القيود والفهارس | ✅ — 3 triggers أُلغيت لصالح قيود إعلانية |
| B4 الملكية والتفويض | ✅ — 7 ثغرات في A3 صُحِّحت (F1–F6، F10، F11) |
| B5 المعاملات | ✅ ✅ G4 |
| B6 الزمن | ✅ ✅ G6 |
| B7 التدقيق | ✅ |
| B8 البذر | ✅ |
| B9 الاعتماديات | ✅ |
| B10 خطة الـMigrations | ✅ M00–M23 |
| **قرارات** | ✅ **G1–G10 معتمدة كلها** |
| **تحققات تقنية** | 🔬 **V1–V8** — M00 في Gate I، مقيَّد النطاق |

**✅ Gate B مغلق (2026-09-23).** التالي: **Gate I** (البنية التحتية) ← **M00** ← Gate C. لا migration قبل نجاح M00.

```text
M00           → يثبت خصائص PostgreSQL/Supabase الحرجة (V1–V8)
Gate C        → إنشاء الجداول
T3            → يثبت أن الجداول الـ28 لها سياسات RLS
CI            → يفشل إذا ظهرت فجوة جديدة
```
