# Gate E6 — النسخ الاحتياطي واختبار الاستعادة

**الحالة:** 🔒 **E6 Technical Database Backup/Restore: CLOSED** (2026-09-26، CI `c985a0d`) · **Production Backup Policy: TBD** (§4)

> **النطاق:** استعادة **قاعدة بيانات** من backup كامل داخل خادم قائم. لا يثبت **استعادة خادم PostgreSQL كامل إلى خادم جديد** (L1) — ذلك جزء من سياسة Production.

**الأدوات:** `scripts/restore-test.sh`، `scripts/db-fingerprint.sql` · **CI:** خطوتان (§2.3)

> E6 شرط قبل أي بيانات حقيقية (`PLAN_v3.md` §3 بند 20). ما أُنجز هنا يثبت أن **backup كامل يعيد بناء الحالة**؛
> ما لم يُنجز هو **سياسة** النسخ في Production، ولا تُحسم قبل اختيار هدف النشر.

---

## 1. ما الذي يثبته الاختبار — وما الذي لا يثبته

**restore من backup ≠ إنشاء schema جديد ثم تشغيل migrations.** القاعدة الهدف تُبنى **من الـdump وحده**:
لا `supabase db reset` ولا migrations عليها. سجل الـmigrations نفسه (`supabase_migrations.schema_migrations`)
جزء من المستعاد ويُقارن (27 صفاً). لذلك لا خطوة «تشغيل migrations بعد الاستعادة» — الطريقة لا تتطلبها،
وتشغيلها كان سيُخفي أي نقص في الـbackup بإعادة إنشاء ما لم يُحفظ.

الإثبات بطبقتين:

| الطبقة | الأداة | يثبت |
|---|---|---|
| **المطابقة** | بصمة سطرية للمصدر والنسخة ← `diff` = 0 | كل عنصر بنية وكل صف بيانات هو نفسه |
| **السلوك** | الحزمة كاملة (26 ملفاً، 1157 تحققاً) على النسخة المستعادة | العزل والتفويض والقيود والدوال تعمل فعلاً، لا أنها موجودة فقط |

---

## 2. الإجراء

### 2.1 الخطوات (مطابقة لطلب E6)

| # | الخطوة | التنفيذ |
|---|---|---|
| 1 | المصدر من migrations | `supabase db reset --no-seed` (الجولة 2) أو `db reset` (الجولة 1) |
| 2 | بيانات اختبار | seed E5 (الجولة 1): Tenant، مجموعة، 3 مدارس، مستخدم لكل دور، Platform Admin، تسجيلات وتدقيق |
| 3 | backup | `pg_dump -Fc --create` — كامل: كل الـschemas بما فيها `auth` و`supabase_migrations` |
| 4 | قاعدة فارغة جديدة | `CREATE DATABASE` من جملة الـdump نفسه (الترميز والـlocale)، ثم **خصائص القاعدة** من الـdump: المالك، `ALTER DATABASE SET`، ACL، التعليق (§3 ف1) |
| 5 | restore | `pg_restore --single-transaction --exit-on-error` — أي خطأ يفشل كل شيء |
| 6 | migrations بعد الاستعادة | **لا تُشغَّل** (§1)؛ سجلها يُقارن ضمن البصمة |
| 7 | التحقق | البصمة (§2.2) — `diff` صفر، وبصمة غير فارغة |
| 8 | الحزمة كاملة | `supabase test db --db-url …/smas_restore` |
| 9 | التسجيل | هذه الوثيقة + CI |

### 2.2 البصمة — `scripts/db-fingerprint.sql`

سطر لكل عنصر `<فئة> | <مفتاح> | <قيمة>`، مرتب حتمياً. على الجولتين: **883 سطراً، diff = 0**.

