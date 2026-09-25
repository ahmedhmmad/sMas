# Gate E — Traceability E1–E4

**التاريخ:** 2026-09-26 · **الأساس:** Gate C مكتمل (M01–M23) · **المجموعة الكاملة:** 1157 اختباراً في 26 ملفاً

كل متطلب يُتتبَّع إلى **الملف ومفتاح التحقق** (`k = '…'`، أثبت من رقم السطر) وما **يثبته بالضبط**.

| الحالة | المعنى |
|---|---|
| ✅ Proven | تحقق يثبت الجزء المحدد من المتطلب؛ الرفض مطابق **باسم القيد/السياسة/الرسالة** لا بـSQLSTATE وحده |
| ◐ Partial | التحقق موجود لكنه لا يثبت الجزء المحدد، أو يطابق بـSQLSTATE وحده |
| ⏳ TODO | مؤجل بقرار؛ اختبار `TODO` يفشل عمداً حتى مرحلته |
| ➖ خارج DB | يُنفَّذ في طبقة أخرى بقرار (FastAPI) — يُذكر مكانه |

**تسمية:** `RLS-I1` = اختبار العزل I1 في `RLS_MODEL_v1.md` §15؛ `INV-I1` = الـinvariant I1 في `DB_IMPLEMENTATION_SPEC_v1.md` §3 — الترقيمان منفصلان في الوثائق ومتصادمان في الأرقام.

**قاعدة الرفض (من M08، مطبَّقة هنا):** تحقق الرفض يثبت أن **القيد المقصود** هو الذي رفض — `like 'ERR <sqlstate>%<constraint_name>%'`. ترتيب الفحص في Postgres: `NOT NULL`/`CHECK` ← `UNIQUE`/`EXCLUDE` ← `FK` ← (سياسات RLS `WITH CHECK` قبل القيود؛ triggers `BEFORE` قبل RLS، `AFTER` بعد القيود).

---

## E1 — قالب اختبار العزل

النمط المستعمل في 14–22 هو القالب المعتمد لكل جدول من المرحلة 2 فصاعداً:

```sql
begin;
create temp table r (k text primary key, v text) on commit drop;       -- نتائج مسجلة لا assertions متناثرة
create function pg_temp.rec(p_key text, p_sql text) ...               -- يلتقط القيمة أو 'ERR <sqlstate>: <message>'
create function pg_temp.run(p_key text, p_label text, p_sql text) ... -- الفاعل: request.jwt.claims + set local role authenticated|anon
-- Fixture: Tenantان؛ Group بمدرستين؛ مدرسة مستقلة؛ فاعل لكل حالة:
--   tenant scope / group scope / school scope / عدة scopes / صلاحية بلا scope (P1) / scope بلا صلاحية (P2) /
--   Tenant آخر / Platform Admin بكل الصلاحيات / anon / (الطالب، ولي الأمر إن كان للجدول مسار علاقة)
-- القراءة: قائمة كاملة مرتبة لكل فاعل (string_agg … order by … collate "C") — تثبت المرئي وغير المرئي معاً
-- الكتابة: لكل رفض ضابط إيجابي؛ الرفض مطابق باسم السياسة/القيد
select plan(N);
select is((select v from r where k = 'vis.<actor>'), '<exact list>', '<what it proves>');
select ok((select v from r where k = 'w.<case>') like 'ERR 42501%row-level security%<table>%', '<rule>');
select ok((select v from r where k = 'c.<case>') like 'ERR 23503%<constraint_name>%', '<invariant>');
select policies_are('public', '<table>', array[...], 'exactly the policies of this migration');
select * from finish();
rollback;
```

**قواعد القالب:**

1. **القائمة الكاملة لا العدد:** `'SA1,SA2'` لا `2` — العدد الصحيح قد يخفي صفاً خاطئاً.
2. **ضابط إيجابي لكل رفض:** وإلا نجح الرفض لسبب آخر (fixture مكسور) دون أن يثبت شيئاً.
3. **اسم القيد/السياسة في كل رفض** (القاعدة أعلاه) — والرسالة للدوال المتحكَّم بها (`forbidden`، `not found`، `T8: …`).
4. **ضابط سلبي عند كل قرار تصميم:** يُشغَّل الاختبار نفسه بالنص الحرفي البديل داخل معاملة تُلغى، ويُوثَّق أنه يفشل (استُعمل في M14، M15، M17، M19، M21b، M22، M23).
5. **الحالة المنشورة لا المؤقتة:** إن احتاج الاختبار امتيازاً مؤقتاً (مثل SELECT على `audit_log` قبل M20) يُمنح داخل المعاملة ويُثبت أولاً غيابه.
6. **لا اعتماد على seed.sql** (B8 §8.3): كل ملف ينشئ بياناته؛ البيانات المرجعية من M23 تُستعمل كما هي، والأكواد الاختبارية بادئتها `zt_`.

