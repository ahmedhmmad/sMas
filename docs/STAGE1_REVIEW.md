# Stage 1 Review — مراجعة ERD + migrations

**الحالة:** ✅ المراجعة مكتملة (2026-10-01) — R1–R10 · خط الأساس `59399d4` (35 migration: M01–M30b) · **النتائج C الخمس مُصلحة بعد الاعتماد (2026-10-02):** M31 (S1، S2 — أمنية، مستقلة) ثم M32 (C1–C3) — §12 · لا C جديدة · **🔒 Stage 1 مغلق (2026-10-02، CI `f41b0ff`)**
**السؤال:** هل الـERD والـmigrations الحالية تعكس التصميم المعتمد وتنفذه بصورة كاملة؟ — لا «هل يمكن تصميمها بطريقة أخرى؟».

---

## 0. المنهج والقواعد

- **مصدر حقيقة الحالة المنفذة = الـcatalog** لقاعدة مبنية بـ`db reset --no-seed` (لقطة واحدة: الجداول، الأعمدة، القيود، الفهارس، السياسات، الـtriggers، الدوال، المنح، الامتيازات الافتراضية، الأدوار). عند تعارض وثيقة مع الـcatalog لا يُفترض صواب أحدهما: يُرجع إلى **التصميم المعتمد** لتحديد الصنف.
- **التصنيف:** **A** وثيقة متأخرة عن تنفيذ معتمد (تُصحَّح in-place بتاريخ) · **B** قاعدة منفذة بلا اختبار يثبتها باسمها (اختبار فقط) · **C** التنفيذ يخالف التصميم المعتمد أو ينقص عنه (يُعرض، ولا إصلاح بلا اعتماد) · **D** سؤال تصميم خارج سؤال المراجعة (ملاحظة، لا يُفتح) · **Deferred** مرحَّل بقرار سابق.
- **C الأمني** (عزل، تجاوز RLS، تصعيد، استيلاء على حساب) يُعرض فوراً — عُرض S1/S2 أثناء المراجعة واعتُمد حلهما.
- لا إعادة فتح لقرار مغلق؛ لا migration ضمن المراجعة (الإصلاحات بعد الاعتماد — §12).

## 1. الخلاصة

| البند | النتيجة |
|---|---|
| **R1** ERD ↔ schema | 30 جدولاً، 331 عموداً، 279 قيداً (30 PK، 91 FK منها 31 مركّبة، 49 UNIQUE، 106 CHECK، 3 EXCLUDE)، 185 فهرساً، 7 أعمدة محسوبة. **لا عمود ولا قيد موثق غائب عن قاعدة البيانات.** الفروق كلها في الاتجاه المعاكس (منفَّذ غير مسرود) ← A. قاعدة «كل FK له فهرس»: 2 ناقصان ← C3 (✅ M32) |
| **R2** الـ46 invariant | كائنات الآليات الـ45 المنفذة كلها موجودة بأسمائها (I43 مرحَّل بقرار). 7 فجوات اختبار (10 قيود) ← B، أُغلقت في `31` |
| **R3** RLS | ENABLE + FORCE على الثلاثين؛ 61 سياسة، كلها PERMISSIVE و`TO authenticated`؛ تطابق RLS_MODEL بتعديلاته المسجلة (M14، M15، M17، M18، M20b، M29). لا سياسة زائدة ولا ناقصة. **S1 و S2** ظهرتا هنا ← C أمني (✅ M31) |
| **R4** الامتيازات | سجل الأعمدة §4.6 مطابق؛ `anon` بلا شيء على الجداول والدوال؛ 71 دالة في `app` (68 SECURITY DEFINER) بعقود سليمة؛ لا دالة في `public`. **C1** (sequences) و**C2** (`MAINTAIN`) خارج ما غطّاه M20 (✅ M32) |
| **R5** الـmigrations | تطبيق من الصفر ناجح ومتكرر؛ بصمتان بنيويتان متطابقتان بين تطبيقين؛ لا اعتماد على حالة لاحقة؛ متطلبات الإنتاج خارج الـmigrations مسرودة (§6.3) |
| **R6** التدقيق | T7 على 28 من 30 (الاستثناءان موثقان)؛ 27 دالة تضبط سياق التدقيق وكلها تعيده فارغاً؛ N5 بدالة M29 |
| **R7** Identity/Auth | `auth.users.id = entity_id` مفروض في DB (D1، I2)؛ حصرية G10 إعلانية؛ قائمة R2 مغلقة عند 3؛ لا دالة تقرأ `auth.uid()` مباشرة؛ عقد V9b اختبار CI |
| **R8** إضافات F3 | `host_label` و`slug` في DD؛ ERD حُدِّث بملحق؛ الاتساق DB/API/Web مثبت باختبارات F3 |
| **R9** الاستعادة | البصمة كانت لا تغطي تعريف الأعمدة ولا مالك الجدول ولا حالة الـtrigger ولا امتيازات الـsequences ولا الإضافات ← وُسِّعت (سكربت)؛ L1 يبقى TBD |
| **R10** انحراف الوثائق | 14 بنداً ← A، صُحِّحت in-place |

**شرط الإغلاق:** لا C مفتوحة · كل A و B مغلقة · CI أخضر. **A و B مغلقة. C: الخمسة مُصلحة** (M31، M32 — §12) ولا C جديدة؛ CI أخضر (`f41b0ff`) — **🔒 Stage 1 مغلق (2026-10-02).**

---

## 2. R1 — ERD ↔ PostgreSQL schema

**الطريقة:** تحليل آلي لـ`DATA_DICTIONARY_v1.md` (قسم لكل جدول: صف لكل عمود، بند لكل قيد) مقابل `pg_attribute`/`pg_constraint`/`pg_index`، ثم فرز يدوي لكل فرق؛ واصطلاحات §0 مقابل الـcatalog.