| الفئة | العدد | المحتوى |
|---|---|---|
| `database` | 3 | المالك، ACL، إعدادات `ALTER DATABASE SET` |
| `schema` | 5 | مالك وACL لـ`public`, `app`, `auth`, `extensions`, `supabase_migrations` |
| `table` | 29 | RLS + FORCE + ACL الجدول |
| `column_acl` | 111 | صلاحيات الأعمدة (سجل §4.6) |
| `constraint` | 266 | النوع + التعريف |
| `index` | 181 | التعريف |
| `policy` | 69 | الأمر، الأدوار، USING، WITH CHECK |
| `function` | 52 | المالك، SECURITY DEFINER، ACL، `search_path`، md5 النص |
| `trigger` | 61 | التعريف |
| `default_acl` | 28 | الامتيازات الافتراضية (secure-by-default، M20) |
| `role` | 4 | `app_owner` (BYPASSRLS)، `authenticated`، `anon`، `service_role` |
| `sequence` | 2 | آخر قيمة (`temporary_id_seq`، `audit_log_id_seq`) |
| `migration` | 27 | الإصدار + الاسم |
| `auth` | 1 | عدد `auth.users` + hash (id، email، كلمة المرور المشفرة) |
| `data` | 29 | عدد صفوف كل جدول + md5 محتواه — يشمل البيانات المرجعية (73 / 10 / 255 / 9) |

### 2.3 النتائج

| الجولة | المصدر | restore | البصمة | الحزمة على النسخة |
|---|---|---|---|---|
| 1 — البيانات | `db reset` (seed E5) | 0 أخطاء | ✅ 883، diff 0 | — |
| 2 — السلوك | `db reset --no-seed` | 0 أخطاء | ✅ 883، diff 0 | ✅ **1157/1157** (R5 TODO كما هو) |

**CI:** الجولة 2 بعد pgTAP، والجولة 1 بعد خطوة الـseed — في كل push.

### 2.4 الضوابط السلبية — البصمة تكشف كل انحراف

كل انحراف أُدخل على النسخة المستعادة (أو إجراء خاطئ) وظهر في الـdiff بسطره:

| # | الانحراف | السطر المكتشف |
|---|---|---|
| a | الإجراء الساذج: `createdb` + `pg_restore` بلا خصائص القاعدة | `database owner` supabase_admin ≠ postgres؛ ACL وإعدادات مفقودة |
| b | `NO FORCE ROW LEVEL SECURITY` على `students` | `table students … force=f` |
| c | `students_select` بـ`USING (true)` | `policy students.students_select … using=true` |
| d | `GRANT UPDATE (identity_scope_id)` لـ`authenticated` | `column_acl students.identity_scope_id` |
| e | استبدال نص `app.require_reason` | `function … config=- body=<md5 مختلف>` |
| f | حذف ربط واحد من `role_permissions` | `data role_permissions 255 → 254` |
| g | تعديل وصف صلاحية | `data permissions 73 <hash مختلف>` |

وضابط على البصمة نفسها: استعلام فاشل كان يُنتج بصمتين فارغتين «متطابقتين» (ظهر في أول محاولة) — لذلك
`ON_ERROR_STOP` في البصمة، والسكربت يرفض بصمة فارغة.

---

## 3. ما كشفه الاختبار

| # | البند | الأثر | المعالجة |
|---|---|---|---|
| **ف1** | `pg_dump` بلا `--create` لا يحمل خصائص القاعدة (المالك، ACL، الإعدادات). الاستعادة إلى قاعدة يملكها `supabase_admin` جعلت `postgres` خارج `pg_database_owner` — مالك schema `public` في PG15+ — فسقط عنه `CREATE` على `public` | الحزمة فشلت على النسخة المستعادة (`permission denied for schema public` في 02 و20)؛ **والبصمة الأولى لم تكشفه** لأنها لم تشمل مستوى القاعدة والـschemas | الإجراء: `--create` وتطبيق جمل مستوى القاعدة من الـdump نفسه بالاسم الجديد. البصمة: فئتا `database` و`schema` (الضابط a) |
| **ف2** | `07` I12 كان يطابق `memberships_tenant_profile_uq`، والـinvariant في المواصفة هو `memberships_profile_uq` (`UNIQUE (profile_id)`). الإدراج يخرق الاثنين دائماً، وأيهما يُبلَّغ يتبع ترتيب إنشاء الفهارس: الـmigrations تنشئ الأوسع أولاً، و`pg_restore` بترتيب الأسماء | التحقق نجح بالمصادفة على المصدر وفشل على النسخة — لم يكن يثبت I12 | `07` يعزل I12: يُسقط القيد الأوسع داخل الـsubtransaction نفسها (تُلغى مع الرفض) فلا يرفض إلا `memberships_profile_uq` — يمر على المصدر والنسخة. `TRACEABILITY_E1_E4.md` صُحِّح. **لا تغيير في migration** |