---

## E2 — `AUTHORIZATION_MATRIX_v1.md` §16 (الـ15)

| # | المتطلب | الملف → التحقق | ما يثبته | الحالة |
|---|---|---|---|---|
| 1 | Tenant A cannot read Tenant B | `14_isolation` → `sweep.ta` + `populated`؛ `tenants/groups/schools.t2a`؛ `16` `vis.t2a`؛ `17` `students.t2a`…؛ `18` `vis.t2a` | مسح كل جدول يحمل `platform_tenant_id`/`school_id` (21 جدولاً، كلها ببيانات T2) بلا صف واحد من T2؛ وقوائم كاملة لكل جدول سياسات | ✅ |
| 2 | Tenant scope sees all authorized schools but no other Tenant | `14` → `schools.ta` = `SA1,SA2,SB1,SS` | كل مدارس T1 ولا شيء من T2 | ✅ |
| 3 | Group scope sees all schools in Group and none outside | `14` → `schools.gm` = `SA1,SA2`؛ `16` `vis.gm` | مدرستا المجموعة، لا GB ولا المستقلة | ✅ |
| 4 | School scope sees only that school | `14` → `schools.sa1`، `w.sa1_rename_SA2 = 0`؛ `16` `vis.sa1`؛ `17` `students.sa1` | مدرسته وحدها، لا الشقيقة في المجموعة نفسها (§1.1 بند 5) | ✅ |
| 5 | Multiple school scopes work simultaneously | `14` → `schools.multi` = `SA2,SS`؛ `16` `vis.multi`، `w.multi_term_SS` | قراءة وكتابة بنطاقين معاً | ✅ |
| 6 | Same user cannot have two Tenant profiles (O1) | `14` → `i6.second_profile` (`profiles_auth_user_uq`)؛ `03` `o1.same_auth_second_tenant`؛ `22` `ps.reused_auth` | UNIQUE عالمي على `auth_user_id`، وعبر مسار الإنشاء أيضاً | ✅ |
| 7 | `current_tenant_id()` returns exactly one Tenant | `14` → `i6.ta`؛ `03` `fn.current_tenant_as_a`؛ `21b` `before/during/after.ctx` | حتمية بـO1، و NULL للـTenant الموقوف | ✅ |
| 8 | Read does not imply Export | `17` → `p3.tch` | حامل `student.read` لا يملك `student.export` | ✅ (طبقة DB) + ➖ القناة: FastAPI (RLS §12.2، Gate F4) |
| 9 | Permission without Scope → no access | `14` `*.noscope`؛ `16` `vis.noscope`، `w.noscope_stage` | صفر صفوف ورفض الكتابة | ✅ |
| 10 | Scope without Permission → no access | `14` `*.noperm`؛ `15` `w.tch_assign_fresh`؛ `16` `vis.noperm`؛ `17` `students.noperm` | صفر صفوف ورفض الكتابة | ✅ |
| 11 | Guardian sees only linked students | `17` → `students.gp` = `sa,sm` | أبناؤه بارتباط نشط فقط؛ لا زميل في المدرسة نفسها، ولا ارتباط منتهٍ | ✅ |
| 12 | Teacher operation requires teaching assignment | `17` → R5 (`todo_start`)، والسلوك الحالي موثق | — | ⏳ D1 (`teaching_assignments`، المرحلة 3) |
| 13 | Platform Admin has no implicit Tenant data access | `15` `profiles/members/roles/perms.pa`؛ `16` `vis.pa`؛ `17` `students/enr/guard/staff/fam.pa`؛ `18` `e16.*`؛ `06` `hpp.admin_student`؛ `07` `plat.*` | بكل صلاحيات المنصة لا يرى بيانات العملاء؛ `is_platform_admin()` لا يمنح شيئاً | ✅ |
| 14 | Cross-tenant FK combinations are rejected | `04` `s.cross_tenant_grp` (`schools_group_fk`)، `is.cross_tenant_school`؛ `07` `m.cross_tenant` (`memberships_profile_fk`)، `mr.wrong_tenant`، `ms.cross_tenant_school`؛ `09` `*_other_tenant`، `sg.cross_tenant`؛ `10` `tenant.mismatch` | كل FK مركّب `(…, platform_tenant_id)` يرفض باسمه | ✅ (G2 أُغلق) |
| 15 | Archived/closed entities obey operational-state rules without exposing deleted data | `21` (15 دالة: انتقالات صريحة + invariants)؛ `20` `b.archive`، `b.*_status`؛ لا DELETE (`20` DELETE على G2 فقط) | الحالات تتغير بالدوال وحدها؛ لا حذف فعلي فلا بيانات محذوفة | ✅ — ملاحظة: RLS لا تُخفي الصفوف المؤرشفة (المؤرشف ≠ المحذوف)؛ إخفاؤها في الواجهات قرار لاحق إن طُلب |