| الفحص | النتيجة |
|---|---|
| جدول في DB بلا قسم DD / قسم بلا جدول | 0 / 0 |
| عمود موثق غائب عن DB | 0 |
| قيد موثق (UNIQUE/FK/EXCLUDE/CHECK) غائب عن DB | 0 (المرشحات الآلية الخمسة صيغ مكافئة: `IN (…)` ↔ `= ANY`، `NOT IN` ↔ `<> ALL`) |
| NULL / النوع / الافتراضي مخالف | 0 |
| عمود في DB غير موثق في جدول أعمدته | 5: `schools.guardian_first_login_mode`، `roles.owner_key`، `identity_scopes.owner_id`، `enrollments.identity_scope_id`/`scope_owner_id` — كلها بقرار مسجل ومذكورة نثراً ← **A** |
| قيد في DB غير مسرود في DD | 23 قيد عدم فراغ + صيغ (`roles_code_chk`، `platform_admin_roles_code_chk`، `students_temporary_id_chk`، `students_official_blank_chk`، `grade_levels_sequence_chk`)، وأسماء قيود الهاتف ← **A** |
| الأعمدة المشتركة (§0.3) | 18 جدولاً تحملها كاملة؛ 12 استثناءً بقرارات مسجلة لم تكن مجموعة في مكان واحد ← **A** |
| الأنواع (§0.1) | `uuid`/`text`/`timestamptz`/`date`/`jsonb`/`integer`/`bigint`/`boolean`/`inet` فقط — لا `varchar`، لا `timestamp`، لا `json`؛ كل `boolean` NOT NULL بافتراضي |
| `ON DELETE CASCADE` (§0.7) | 4 فقط، على جداول الربط؛ `ON UPDATE CASCADE` واحد (`terms_year_fk` — I35)؛ لا `SET NULL` |
| `UNIQUE (id, platform_tenant_id)` / `(id, school_id)` (§0.6) | 10 / 4 — القائمتان مطابقتان |
| جداول الهوية بلا `school_id` (ثابت 3) | `students`, `families`, `guardians`, `staff` — مؤكد |
| جداول School-level: `school_id NOT NULL` + فهرس (ثابت 2) | `academic_years`, `terms`, `stages`, `grade_levels`, `sections`, `enrollments`, `staff_school_assignments` — مؤكد |
| فهارس DD §3 / ERD §8 (16) | كلها موجودة |
| «كل FK له فهرس يبدأ بأعمدته» (المواصفة §3.4) — 91 FK | 87 مستوفاة. `families.platform_tenant_id` و`login_challenges.platform_tenant_id` بلا فهرس ← **C3**. `profiles`/`system_users (auth_user_id, identity_kind)`: `UNIQUE (auth_user_id)` يحدد صفاً واحداً — مستوفاة فعلاً لا حرفاً ← ملاحظة ضمن C3 |
| تسمية القيود | كل CHECK باسم صريح؛ قيد واحد باسم مولَّد: `auth_identities_auth_user_id_fkey` ← **D** (تجميلي) |
| ERD §5 (القيود الـ19) | كلها ممثلة في I1–I46؛ ERD §4 لا يذكر إضافات ما بعد Gate A ← **A** (ملحق §4.21) |

## 3. R2 — الـ46 invariant

الآلية كما صنفتها `DB_IMPLEMENTATION_SPEC_v1.md` §3.1، والكائن كما هو في الـcatalog اليوم، وملف pgTAP الذي يطابقه **باسمه**. تمدّ `TRACEABILITY_E1_E4.md` §E3 (التي تتوقف عند M23).