ف2 مثال على قيمة التشغيل على النسخة المستعادة: قاعدة «مطابقة اسم القيد» (M08) كانت محققة شكلاً،
والاعتماد الخفي على ترتيب الـOIDs لا يظهر إلا حين يتغير ترتيب الإنشاء.

---

## 4. سياسة Production — TBD

لا تُحسم قبل اختيار هدف النشر. **لا قيم افتراضية مخترعة.**

| البند | القيمة |
|---|---|
| Production target | **TBD** |
| RPO | **TBD** |
| RTO | **TBD** |
| Retention | **TBD** |
| Backup frequency | **TBD** |
| WAL/PITR policy | **TBD** |
| Encryption/access policy | **TBD** |
| مكان حفظ النسخ | **TBD** |
| Restore procedure (Production) | **TBD** |
| اختبار استعادة إلى **خادم جديد بالكامل** بما فيه الأدوار على مستوى الخادم (`app_owner`، أدوار Supabase) | **TBD** — L1 |

---

## 5. حدود ما ثبت — تُحسم مع هدف النشر

| # | الحد | لماذا يهم |
|---|---|---|
| L1 | الاستعادة في **نفس الـcluster** وبنفس صورة Supabase | الأدوار كائنات على مستوى الـcluster لا يحملها `pg_dump`: `app_owner` (مالك كل دوال SECURITY DEFINER، BYPASSRLS) وأدوار Supabase يجب أن توجد في الـcluster الهدف **قبل** الاستعادة (`pg_dumpall --globals-only` أو ما يوفره المزود). استعادة إلى cluster جديد لم تُختبر |
| L2 | اختبار **منطقي** (`pg_dump`) | لا يثبت PITR/WAL ولا النسخ الفيزيائية — يتبع سياسة WAL/PITR (§4) |
| L3 | خارج الـdump: إعدادات Auth (GoTrue)، أسرار JWT الحقيقية، مفاتيح `service_role`، Storage objects (غير مستعملة في Foundation) | الاستعادة الكاملة لبيئة = قاعدة + إعدادات البيئة؛ تُوثَّق مع هدف النشر |
| L4 | الـdump يحوي `auth.users` بكلمات مرورها المشفرة وكل بيانات الـTenants | ملف الـbackup بحساسية القاعدة نفسها — سياسة التشفير والوصول (§4) شرط قبل أول backup لبيانات حقيقية |
| L5 | لا اختبار زمني (RTO) ولا حجمي | الزمن الحالي ثوانٍ على بيانات صغيرة؛ القياس الفعلي مع الحجم الحقيقي |

---

## 6. التشغيل محلياً

```bash
export DOCKER_HOST=npipe:////./pipe/podman-machine-default   # Podman (CLAUDE.md §2)
npx supabase db reset --no-seed
CONTAINER_CLI=podman bash scripts/restore-test.sh --run-tests    # السلوك
npx supabase db reset
CONTAINER_CLI=podman bash scripts/restore-test.sh                # البيانات
```

القاعدة الهدف `smas_restore` تُحذف وتُنشأ في كل تشغيل؛ المصدر لا يُمس.