## E2 — `RLS_MODEL_v1.md` §15

### 15.1 العزل

| # | الملف → التحقق | الحالة |
|---|---|---|
| RLS-I1 | `14` `sweep.ta` (21 جدولاً، غير فارغة) + قوائم 14–18 | ✅ |
| RLS-I2 | `14` `schools.sa1`، `w.sa1_rename_SA2`؛ `16` `vis.sa1` | ✅ |
| RLS-I3 | `14` `groups.gm`، `schools.gm` | ✅ |
| RLS-I4 | `14` `schools.gm` (لا `SS`) | ✅ |
| RLS-I5 | `14` `schools.multi`؛ `16` `vis.multi` | ✅ |
| RLS-I6 | `14` `i6.ta`، `i6.second_profile` | ✅ |
| RLS-I7 | `14` `i7.tenant_as_platform` (`system_users_identity_fk`)، `i7.platform_as_tenant` (`profiles_identity_fk`)، `i7.overlap` | ✅ |

### 15.2 Permission و Scope

| # | الملف → التحقق | الحالة |
|---|---|---|
| P1 | `14` `*.noscope`؛ `16` `vis.noscope`، `w.noscope_stage` | ✅ |
| P2 | `14` `*.noperm`؛ `16` `vis.noperm`؛ `17` `students.noperm` | ✅ |
| P3 | `17` `p3.tch` | ✅ DB + ➖ القناة F4 |
| P4 | `07` `hp.sa_export` (دور معطَّل لا يمنح شيئاً)؛ `21` `ro.off` (التعطيل انتقال حالة) | ✅ |

### 15.3 العلاقة التشغيلية

| # | الملف → التحقق | الحالة |
|---|---|---|
| R1 | `17` `students.gp` | ✅ |
| R2 | `17` `students.sa`، `enr.sa` | ✅ |
| R3 | `17` `students.ta`/`sa1` (لا `sn`)؛ `12` `student_in_scope.*` | ✅ |
| R4 | `17` `students.bus` | ✅ (يُعاد مع البذر الحقيقي: `23` يثبت أن `bus_supervisor` بلا `student.read`) |
| R5 | `17` `todo_start` + السلوك الحالي | ⏳ D1 |

### 15.4 منع التصعيد