| INV | الآلية المصنفة | الكائنات في catalog | pgTAP | الحالة |
|---|---|---|---|---|
| I1 | UNIQUE | `platform_tenants_tenant_code_uq` | `03` | ✅ |
| I2 | UNIQUE مركّب | `groups_tenant_code_uq`، `schools_tenant_code_uq`، `schools_tenant_slug_uq` | `04` | ✅ |
| I3 | CHECK | `platform_tenants_tenant_code_chk`، `groups_group_code_chk`، `schools_school_code_chk`، `schools_slug_chk`، `platform_tenants_host_label_chk`، `platform_tenants_host_label_reserved`، `roles_code_chk`، `platform_admin_roles_code_chk`، `permissions_code_format_chk` | `03`، `04`، `05`، `06`، `30`، `30b`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `schools_school_code_chk` |
| I4 | CHECK | `platform_tenants_suspended_chk`، `schools_archived_chk`، `families_archived_chk`، `guardians_archived_chk`، `staff_archived_chk`، `students_archived_chk`، `memberships_ended_chk`، `platform_admin_assignments_revoked_chk` | `03`، `04`، `05`، `07`، `09`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `families_archived_chk`، `guardians_archived_chk`، `students_archived_chk` |
| I5 | FK مركّب | `schools_group_fk`، `groups_id_tenant_uq` | `04` | ✅ — هدف FK (يثبته الـFK نفسه): `groups_id_tenant_uq` |
| I6 | GRANT (لا UPDATE على العمود) | `platform_tenants.tenant_code.UPDATE`، `platform_tenants.host_label.UPDATE`، `groups.group_code.UPDATE`، `schools.school_code.UPDATE`، `families.family_code.UPDATE`، `staff.employee_code.UPDATE` | `20` السجل | ✅ |
| I7 | UNIQUE جزئي | `identity_scopes_group_uq`، `identity_scopes_school_uq` | `04` | ✅ |
| I8 | Trigger T9 | `groups.create_identity_scope`، `schools.create_identity_scope`، `tg_create_identity_scope` | `04`، `11` | ✅ |
| I9 | GENERATED is_standalone + FK مركّب | `schools.is_standalone`، `schools_id_standalone_uq`، `identity_scopes_school_standalone_fk`، `identity_scopes_standalone_chk` | `04`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `identity_scopes_standalone_chk`؛ هدف FK (يثبته الـFK نفسه): `schools_id_standalone_uq` |
| I10 | UNIQUE | `profiles_auth_user_uq` | `03`، `14` | ✅ |
| I11 | G10: auth_identities + FK مركّب | `auth_identities_kind_uq`، `auth_identities_kind_chk`، `profiles_identity_fk`، `profiles_identity_kind_chk`، `system_users_identity_fk`، `system_users_identity_kind_chk` | `03`، `05`، `14`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `auth_identities_kind_chk`؛ هدف FK (يثبته الـFK نفسه): `auth_identities_kind_uq` |
| I12 | UNIQUE (profile_id) | `memberships_profile_uq` | `07` | ✅ |
| I13 | CHECK | `membership_scopes_shape_chk` | `07` | ✅ |
| I14 | UNIQUE NULLS NOT DISTINCT | `membership_scopes_uq` | `07` | ✅ |
| I15 | FK مركّب ×3 | `membership_scopes_membership_fk`، `membership_scopes_group_fk`، `membership_scopes_school_fk` | `07`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `membership_scopes_membership_fk`، `membership_scopes_group_fk` |
| I16 | GENERATED owner_key + FK مركّب + CHECK | `roles.owner_key`، `roles_id_owner_uq`، `membership_roles_role_fk`، `membership_roles_membership_fk`، `membership_roles_owner_chk` | `07` | ✅ — هدف FK (يثبته الـFK نفسه): `roles_id_owner_uq` |
| I17 | CHECK | `roles_is_system_chk` | `06` | ✅ |
| I18 | CHECK | `permissions_code_parts_chk` | `06` | ✅ |
| I19 | Trigger T8 | `membership_roles.authz_integrity`، `role_permissions.authz_integrity`، `membership_scopes.authz_integrity`، `tg_authz_integrity` | `19` | ✅ |
| I20 | RLS WITH CHECK | `membership_scopes_insert`، `membership_scopes_delete` | `15` | ✅ |
| I21 | RLS (can_manage_membership) | `membership_roles_insert`، `membership_roles_delete`، `can_manage_membership` | `15` | ✅ |
| I22 | UNIQUE | `staff_tenant_code_uq` | `09` | ✅ |
| I23 | UNIQUE جزئي | `staff_profile_uq`، `guardians_profile_uq` | `09`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `guardians_profile_uq` |
| I24 | UNIQUE جزئي | `staff_school_assignments_primary_uq` | `09` | ✅ |
| I25 | UNIQUE + CHECK | `guardians_tenant_phone_uq`، `guardians_phone_chk` | `09`، `22` | ✅ |
| I26 | UNIQUE جزئي | `student_guardians_primary_uq` | `09` | ✅ |
| I27 | FK مركّب | `students_family_fk`، `students_scope_fk`، `students_profile_fk`، `student_guardians_student_fk`، `student_guardians_guardian_fk`، `guardians_profile_fk`، `staff_profile_fk` | `09`، `31` | ✅ — **فجوة اختبار أُغلقت في `31`:** `student_guardians_student_fk` |
| I28 | UNIQUE جزئي | `students_scope_official_id_uq` | `09` | ✅ |
| I29 | CHECK | `students_identifier_chk` | `09` | ✅ |
| I30 | NOT NULL + UNIQUE | `students.student_profile_id`، `students_profile_uq` | `09` | ✅ |
| I31 | دالة الإنشاء + GRANT + CHECK صيغة | `next_temporary_id`، `provision_student`، `students_temporary_id_chk`، `students.temporary_id.UPDATE`، `students.temporary_id.INSERT`، `students_tenant_temporary_id_uq` | `02`، `09`، `20`، `22` | ✅ |
| I32 | GENERATED | `students.full_name`، `guardians.full_name`، `staff.full_name` | `09` | ✅ |
| I33 | UNIQUE جزئي | `academic_years_active_uq` | `08` | ✅ |
| I34 | EXCLUDE | `academic_years_no_overlap` | `08` | ✅ |
| I35 | FK مركّب بتاريخي السنة ON UPDATE CASCADE + CHECK | `academic_years_bounds_uq`، `terms_year_fk`، `terms_within_year_chk` | `08` | ✅ — هدف FK (يثبته الـFK نفسه): `academic_years_bounds_uq` |
| I36 | EXCLUDE | `terms_no_overlap` | `08` | ✅ |
| I37 | FK مركّب | `grade_levels_stage_fk`، `sections_year_fk`، `sections_grade_level_fk` | `08` | ✅ |
| I38 | UNIQUE جزئي | `enrollments_active_uq` | `10` | ✅ |
| I39 | FK مركّب واحد إلى sections | `sections_context_uq`، `enrollments_section_fk` | `10` | ✅ — هدف FK (يثبته الـFK نفسه): `sections_context_uq` |
| I40 | G3: GENERATED owner keys + FK مركّبان | `schools.scope_owner_id`، `identity_scopes.owner_id`، `schools_id_scope_owner_uq`، `identity_scopes_id_owner_uq`، `students_id_scope_uq`، `enrollments_school_owner_fk`، `enrollments_scope_owner_fk`، `enrollments_student_scope_fk` | `10` | ✅ — هدف FK (يثبته الـFK نفسه): `schools_id_scope_owner_uq`، `identity_scopes_id_owner_uq`، `students_id_scope_uq` |
| I41 | G6: EXCLUDE | `enrollments_no_overlap` | `10` | ✅ |
| I42 | CHECK | `enrollments_active_chk`، `staff_school_assignments_active_chk`، `student_guardians_active_chk` | `09`، `10` | ✅ |
| I43 | FastAPI / المرحلة 4 | — | — | ⏭️ Deferred (المرحلة 4) |
| I44 | REVOKE + Trigger T5 | `audit_log.audit_log_immutable`، `audit_log.audit_log_no_truncate`، `tg_reject_mutation` | `02`، `11`، `20` | ✅ |
| I45 | Trigger T7 | `tg_audit` | `11` | ✅ |
| I46 | Trigger T6 | `tg_stamp` | `02` | ✅ |

**T7** على 28 جدولاً (كل الجداول عدا `audit_log` و`login_challenges`) · **T6** على 26 (عدا `audit_log`، `login_challenges`، وجدولي الربط الصرف) · **T8** على `membership_roles`، `role_permissions`، `membership_scopes` · **T9** على `groups`، `schools` · **T5** على `audit_log` (صف + `TRUNCATE`).

## 4. R3 — تغطية RLS

`relrowsecurity` و`relforcerowsecurity` = true على الجداول الثلاثين (حارس `13`). السياسات كلها `PERMISSIVE`، `TO authenticated`؛ لا سياسة لـ`anon` ولا `PUBLIC`.

| الجدول | الأوامر المغطاة بسياسة | SELECT |
|---|---|---|
| `academic_years` | SELECT · INSERT · UPDATE | 1 |
| `audit_log` | SELECT | 2 |
| `auth_identities` | — (بلا سياسة عميل) | 0 |
| `enrollments` | SELECT · INSERT · UPDATE | 1 |
| `families` | SELECT · UPDATE | 1 |
| `grade_levels` | SELECT · INSERT · UPDATE | 1 |
| `groups` | SELECT · INSERT · UPDATE | 1 |
| `guardians` | SELECT · UPDATE | 1 |
| `identity_scopes` | SELECT | 1 |
| `login_challenges` | — (بلا سياسة عميل) | 0 |
| `membership_roles` | SELECT · INSERT · DELETE | 1 |
| `membership_scopes` | SELECT · INSERT · DELETE | 1 |
| `memberships` | SELECT | 1 |
| `permissions` | SELECT | 1 |
| `platform_admin_assignments` | SELECT | 1 |
| `platform_admin_role_permissions` | — (بلا سياسة عميل) | 0 |
| `platform_admin_roles` | — (بلا سياسة عميل) | 0 |
| `platform_tenants` | SELECT · UPDATE | 1 |
| `profiles` | SELECT · UPDATE | 1 |
| `role_permissions` | SELECT · INSERT · DELETE | 1 |
| `roles` | SELECT · INSERT · UPDATE | 1 |
| `schools` | SELECT · INSERT · UPDATE | 1 |
| `sections` | SELECT · INSERT · UPDATE | 1 |
| `staff` | SELECT · UPDATE | 1 |
| `staff_school_assignments` | SELECT · INSERT · UPDATE | 1 |
| `stages` | SELECT · INSERT · UPDATE | 1 |
| `student_guardians` | SELECT · INSERT · UPDATE | 1 |
| `students` | SELECT · UPDATE | 1 |
| `system_users` | SELECT | 1 |
| `terms` | SELECT · INSERT · UPDATE | 1 |

- **بلا سياسة عميل (4):** `auth_identities` (G10 — مستثنى بتصميمه)، `login_challenges` (M26)، `platform_admin_roles` و`platform_admin_role_permissions` (قرار M14: service فقط).
- **DELETE:** ثلاث سياسات فقط — استثناء G2.
- **INSERT غائب عمداً** عن `students`, `guardians`, `staff`, `families`, `profiles`, `memberships` (G4: دوال الإنشاء)، وعن `platform_tenants` (M20b) و`identity_scopes` (T9).
- **مطابقة النص:** كل سياسة قورنت بـRLS_MODEL §7–§13: مطابقة مع التعديلات المسجلة — `WITH CHECK` Tenant على `groups`/`schools` (M14)، `can_manage_membership` على النطاق و`membership_id_of` (M15)، `student_in_scope` على كتابة `enrollments` (M17)، سياستا تدقيق منفصلتان (M18)، حذف سياسات المنصة (M20b، M29).
- **لا سياسة تقرأ `memberships` أو جدول علاقة مباشرة** (§1.1 بند 6)؛ الاستعلامان الفرعيان الوحيدان: `role_permissions` ← `roles`، و`families` ← `students` — كما في RLS_MODEL §10.3 و§10.5.
- `auth.uid()` مباشرة في سياستين فقط (`profiles_select` الذات، `system_users_self_select`) — كما في RLS_MODEL §10.1 و§10.6.

## 5. R4 — الامتيازات

| الدور | الجداول | الأعمدة | الدوال (`app`) | schemas |
|---|---|---|---|---|
| `anon` | لا شيء | لا شيء | لا شيء | لا `USAGE` على `app`؛ لا `CREATE` |
| `authenticated` | SELECT على 29 (لا `login_challenges`)؛ DELETE على جداول G2 الثلاثة | سجل §4.6 حرفياً (INSERT على 14 جدولاً، UPDATE على 17) | 19 مساعد RLS (كل منها تستدعيه سياسة) + 27 دالة متحكَّم بها (allowlist `20`) | `USAGE` على `app`؛ لا `CREATE` |
| `service_role` | كل شيء على 28؛ `audit_log`: INSERT/SELECT بلا UPDATE/DELETE/TRUNCATE؛ لا شيء على `login_challenges` | — | دوال ما قبل JWT الخمس فقط | — |
| `app_owner` | منح صريحة لكل جدول بقدر حاجة دواله (`BYPASSRLS`) | `auth_identities`: أعمدة الحالة الثلاثة | يملك 68 دالة؛ EXECUTE على استثناءات R2 الثلاثة | `USAGE, CREATE` على `app` |
| `authenticator` | لا شيء مباشر (`NOINHERIT`؛ عضو في الأدوار الثلاثة) | — | — | — |

- **الدوال (71):** 68 `SECURITY DEFINER`، وكل دالة بـ`search_path` مثبت (`pg_temp` أخيراً)؛ 3 ملك `postgres` بـ`search_path` فارغ و EXECUTE لـ`app_owner` وحده (قائمة R2 المغلقة)؛ 17 داخلية بلا EXECUTE لأحد؛ لا EXECUTE لـ`PUBLIC` ولا لـ`anon`؛ لا `p_actor` في أي توقيع؛ لا دالة في `public` (سطح RPC عبر PostgREST فارغ — المكشوف `public` و`graphql_public` فقط).
- **الامتيازات الافتراضية:** دوال `app_owner` تولد بلا EXECUTE لأحد (M01). جداول `postgres` الجديدة في `public`: `anon` لا شيء، `authenticated` SELECT (M20) — **ومعه `MAINTAIN`** ← C2. Sequences ودوال `postgres` الجديدة في `public`: افتراضي Supabase لم يُمَسّ ← C1.

## 6. R5 — الـmigrations

### 6.1 الترتيب والاعتماديات
35 migration تُطبَّق من الصفر بترتيب أسمائها بلا خطأ (`db reset`)، محلياً وفي CI مع كل push. لا migration تشير إلى كائن تنشئه لاحقة (التطبيق التسلسلي نفسه يثبته). الاستبدالات (`drop function` ثم `create`) في M27 و M30 تعيد الامتيازات صراحةً (حارس `31` يثبت العقد النهائي).

### 6.2 التكرار والحتمية
بصمتان بنيويتان (كل الفئات عدا hash البيانات، لأن المعرّفات `gen_random_uuid()`) بعد تطبيقين مستقلين من الصفر: **متطابقتان — 0 فرق في 1360 سطراً**. `M01` قابلة للتكرار على cluster يبقى فيه `app_owner` بين الـresets.