| # | الملف → التحقق | الحالة |
|---|---|---|
| E1 | `17` `u.sa1_enr_move`؛ `20` `b.enr_school` | ✅ (طبقتان: صلاحية العمود ثم WITH CHECK) |
| E2 | `17` `u.sa1_student_tenant`؛ `20` `b.groups_tenant` | ✅ |
| E3 | `15` `w.sa1_scope_SB1_fresh` | ✅ |
| E4 | `19` `r1.e4` | ✅ (T8، ضابط سلبي بلا trigger) |
| E5 | `23` E5 + حارس داخل M23 | ✅ |
| E6 | `20` DELETE على G2 فقط + `14`/`15`/`16`/`17` `d.*` | ✅ |
| E7 | `17` `students/enr/guard/staff/fam.pa` | ✅ |
| E8 | `15` `*.pa`؛ `05` `admin.*` (هوية فقط) | ✅ |
| E9 | `15` `w.sa1_scope_tenant_fresh`، `w.sa1_scope_tenant_self` | ✅ |
| E10 | `14` `w.gm_school_GB` | ✅ |
| E11 | `15` `profiles.grd` | ✅ |
| E12 | `15` `members.gm` | ✅ |
| E13 | `15` `w.sa1_assign_multi` | ✅ |
| E14 | `15` `w.sa1_assign_empty_self` (خطوة 1)؛ `19` `r2.f5_step1/2` (الخطوتان) | ✅ |
| E15 | `18` `vis.acc` | ✅ |
| E16 | `18` `e16.students`، `e16.other` | ✅ |
| E17 | `14` `i7.*`؛ `03` `g10.*`؛ `05` `g10.*` | ✅ |

### 15.5 السلامة التقنية

| # | الملف → التحقق | الحالة |
|---|---|---|
| T1 | `12` `rls.*` (الدوال تحت FORCE RLS)؛ وكل اختبارات السياسات 14–22 تعمل بدور `authenticated` عبر الدوال | ✅ |
| T2 | `13` (29 جدولاً بالاسم؛ غير المدرج يُفشل) | ✅ |
| T3 | `13` T3 — كل جدول بسياسة SELECT عدا الاستثناءات الثلاثة الموثقة | ✅ (G4 أُغلق) |
| T4 | `11` `t5.*` (service بالصلاحية، المالك بالـtrigger `rows are immutable`)؛ `20` | ✅ |

---

## E3 — القيود (`DB_IMPLEMENTATION_SPEC_v1.md` §3)

كل رفض أدناه مطابق **باسم القيد** (بعد G1).