### 6.3 جمل البيانات داخل الـmigrations
| Migration | الجملة | الافتراض |
|---|---|---|
| M23 `reference_data` | `insert` للكتالوج والأدوار والربط | جداول فارغة؛ حارس داخل الـmigration يكشف الانحراف |
| M30 `tenant_host_context` | `update platform_tenants set host_label = …` | اشتقاق أولي للصفوف القائمة — **لا أثر على قاعدة جديدة**؛ لا بيانات إنتاج سبقت M30 |
| M30b `host_dns_labels` | فحص قبل القيد يوقف بقائمة مسمّاة | fail before mutation — لا تصحيح تلقائي |
| M13، M20 | `do` للتحقق فقط | — |

### 6.4 ما يلزم الإنتاج خارج الـmigrations — لا خطوة يدوية مخفية؛ هذه هي القائمة
1. الـmigrations تُنفَّذ بدور **`postgres`** (جمل `alter default privileges for role postgres`، `grant app_owner to postgres`، `set local role app_owner` تفترضه).
2. **إقلاع أول Platform Admin** (G8): `system_users` + `platform_admin_assignments` بلا مسار عميل — خطوة service عند التهيئة (الـseed يفعلها للتطوير).
3. Supabase Auth: `minimum_password_length` = `API_MIN_PASSWORD_LENGTH`؛ توقيع JWT غير متماثل (ES256)؛ حدود المعدّل ومعالجة IP (I4).
4. FastAPI: `API_DATABASE_URL` (كلمة مرور `authenticator`)، `SUPABASE_SECRET_KEY`، `API_CORS_ORIGIN_BASE`، `API_ENVIRONMENT=production`، قناة OTP حقيقية (المرحلة 5). الواجهة: `VITE_BASE_DOMAIN`.
5. PostgREST: المكشوف `public` و`graphql_public` فقط — `app` لا يُكشف.
6. DNS/TLS للـhosts (خارج F3)، وسياسة النسخ الاحتياطي (Deferred).

## 7. R6 — التدقيق · R7 — Identity/Auth · R8 — F3

**R6**
- T7 (`tg_audit`، AFTER INSERT/UPDATE/DELETE) على 28 جدولاً؛ الاستثناءان: `audit_log` نفسه، و`login_challenges` (قرار 2026-09-26: لا تُنسخ OTP hashes؛ نتيجة الدخول تُدقَّق على `guardians`/`staff`). `auth_identities` **مُدقَّق** (انتقالات الحالة).
- 27 دالة تستدعي `set_audit_context`؛ في كل منها آخر استدعاء إعادة فارغ (`null, null`) — مُثبت سلوكياً في `21`/`22` وبالفحص النصي هنا.
- الدوال التي تكتب بلا سياق: `otp_issue` (جدول بلا T7)، `platform_read_tenants` (تكتب صف N5 نفسه)، `new_tenant_account` (داخل `bootstrap_tenant`/`provision_*` وسياقها)، والـtriggers.
- N5: `platform_read_tenants` تقرأ وتدقّق في عبارة واحدة (`29`)؛ T5 يمنع UPDATE/DELETE/TRUNCATE حتى على المالك.

**R7**
- `auth.users.id = student_id / guardian_id / staff_id`: مفروض في `provision_student` (D1) و`provision_account` (I2) — `22`، `24`، `26`.
- G10: `auth_identities (auth_user_id, kind)` + FK مركّب من `profiles` و`system_users` + `identity_kind` ثابت بـCHECK؛ ثلاثة FKs إلى `auth.users`.
- R2: الاستثناءات الثلاثة فقط ملك `postgres` (`auth_uid`، `auth_user_updated_at`، `auth_password_changed_by_self_after`) — حارس `05` والعقد في `31`.
- D2: افتراض سجل Supabase Auth (`user_updated_password` بفاعل الحساب) يبقى اختبار عقد في pytest (`test_auth_contract.py`) يعمل في CI.
- D3: الهويات الاصطناعية في طبقة FastAPI؛ قاعدة البيانات لا تخزن بريداً اصطناعياً خارج `auth.users`.

**R8**
- `platform_tenants.host_label` و`schools.slug`: القيدان بنصيهما في DD (§2.1، §2.3) وفي `30`/`30b`؛ ERD §4.21 يذكرهما.
- الاتساق DB/API/Web: متجهات `docs/contracts/host_context_vectors.json` يقرؤها Vitest و pytest ويُفحص بها القيدان — مغلق في F3، لم يُعَد.

## 8. R9 — توافق الاستعادة

`scripts/restore-test.sh` يقارن بصمة المصدر بنسخة مستعادة من `pg_dump -Fc --create` بلا migrations. تغطية البصمة فئةً فئة:

| الفئة | قبل المراجعة | بعدها |
|---|---|---|
| خصائص القاعدة، مالكو الـschemas وACL | ✅ | ✅ |
| RLS + FORCE + ACL الجدول، ACL الأعمدة | ✅ | ✅ |
| القيود، الفهارس، السياسات، الـtriggers (التعريف) | ✅ | ✅ |
| الدوال: المالك، SECURITY DEFINER، ACL، الإعدادات، hash الجسم | ✅ | ✅ |
| الامتيازات الافتراضية، الأدوار الأربعة، قيم الـsequences، سجل الـmigrations، حسابات Auth، hash بيانات كل جدول | ✅ | ✅ |
| **تعريف الأعمدة** (النوع، NULL، الافتراضي، المحسوب، identity، الترتيب) | ❌ | ✅ `column` |
| **مالك الجدول** | ❌ | ✅ `table_owner` |
| **حالة الـtrigger** (مفعّل/معطّل) | ❌ | ✅ `trigger_state` |
| **مالك وACL الـsequences** | ❌ | ✅ `sequence_acl` |
| **الإضافات** (الاسم، الـschema، الإصدار) | ❌ | ✅ `extension` |

البصمة 929 ← 1360 سطراً. **أول تشغيل للفئات الجديدة كشف فرق تمثيل واحداً لا فرقاً فعلياً:** `app.temporary_id_seq` يحمل ACL صريحاً (`{app_owner=rwU}`) في المصدر و`NULL` بعد الاستعادة — ACL يساوي الافتراضي (المالك وحده) لا يكتبه `pg_dump`؛ طُبِّعت الفئة بـ`acldefault` فتطابقت. لا فرق في أي فئة أخرى، نظيفاً وببيانات الـseed. **ضابط سلبي** على النسخة المستعادة: تغيير افتراضي عمود، تعطيل trigger، منح على sequence، تغيير مالك جدول ← كل فئة جديدة (`column`، `trigger_state`، `sequence_acl`، `table_owner`) تُظهر الفرق. **L1 باقٍ:** الاستعادة إلى cluster جديد (الأدوار وصفاتها وعضوياتها — cluster-level لا يحملها dump القاعدة) لم تُختبر — Deferred مع سياسة الإنتاج.