| INV | القيد | الملف → التحقق (اسم القيد) | الحالة |
|---|---|---|---|
| I1 | `tenant_code` فريد | `03` `pt.dup_code` (`platform_tenants_tenant_code_uq`) | ✅ |
| I2 | الأكواد/slug داخل Tenant | `04` `g.dup_code` (`groups_tenant_code_uq`)، `s.dup_code`، `s.dup_slug` | ✅ |
| I3 | صيغ الأكواد | `03` `pt.bad_code`؛ `04` `g.bad_code`، `s.bad_slug`؛ `05` `par.bad_code`؛ `06` `p.bad_format`، `r.bad_code` | ✅ |
| I4 | status ↔ archived/suspended | `03` `pt.suspend_no_ts`؛ `04` `s.archive_no_ts`؛ `05` `paa.revoke_no_ts`؛ `07` `m.end_no_ts`؛ `09` `st.archive_no_ts` | ✅ |
| I5 | مدرسة → مجموعة من نفس Tenant | `04` `s.cross_tenant_grp` (`schools_group_fk`) | ✅ |
| I6 | الأكواد ثابتة | `20` السجل (لا UPDATE على أعمدة الأكواد)، `b.family_code` | ✅ |
| I7 | نطاق هوية واحد على الأكثر | `04` `is.second_scope_*` (`identity_scopes_group_uq`/`_school_uq`) | ✅ |
| I8 | نطاق واحد على الأقل (T9) | `04` T9 (العدّ لكل مجموعة/مدرسة مستقلة)؛ `11` تدقيق T9 | ✅ |
| I9 | مدرسة داخل Group بلا نطاق خاص | `04` `is.scope_for_grouped_school`، `is.join_group_with_scope` (`identity_scopes_school_standalone_fk`) | ✅ |
| I10 | `auth_user_id` فريد (O1) | `03`، `14` (`profiles_auth_user_uq`) | ✅ |
| I11 | Tenant أو Platform لا الاثنان (G10) | `03` `g10.*`، `05` `g10.*`، `14` `i7.*` | ✅ |
| I12 | Profile ↔ Membership 1:1 | `07` `m.second_membership` (`memberships_tenant_profile_uq`) | ✅ |
| I13 | شكل النطاق | `07` `ms.bad_shape` (`membership_scopes_shape_chk`) | ✅ |
| I14 | لا تكرار نطاق (NULLS NOT DISTINCT) | `07` `ms.dup_tenant`، `ms.dup_group` (`membership_scopes_uq`) | ✅ |
| I15 | النطاق من Tenant العضوية | `07` `ms.cross_tenant_school` (`membership_scopes_school_fk`) | ✅ |
| I16 | دور نظام أو من Tenant العضوية | `07` `mr.foreign_honest` (`membership_roles_owner_chk`)، `mr.foreign_forged` (`membership_roles_role_fk`) | ✅ |
| I17 | `is_system ↔ tenant IS NULL` | `06` `r.system_not_flagged`، `r.custom_flagged` (`roles_is_system_chk`) | ✅ |
| I18 | `code = resource.operation` | `06` `p.parts_mismatch` (`permissions_code_parts_chk`)؛ `23` صيغة الكتالوج | ✅ |
| I19 | T8 | `19` (المتطلبات الثلاثة) | ✅ |
| I20 | النطاق الممنوح ⊆ الفاعل | `15` E3، E9، `w.sa1_scope_group_fresh` | ✅ |
| I21 | سلطة على العضوية الهدف | `15` E13، `d.sb1_*`، `w.sa1_scope_SA1_acc` | ✅ |
| I22 | `employee_code` داخل Tenant | `09` `st.dup_code` | ✅ |
| I23 | حساب ↔ موظف/ولي أمر 1:1 | `09` `st.profile_twice`، `g.profile_*` | ✅ |
| I24 | مدرسة أساسية نشطة واحدة للموظف | `09` `ssa.second_primary` (+ إيجابيان) | ✅ |
| I25 | هاتف ولي الأمر فريد + E.164 | `09` `g.dup_phone`، `g.bad_phone`؛ `22` `pg.phone` (`guardians_tenant_phone_uq`) | ✅ |
| I26 | ولي أمر أساسي نشط واحد | `09` `sg.second_primary` | ✅ |
| I27 | الطالب/ولي الأمر/الأسرة/النطاق من نفس Tenant | `09` `s.*_other_tenant`، `sg.cross_tenant` | ✅ |
| I28 | `official_id` داخل نطاق الهوية | `09` `s.dup_official_same_scope` | ✅ |
| I29 | معرّف واحد على الأقل | `09` `s.no_identifier` | ✅ |
| I30 | `student_profile_id` 1:1 إلزامي | `09` `s.no_profile`، `s.profile_twice` | ✅ |
| I31 | `temporary_id` يولّده النظام | `09` `s.bad_temp_format`، `s.dup_temp`؛ `02` التوليد؛ `20` لا عمود `temporary_id` في السجل؛ `22` `ps.shape` | ✅ |
| I32 | `full_name` مولَّد | `09` | ✅ |
| I33 | سنة نشطة واحدة | `08` `ay.second_active` (`academic_years_active_uq`)؛ `21` `y.act_busy` | ✅ |
| I34 | لا تداخل سنوات | `08` `ay.overlap`، `ay.touching_end` (`academic_years_no_overlap`) | ✅ |
| I35 | الفصل داخل السنة | `08` `t.outside_year`، `t.shrink_year` (`terms_within_year_chk`)، `t.forged_bounds` (`terms_year_fk`) | ✅ |
| I36 | لا تداخل فصول | `08` `t.overlap` (`terms_no_overlap`) | ✅ |
| I37 | المرحلة/الصف/الشعبة من نفس المدرسة | `08` `gl.stage_other_school`، `sec.year_other_school`، `sec.grade_other_school` | ✅ |
| I38 | تسجيل نشط واحد | `10` `i38.duplicate_active` | ✅ — محتوى في G6 (استثناء M10 الموثق) |
| I39 | السنة/الصف/الشعبة متسقة | `10` `i39.*` | ✅ |
| I40 | المدرسة داخل نطاق هوية الطالب (G3) | `10` `g3.*` | ✅ |
| I41 | لا تداخل تسجيلات (G6) | `10` `g6.*` | ✅ |
| I42 | status ↔ effective_to | `10` `b6.*`؛ `09` `ssa.active_with_end`، `sg.active_with_end` | ✅ |
| I43 | سعة الشعبة وسياسة الجنس | — | ➖ FastAPI / المرحلة 4 (بقرار) |

---

## E4 — التدقيق (§3 I44–I46 + B7)