## 9. سجل النتائج

### 9.1 C — يخالف التصميم المعتمد أو ينقص عنه (✅ مُصلحة كلها بعد الاعتماد — M31، M32؛ §12)

| # | النوع | النتيجة | المرجع المعتمد | الأثر | الإصلاح |
|---|---|---|---|---|---|
| **S1** | 🔴 أمني | مدير مدرسة يربط ولي أمر `pending` من مدرسة أخرى بطالب من مدرسته (`student_guardians` INSERT)، فيصير `guardian_in_scope`، فتنجح `begin/arm_guardian_temporary_password` — استيلاء على حساب لم يُستكمل. مُثبت على دوال DB (fixture `27`) | §1.1 بند 11؛ قصد D4 (المدرسة تصدر كلمة لأولياء أمور طلابها). §10.5 (الربط بلا رؤية) منفذة حرفياً ولا تُفتح | حساب ولي أمر + بيانات أبنائه في مدرسة أخرى، داخل الـTenant نفسه؛ يلزم `guardian.link` + `security.manage` ومعرفة UUID | ✅ **مُصلح — M31:** `student_guardians.relationship_source` — `provisioned` تكتبه `provision_guardian` وحدها، والإصدار يشترط ارتباطاً `provisioned` نشطاً بطالب في النطاق الحالي؛ **مصدر العلاقة جزء من الـinvariant**. لا `created_by` (الحزمة النهائية نقّحت صياغة S1-أ «أو فاعل آخر») — §12.1 |
| **S2** | 🔴 أمني | `students.family_id` يكتبه العميل و`WITH CHECK` لا يفحص الأسرة الهدف: موظف يسند طالبه إلى أسرة خارج نطاقه فيقرؤها ويعدّلها. مُثبت (fixture `17`) | §1.1 بند 11 | اسم وعنوان أسرة خارج النطاق، داخل الـTenant؛ يلزم `student.update` ومعرفة UUID | ✅ **مُصلح — M31:** `family_id IS NULL OR app.family_in_scope(family_id)` في WITH CHECK — الأسرة ضمن نطاق الفاعل أصلاً — §12.1 |
| **C1** | 🟠 امتيازات | `anon` و`authenticated` يملكان USAGE/SELECT/UPDATE على `public.audit_log_id_seq` و`public.login_challenges_id_seq`؛ والامتياز الافتراضي يمنحه لكل sequence جديدة | M20: «`anon` لا شيء»؛ secure-by-default: منح صريح فقط | **لا مسار عميل** (دوال الـsequences في `pg_catalog`، خارج المكشوف). بـSQL مباشر: `setval` على تسلسل التدقيق يُفشل كل كتابة مُدقَّقة | ✅ **مُصلح — M32:** السحب + الامتياز الافتراضي + حارسان في `20` — §12.2 |
| **C2** | 🟠 امتيازات | `authenticated` يملك `MAINTAIN` على 28 جدولاً، وعلى كل جدول جديد افتراضياً | M20: «نبدأ من الصفر ثم نمنح السجل حرفياً» — الـrevoke سرد الامتيازات بالاسم قبل `MAINTAIN` (PG17) | **لا مسار عميل.** بـSQL مباشر: `LOCK TABLE`/`VACUUM`/`REINDEX` — إتاحة لا بيانات | ✅ **مُصلح — M32:** السحب + الافتراضي + `MAINTAIN` في حراس `20` — §12.2 |
| **C3** | 🟡 فهارس | `families.platform_tenant_id` و`login_challenges.platform_tenant_id` بلا فهرس يبدأ بهما | المواصفة §3.4: «كل FK له فهرس يبدأ بأعمدته» | أداء فقط (لا حذف لصف Tenant أصلاً) | ✅ **مُصلح — M32:** الفهرسان؛ الاستثناء موثق (المواصفة §3.4، DD §3) ومحروس في `31` — §12.2 |

### 9.2 B — فجوات اختبار (مغلقة في `31_stage1_contract`)

| # | INV | القيد الذي لم يكن يُطابَق باسمه |
|---|---|---|
| B1 | I3 | `schools_school_code_chk` |
| B2 | I4 | `families_archived_chk`، `guardians_archived_chk`، `students_archived_chk` |
| B3 | I9 | `identity_scopes_standalone_chk` — وهو ما يمنع الالتفاف على FK النطاق بعلَم مزوَّر |
| B4 | I11 | `auth_identities_kind_chk` |
| B5 | I15 | `membership_scopes_membership_fk`، `membership_scopes_group_fk` |
| B6 | I23 | `guardians_profile_uq` |
| B7 | I27 | `student_guardians_student_fk` |

### 9.3 A — انحراف وثائق (مصحَّح in-place بعلامة «مراجعة Stage 1، 2026-10-01»)

| # | الوثيقة | التصحيح |
|---|---|---|
| A1 | DD §0.5b (جديد) | 23 قيد عدم فراغ منفذة غير مسرودة |
| A2 | DD §0.3 | مصفوفة الأعمدة المشتركة: 18 كاملة + 12 استثناءً بأسبابها |
| A3 | DD §2.3 | صف `guardian_first_login_mode` وقيده |
| A4 | DD §2.9، §2.16.1، §2.20 | الأعمدة المحسوبة وأعمدة G3 في جداول الأعمدة |
| A5 | DD §0.5 | أسماء قيود الهاتف المنفذة |
| A6 | DD §2.5، §2.9، §2.17، §2.24 | قيود الصيغ المنفذة و`roles_tenant_fk` |
| A7 | DD §4؛ المواصفة §3.3 | T8 يشمل `membership_scopes` INSERT (M19)؛ T7 «28 من 30» |
| A8 | RLS_MODEL §12، §15 | صف DELETE يذكر استثناء G2 |
| A9 | ERD §4.21 (جديد)؛ حالة ERD و DD | ملحق إضافات ما بعد Gate A؛ الحالة «معتمد ومنفَّذ» لا «مسودة» |
| A10 | CLAUDE.md §3 | خانات Gate C (C1–C10) و Gate D (D1–D7) مع ربطها بـM01–M23 |
| A11 | CLAUDE.md الرأس و§2 | تاريخ آخر تحديث، حالة المستودع، عدد الوثائق |
| A12 | PLAN_v3 §5 المرحلة 1 | خانات البنود المنفذة |
| A13 | TRACEABILITY | إحالة إلى مصفوفة R2 هنا وإلى `31` |
| A14 | F3_HOST_CONTEXT / CLAUDE | عدّ الاختبارات بعد `31` |

### 9.4 D — ملاحظات تصميم (لا تُفتح)

| # | الملاحظة |
|---|---|
| D1 | رؤية ولي الأمر بعد ربطه بطالب (`student_guardians` INSERT بلا رؤية مسبقة) — **معتمدة نصاً** في RLS_MODEL §10.5؛ S1-أ يغلق إدارة الحساب دون تغييرها. المطابقة بالهاتف مؤجلة للمرحلة 4 |
| D2 | تكليف موظف بـINSERT (`staff.assign` + مدرسة الهدف) — **معتمد بقرار 2026-09-25 (خيار b)**؛ الآلية نفسها (علاقة ينشئها الفاعل) دون مسار إدارة حساب اليوم. يُراجَع عند تصميم 5c/حسابات الموظفين |
| D3 | `profiles_select` مسار الذات بـ`auth.uid()`: صف الـprofile الذاتي يبقى مقروءاً والـTenant موقوف — كما في RLS_MODEL §10.1 (الذات بلا helper) |
| D4 | `auth_identities_auth_user_id_fkey` اسم مولَّد — تجميلي |
| D5 | backfill `host_label` في M30 يشتق عنواناً تلقائياً لصفوف قائمة — لا أثر (لا بيانات سبقته)؛ القاعدة المعتمدة لاحقاً (M30b) fail-before-mutation |

### 9.5 Deferred — مرحَّل بقرار، لا يمنع Stage 1