| المتطلب | الملف → التحقق | الحالة |
|---|---|---|
| I44 / T4 — غير قابل للتعديل أو الحذف | `11` `t5.service_*` (`permission denied`)، `t5.owner_*` (`rows are immutable` — حتى المالك)؛ `02` T5 عام؛ `20` | ✅ |
| I45 — كل تغيير يُسجَّل (T7 على 28 جدولاً) | `11` «T7 attached to 28 tables»، insert/update/delete، الحذف المتسلسل، صفوف T9 | ✅ |
| I46 — `created_by`/`updated_by` لا تُزوَّر (T6) | `02` T6 (القيم المزوَّرة تُتجاهل، `created_*` ثابتة، `granted_by`) | ✅ |
| الفاعل (`actor_type`/`actor_id`) مستقل عن `created_by` | `11` system / tenant_user / platform_admin (حيث لا `created_by`)؛ `21` `au.actor`؛ `22` `bt.audit` | ✅ |
| النطاق (`platform_tenant_id`/`school_id`) | `11` اشتقاق الـTenant من المدرسة؛ دور مخصص تحت Tenant الدور | ✅ |
| `old_values`/`new_values` | `11` «old and new values captured»، الحذف بلا new | ✅ |
| `action` لانتقالات الحالة | `11` `app.audit_action`؛ `21` `au.*` لكل انتقال | ✅ |
| `reason` | `11`؛ `21` `au.tenant`، `au.staff_f2`، `au.enr_s3`، `au.new_s3` | ✅ |
| `source` (غير موثوق، لا يُفشل الكتابة) | `11` «known source kept»، «unknown source coerced to api» | ✅ |
| `ip_address` (أول `x-forwarded-for`؛ غير الصالح NULL) | `11` | ✅ |
| entity id للمفاتيح المركبة | `11` `role_permissions`، `membership_roles`، `auth_identities` | ✅ |
| إعادة سياق التدقيق فارغاً بعد كل كتابة (متطلب M11) | `11` «reason not carried over»؛ `21` `au.ctx_leak`؛ `22` `#ctx` | ✅ |
| الرؤية F10 / F11 / E15 / E16 | `18` | ✅ |
| تسجيل القراءات والتصدير (§7.4، N5) | — | ➖ FastAPI (Gate F4)؛ `11` يثبت أن `service_role` يملك INSERT لذلك |

---

## الفجوات — وُجدت وأُغلقت في هذه الجولة (اختبارات فقط، بلا migrations)

| # | المجال | الفجوة | الإغلاق |
|---|---|---|---|
| **G1** | E3 | 74 تحقق رفض في 02–08، 11، 22 (مكتوبة قبل قاعدة M08) طابقت بـSQLSTATE وحده، و16 تحقق «not found» في 21–22 | كل رسالة التُقطت فعلياً وشُدِّد كل تحقق على اسم القيد الذي أطلقها؛ الرسائل كلها أطلقها القيد المقصود **عدا G2** |
| **G2** | E3 / Matrix #14 | `07` `m.cross_tenant` ادّعى «عضوية لا تربط profile بـTenant آخر»، والذي أطلقه فعلاً `memberships_profile_uq` (للـprofile عضوية سلفاً) — الـFK المركّب لم يُختبر | fixture بـprofile بلا عضوية؛ الرفض الآن `memberships_profile_fk` |
| **G3** | Matrix #8 / P3 | لا تحقق أن `read` لا يعني `export` | `17` `p3.tch` (طبقة الصلاحية؛ القناة في F4) |
| **G4** | RLS T3 | لا تحقق أن كل جدول بسياسة SELECT | `13` T3 مع الاستثناءات الثلاثة الموثقة بالاسم |

## ما يبقى خارج الإغلاق — بقرار لا بنقص

| البند | السبب |
|---|---|
| Matrix #12 / R5 | D1: `teaching_assignments` (المرحلة 3) — `TODO` يفشل عمداً |
| P3 (القناة) | التصدير قناة FastAPI (RLS §12.2) — Gate F4 |
| تسجيل قراءات Platform Admin والتصدير | FastAPI (§7.4، N5) — Gate F4 |
| INV-I43 | FastAPI / المرحلة 4 |
| إخفاء الصفوف المؤرشفة | RLS لا تفرّق بالحالة؛ المؤرشف ≠ المحذوف — قرار لاحق إن طُلب |