| البند | السبب | المرحلة | يؤثر على Stage 1؟ |
|---|---|---|---|
| **R5 teaching-assignment** — R5 teaching-assignment invariant cannot be fully enforced or tested until `teaching_assignments` is introduced in Phase 3 (`17` TODO، Matrix #12) | الجدول خارج Foundation | 3 | **No** |
| **I43** سعة الشعبة وسياسة الجنس | FastAPI / تجميع عددي | 4 | **No** |
| **Production Backup Policy** (RPO، RTO، retention، PITR، التشفير، الاستعادة إلى cluster جديد بأدواره — L1) | يتبع اختيار هدف النشر | قبل أي بيانات حقيقية | **No** |
| **I4** حدود معدّل Supabase Auth ومعالجة IP | إعداد نشر | الإنتاج | **No** |
| **5c** إعادة ضبط حساب active؛ هوية `tenant_admin`؛ تنبيهات القفل | قرارات مؤجلة مسجلة | 4–5 | **No** |
| البنود المفتوحة في CLAUDE.md §6 (1–8) | أسئلة أعمال | مراحلها | **No** |

## 10. الحراس الدائمة المضافة — `supabase/tests/31_stage1_contract.test.sql`

عقود مستقرة، حتمية، رخيصة، بلا بيانات متغيرة. أي تغيير مقصود يحدّث القائمة عمداً.

| الحارس | العقد |
|---|---|
| السياسات | القائمة بالاسم والأمر (61) — لا مضافة ولا محذوفة؛ كلها PERMISSIVE `TO authenticated`؛ الجداول الأربعة بلا سياسة بالاسم |
| الـtriggers | القائمة بالجدول والدالة والأحداث (61)؛ لا trigger معطّل |
| عقود الدوال | 71 دالة: التوقيع، المالك، SECURITY DEFINER، `search_path`، من يملك EXECUTE؛ لا EXECUTE لـ`PUBLIC` |
| السطح | لا دالة ولا view في `public`؛ `app` بلا جداول؛ لا `CREATE` لأدوار الـAPI؛ `anon` لا يصل `app` |
| FK ← فهرس (M32/C3) | كل FK في `public` له فهرس تبدأ أعمدته بأعمدة الـFK؛ الاستثناء الوحيد FK الهوية (`profiles`، `system_users`) بالاسم |

قائم سلفاً: قائمة الجداول و RLS/FORCE (`13`)، سجل الأعمدة و allowlist (`20`)، T7 (`11`). **لم تُحوَّل إلى حراس:** تفاصيل R1 (الأنواع، الافتراضيات) — تحرسها بصمة الاستعادة لا عقد معماري؛ وعقدا C1/C2 أُضيفا مع إصلاحهما (M32) إلى `20`: لا امتياز على أي sequence قائمة أو مستقبلية، و`MAINTAIN` ضمن الممنوع على الجداول والجدول المستقبلي.

**ضوابط سلبية (11):** سياسة مضافة/محذوفة/لـ`anon`، trigger معطّل/محذوف، ACL دالة موسَّع، مالك مغيَّر، `search_path` مُسقَط، EXECUTE لـ`PUBLIC`، دالة و view في `public` — كل واحد يُفشل حارسه.

## 11. ملحق — إثبات S1 و S2 (معاملات أُلغيت)

**S1** — fixture `27_guardian_onboarding`؛ الفاعل `school_admin` نطاقه SA، الهدف ولي أمر `pending` ابنه في SC فقط:

| الخطوة | النتيجة |
|---|---|
| `select … from guardians where id = G` | 0 صفوف |
| `app.begin_guardian_temporary_password(G)` | `P0002 not found` |
| `insert into student_guardians (طالب من SA, G, …)` | `ok` |
| `select phone_e164 from guardians where id = G` | الهاتف |
| `app.begin_guardian_temporary_password(G)` ثم `app.arm_guardian_temporary_password(G)` | معرّف الحساب، ثم `pending` |

**بعد M31:** الربط والقراءة كما هما (`direct`)، والخطوة الأخيرة `P0002` — `32`.

**S2** — fixture `17_relationship`؛ الفاعل مدير SA2، الأسرة `fama` طالبها الوحيد في SA1:

| الخطوة | النتيجة |
|---|---|
| `select count(*) from families where id = fama` | 0 |
| `update students set family_id = fama where id = <طالب SA2>` | `ok` |
| `select family_name from families where id = fama` | `fama` |
| `update families set address = … where id = fama` | `ok` |

**بعد M31:** الخطوة الثانية `42501` (RLS `students`) والأسرة تبقى غير مرئية — `32`.

## 12. الإصلاحات — M31 و M32 (2026-10-02)

بعد اعتماد الحزمة النهائية: الأمنية أولاً في migration مستقلة، ثم غير الأمنية. لا migration منفذة عُدِّلت.

### 12.1 M31 `security_relationship_source` — S1 و S2 (أمنية)

**S1 — صلاحية ربط ولي الأمر ≠ صلاحية إدارة حسابه:**
- `student_guardians.relationship_source text NOT NULL DEFAULT 'direct'` + `student_guardians_relationship_source_chk` (`direct`، `provisioned`). **خارج GRANT** (عمود بعد M20 لا يُمنح ضمنياً)؛ الصفوف القائمة تصير `direct` (fail-closed؛ لا بيانات حقيقية سبقته).
- `app.provision_guardian` تكتب `provisioned` — المصدر الوحيد (`create or replace`: التوقيع والمالك والـACL كما هي).
- `app.guardian_account_for_issue` (بوابة `begin`/`arm`) تشترط فوق ما سبق ارتباطاً **`provisioned` نشطاً** بطالب في النطاق الحالي (`student_in_scope`). `created_by` لا يدخل القرار.
- الربط المباشر (RLS_MODEL §10.5) لم يُمس: يُنشأ `direct` ويمنح الرؤية كما كان.

**S2 — `students_update` WITH CHECK** += `family_id IS NULL OR app.family_in_scope(family_id)`. دوال WITH CHECK تقرأ لقطة الجملة (الصف القديم — كما يعتمد M14)، فالطالب المنقول لا يجعل الأسرة الهدف ضمن النطاق بنفسه، والأسرة غير المتغيرة — ولو كان الطالب عضوها الوحيد — مقبولة. لا دالة جديدة.

**`32_security_relationship_source` (40):**

| الحالة | النتيجة |
|---|---|
| SA قبل أي ارتباط: رؤية ولي أمر سجّلته SB / `begin` | 0 صفوف / `P0002` |
| SA يربطه مباشرة بطالب من SA | ✅ `direct` — الربط المشروع يعمل |
| القراءة بعد الربط؛ `guardian_in_scope` | ✅ الهاتف؛ `true` |
| `begin` ثم `arm` بعد الربط المباشر | ❌ `P0002` — **السلسلة تفشل عند إدارة الحساب تحديداً** |
| العميل يكتب `relationship_source = 'provisioned'` (INSERT، UPDATE) | ❌ `42501` |
| `provision_guardian` على ولي الأمر نفسه (فرع idempotent) | يعود بلا ترقية الارتباط — `begin` ما زال ❌ |
| SB (سجّلته) — `begin`/`arm` | ✅ |
| SA يسجّل ولي أمر لطالبه بـ`provision_guardian` | ✅ `provisioned` ← حساب `pending` ← `begin`/`arm` ✅ |
| S2: نقل طالب SA إلى أسرة SB / أسرة فارغة / طالبين في جملة واحدة | ❌ `42501` (RLS `students`)؛ الأسرة تبقى غير مرئية |
| S2: أسرة في النطاق / `NULL` / تعديل الطالب العضو الوحيد / SB يعدّل طالبه | ✅ |
| البنية | النوع والافتراضي والقيد؛ لا GRANT للعمود؛ نص WITH CHECK؛ الدالتان وحدهما تذكران العمود |

fixture `27` حُدِّث: أولياء أمور تسجّلهم المدرسة = ارتباط `provisioned` (مسار C فيه يعتمد على ذلك).

**الضوابط السلبية (5) — كلها تُفشل `32`:** بوابة بلا شرط `provisioned` ← 4 · `provision_guardian` بلا العلامة (نصها قبل M31) ← 7 · WITH CHECK بلا شرط الأسرة ← 5 · البديل المرفوض (دالة أسرة تستثني الطالب الحالي) ← 3 — يمنع تعديلات مشروعة · منح العمود للعميل ← 6.

### 12.2 M32 `privilege_index_followup` — C1، C2، C3

- **C1:** `revoke all on all sequences in schema public from anon, authenticated` + الامتياز الافتراضي لـ`postgres` في `public`. أعمدة IDENTITY لا تحتاج امتيازاً على تسلسلها (T7 يكتب `audit_log` بدور `app_owner` الذي لا يملك عليه شيئاً — مثبت بالحزمة كاملة). افتراضيات `supabase_admin` لم تُمس.
- **C2:** `revoke maintain` على الجداول والافتراضي — الجدول الجديد يعطي `authenticated` SELECT وحده.
- **C3:** `families_tenant_idx`، `login_challenges_tenant_idx`؛ استثناء FK الهوية موثق (المواصفة §3.4، DD §3).
- **الحراس:** `20` (+2) — `MAINTAIN` في قائمتي `anon` و`authenticated` والجدول المستقبلي؛ لا امتياز على أي sequence في `public`/`app`؛ sequence مستقبلية بلا امتياز. `31` (+1) — كل FK في `public` له فهرس تبدأ أعمدته بأعمدة الـFK (الجزئي بشرط `IS NOT NULL` فقط) عدا FK الهوية بالاسم.

**الضوابط السلبية (10) — كل واحد يُفشل حارسه وحده:** `MAINTAIN` لـ`authenticated`، لـ`anon`، افتراضي `MAINTAIN`، USAGE على تسلسل التدقيق، على `app.temporary_id_seq`، افتراضي الـsequences، حذف كل من الفهرسين، استبداله بجزئي بشرط آخر، فهرس يبدأ بعمود آخر.

### 12.3 النتيجة

pgTAP **1483/1483** (36 ملفاً) على `db reset --no-seed`؛ تطبيقان متتاليان بلا فرق بنيوي في البصمة (الفرق الوحيد قيم الـsequences التي تقدّمها الاختبارات)؛ الاستعادة **PASS** نظيفة وبالـseed (187 فهرساً، 37 migration)؛ pytest **225/225** (مسار ولي الأمر C عبر `provision_guardian` في الـseed)؛ Vitest 87، lint، typecheck. **C جديدة: لا.**

**CI:** أخضر — `f41b0ff` (https://github.com/ahmedhmmad/sMas/actions/runs/36992802792). **🔒 Stage 1 مغلق (2026-10-02).**
