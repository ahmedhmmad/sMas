# M00 — نتائج التحقق (Gate I)

**التاريخ:** 2026-09-23
**المرجع:** `DB_IMPLEMENTATION_SPEC_v1.md` §12
**الاختبارات:** `spikes/m00/` — كل ملف داخل `BEGIN ... ROLLBACK`، لا أثر يبقى في قاعدة البيانات
**الدليل الخام:** `spikes/m00/out/*.tap` (مستثنى من git — يُعاد توليده بـ`node spikes/m00/run.mjs`)

---

## 0. بيئة التنفيذ — وحدودها

| البند | القيمة |
|---|---|
| Postgres | **17.6** (`public.ecr.aws/supabase/postgres:17.6.1.167` — الصورة نفسها التي يستعملها Supabase CLI 2.117.0) |
| المحرك | Podman 6.0.2 (WSL) |
| دور الاختبار | `postgres` — الدور الذي تعمل به migrations |

**التشغيل النهائي: حزمة Supabase المحلية الكاملة** (`supabase start`) على Podman — كل الأدلة أدناه من الحاوية `supabase_db_SMas` وواجهة Auth الحقيقية.

**مشكلة بيئية حُلّت دون إعادة تشغيل أي شيء:** Podman (rootful/WSL) ينشر المنافذ بقواعد DNAT داخل الـVM لا بمنفذ يستمع، فوسيط WSL لا ينقلها إلى `127.0.0.1` على Windows. الدليل:

```
VM IP:54398          reachable after 1s
127.0.0.1:54398      NOT reachable
داخل الـVM           no listening socket on 54398
```

الحل: `scripts/podman-relay.mjs` — وسيط TCP بلا dependency على Windows: `127.0.0.1:{54321,54322}` ← `<VM IP>`. لم تُغيَّر إعدادات Podman، ولم تُعَد تشغيل الـVM، ولم تُمَس حاويات المشاريع الأخرى.

(التشغيل الأول لـV1–V7 وجزء DB من V8 تم على صورة قاعدة البيانات نفسها كحاوية مستقلة `smas_m00_db` قبل حل مشكلة المنافذ؛ أُعيد كل شيء على الحزمة الكاملة بنتائج مطابقة.)

---

## 1. الملخص

| # | يُثبت | النتيجة | تحققات |
|---|---|---|---|
| **V1** | `FORCE RLS` + `SECURITY DEFINER` بلا recursion | ✅ | 3/3 |
| **V2** | `BYPASSRLS` للمالك، والمالك المخصص | ✅ **R2 معتمد** — المالك المخصص عبر `app.auth_uid()` | 17/17 |
| **V3** | أمان `search_path`، هوية الفاعل، `EXECUTE` | ✅ + اكتشاف | 6/6 |
| **V4** | GENERATED + FK مركّب | ✅ | 7/7 |
| **V5** | `NULLS NOT DISTINCT` | ✅ | 4/4 |
| **V6** | `ON UPDATE CASCADE` بتواريخ + CHECK تحت `FORCE` | ✅ | 4/4 |
| **V7** | جدول بلا سياسة تحت `FORCE` + أداة الكشف | ✅ | 4/4 |
| **V8** | Saga إنشاء الحساب | ✅ | 8/8 DB + 5/5 HTTP |
| | **المجموع** | ✅ **M00 أخضر بالكامل** | **58/58** |

---

## 2. النتائج التفصيلية

### V1 — `FORCE RLS` + `SECURITY DEFINER` ✅

```
V1.fn_owner          = postgres
V1.owner_direct_rows = 3        ← المالك تحت FORCE يرى الكل: يحمل BYPASSRLS
V1.user_a_rows       = 2        ← tenant 1 فقط
V1.user_c_rows       = 1        ← tenant 2 فقط
```

سياسة على `profiles` تستدعي دالة `SECURITY DEFINER` تقرأ `profiles` نفسها — **بلا recursion** تحت `FORCE`. البديل (إسقاط `FORCE` عن جداول مصدر التفويض) **غير لازم**.

### V2 — مالك الدوال ✅ R2

> **القرار (2026-09-23):** المالك المخصص + `app.auth_uid()`. `postgres` احتياط فقط. الاختبار أدناه أُعيد كتابته ليختبر إعداد R2 كاملاً، وسجلّ المحاولة الأولى (البديل) محفوظ تحته للتاريخ.

```
V2.owner_attrs                      = login=f bypassrls=t super=f createrole=f
V2.schema_owner                     = postgres
V2.direct_auth_uid_from_owner       = ERR 42501: permission denied for schema auth
V2.wrapper_owner                    = postgres
V2.wrapper_config                   = search_path=""
V2.helper_owner                     = m00_owner
V2.user_a_rows / user_c_rows        = 2 / 1
V2.wrapper_called_by_authenticated  = ERR 42501: permission denied for function auth_uid
V2.helper_under_service_role        = <null>
V2.owner_replace_wrapper            = ERR 42501: must be owner of function auth_uid
V2.owner_drop_wrapper               = ERR 42501: must be owner of function m00.auth_uid
V2.after_attempts_user_b_tenant     = 11111111-…   ← السلسلة سليمة بعد التلاعب
```

**تصحيح على ملاحظتي السابقة (R4):** كتبت أن `app_owner` يجب أن **يملك** schema `app`. هذا كان سيفتح ثغرة: مالك الـschema يحذف أي كائن داخله، فيستطيع حذف الوسيط وإعادة إنشائه ليُرجع هوية مزوَّرة. الإعداد المُثبت: الـschema ملك `postgres`، و`app_owner` يُمنح `USAGE, CREATE` فقط — `CREATE` تكفي لنقل الملكية ولا تسمح بحذف كائن الغير (مُثبت: `owner_drop_wrapper = ERR 42501`).

#### السجل التاريخي — المحاولة الأولى

```
V2.current_user              = postgres
V2.rolsuper                  = false
V2.rolbypassrls              = true
V2.rolcreaterole             = true
V2.service_role_bypassrls    = true
V2.authenticated_bypassrls   = false
V2.create_dedicated_owner    = ok
V2.reassign_owner            = ok      (بعد إصلاحين — أدناه)
V2.fn_owner_after_reassign   = m00_owner
V2.dedicated_owner_user_a_rows = ERR 42501: permission denied for schema auth
```

**ما ثبت:**
1. `postgres` يحمل `BYPASSRLS` وليس superuser → V1 يعمل به.
2. إنشاء دور مخصص يحمل `BYPASSRLS` **ممكن**.
3. نقل الملكية إليه يتطلب شرطين في Postgres 16+: أن يكون المنفِّذ عضواً فيه (`grant m00_owner to postgres`)، وأن يملك الدور المخصص `CREATE` على الـschema.
4. **🔴 الدالة التي يملكها الدور المخصص لا تستطيع استدعاء `auth.uid()`.** schema `auth` يملكه `supabase_auth_admin`، و`postgres` لا يملك حق منح `USAGE` عليه (`WARNING: no privileges were granted for "uid"`).

**الأثر:** كل الدوال المساعدة تعتمد على `auth.uid()`، فمتطلب «owner مخصص» (§5.0.2 رقم 7) **غير قابل للتطبيق كما صيغ**.

**مجس لم يغيّر التصميم** — وسيط `SECURITY DEFINER` يملكه `postgres` ويُرجع `auth.uid()`، يستدعيه الدور المخصص:

```
V2alt.wrapper_owner_user_a_rows = 2
V2alt.wrapper_sees_caller       = aaaaaaaa-0000-0000-0000-000000000001
```

→ المالك المخصص **يعمل** عبر وسيط واحد. انظر §3.

**تصحيح على اختباراتي:** النسخة الأولى من V2 نجحت دون أن تختبر المالك المخصص فعلاً — نقل الملكية فشل بصمت فقيس الرقم والدالة ما زالت ملك `postgres`. التحققات الآن تفرض أن `fn_owner_after_reassign = m00_owner`.

### V3 — أمان الدوال ✅ + اكتشاف

```
V3a.whoami_inside_definer   = aaaaaaaa-…-000000000001   ← هوية المستدعي، لا المالك
V3a.current_user_inside_call = authenticated
V3b.count_safe              = 3      ← search_path ثابت يتجاهل جدول المهاجم
V3b.count_unsafe            = 100    ← ضابط سلبي: بدونه الهجوم ينجح
V3c.default_anon_exec       = true   ← ⚠️
V3c.fresh_schema_fn_acl     = <null = PUBLIC default>
V3c.after_revoke_anon_exec  = false
V3c.m20_anon_executable_count = 0
```

**(a)** `auth.uid()` داخل `SECURITY DEFINER` تبقى هوية المستدعي — شرط T8 والتدقيق ودوال §5.2 متحقق.
**(b)** الهجوم عبر `pg_temp` **حقيقي** (الضابط السلبي نجح)، و`SET search_path = …, pg_temp` يمنعه.
**(c) 🔴 اكتشاف:** أي دالة في schema جديد (مثل `app`) **قابلة للتنفيذ من `anon` افتراضياً** — `proacl` فارغ = `PUBLIC` يملك `EXECUTE`. الصلاحيات الافتراضية في Supabase مضبوطة لـ`public`, `storage`, `graphql*` فقط:

```
postgres/public       = {…, anon=X, authenticated=X, service_role=X}
supabase_admin/public = {…, anon=X, authenticated=X, service_role=X}
(لا صفوف لـschema جديد)
```

**الأثر على التنفيذ:** `REVOKE` لكل دالة على حدة يعتمد على عدم النسيان. الأصح أن يُضاف إلى M01 عند إنشاء schema `app`:

```sql
alter default privileges in schema app revoke execute on functions from public;
```

فتولد كل دالة لاحقة **بلا** `EXECUTE` لأحد، و`GRANT` صريح لكل ما يُسمح به. هذا تطبيق للمتطلب 7 المعتمد لا قرار جديد.

> **🔴 تصحيح — اكتشفه اختبار M01:** التوصية أعلاه (`IN SCHEMA app`) **لم تكن مُختبَرة وهي بلا أثر**. V3c اختبر `REVOKE` لكل دالة، ثم أوصيت بآلية أخرى دون تجربتها. في Postgres الصلاحيات الافتراضية المقيّدة بـschema **تضيف فقط** ولا تسحب منح `PUBLIC` العالمي. الدليل (معاملة مُلغاة على الحزمة الكاملة):
>
> ```
> A  IN SCHEMA app، دالة ينشئها postgres             anon=true    ← بلا أثر
> B  FOR ROLE app_owner، دالة ينشئها app_owner        owner=app_owner anon=false authenticated=false
> C  دالة ينشئها postgres في public                  anon=true    ← لا أثر جانبي
> ```
>
> **المُطبَّق في M01:** `alter default privileges for role app_owner revoke execute on functions from public;` + قاعدة: دوال `SECURITY DEFINER` في `app` تُنشأ تحت `set local role app_owner`.

### V4 — GENERATED + FK مركّب ✅

```
V4a.scope_for_standalone       = ok
V4a.scope_for_grouped_school   = ERR 23503 (FK على العمود المحسوب)
V4c.join_group_with_scope      = ERR 23503 (تغيير group_id يُرفض)
V4b.system_role_into_T1        = ok
V4b.own_custom_role_into_T1    = ok
V4b.foreign_role_honest_key    = ERR 23514 (CHECK)
V4b.foreign_role_forged_key    = ERR 23503 (FK)
```

I9 و I16 إعلانيان كما صُمِّما. **T1 يبقى ملغى.** وتغيير `group_id` لمدرسة تملك نطاقاً يُرفض من المحرك — الانضمام لمجموعة يمر إلزامياً بإجراء الدمج.

### V5 — `NULLS NOT DISTINCT` ✅

```
V5.server_version                     = 17.6
V5.plain_unique_duplicate_tenant_scope = accepted   ← ضابط سلبي: خطأ D8 حقيقي
V5.nnd_duplicate_tenant_scope          = ERR 23505
V5.nnd_second_school_scope             = accepted
```

### V6 — `ON UPDATE CASCADE` بتواريخ ✅

```
V6.insert_term_outside_year     = ERR 23514
V6.extend_year                  = ok        (terms بلا أي سياسة لـauthenticated)
V6.terms_year_end_after_extend  = 2027-07-31
V6.shrink_year_excluding_term   = ERR 23514
```

التسلسل المرجعي يعمل تحت `FORCE RLS` ولا يعتمد على سياسات الجدول الابن، والـCHECK يُعاد تقييمه. **T4 يبقى ملغى.**

### V7 — جدول بلا سياسة ✅

```
V7.read_without_policy  = 0                          ← منع صامت، بلا خطأ
V7.write_without_policy = ERR 42501
V7.read_with_policy     = 2
V7.detector_flags       = rls_disabled:rls_disabled,without_policy:no_select_policy
```

القراءة من جدول بلا سياسة **لا تُظهر خطأ** — تُرجع صفراً. هذا بالضبط سبب إلزامية أداة الكشف. الاستعلام يلتقط الجدولين غير المحميين **وحدهما**؛ يُستعمل حرفياً في اختبار T3 بعد M13–M18.

### V8 — Saga ✅

**جزء DB (8/8)** — حسابات Auth أُدرجت بـSQL داخل المعاملة بدل Admin API:

```
V8a.service_role_auth_uid   = <null>              ← شرط إعفاء G7 محدد
V8b.provision_ok            = created actor=<caller>
V8b.retry_same_id           = exists              ← idempotency
V8b.rows_for_student        = 1/1                 ← profile + student + enrollment مرة واحدة
V8c.provision_fails_midway  = ERR 23503 … "enrollments" …
V8c.profile_left_for_auth2  = 0                   ← ذرية: لا profile ولا student
V8c.students_total          = 1
V8d.unauthorized_caller     = ERR 42501: forbidden
V8d.anon_can_execute        = false
```

**تصحيح على اختباراتي:** المحاولة الأولى لـV8c استعملت مدرسة غير موجودة، فرُفضت عند فحص التفويض **قبل** أي إدراج — لم تختبر الذرية. الإصلاح: تفويض على مدرسة غير موجودة، فيجتاز الفحص ويُدرج الـprofile والطالب ثم يفشل عند الـenrollment.

**جزء HTTP (5/5)** — Supabase Auth Admin API الحقيقي، بنمط الـSaga كما سيعمل FastAPI:

```
V8e.create_status               = 200
V8e.id_honored                  = true         ← المعرّف المولَّد مسبقاً يصبح auth.users.id
V8e.retry_status                = 422
V8e.retry_error_code            = email_exists ← إعادة المحاولة لا تُكرِّر الحساب
V8e.lookup_by_id_status         = 200          ← الحساب القائم يُسترجع بالمعرّف: الاستئناف ممكن
V8f.compensating_delete_status  = 200
V8f.after_delete_lookup_status  = 404          ← الحذف التعويضي يزيل الحساب
```

**أثر مباشر على F2 و FastAPI:** معرّف الطالب المولَّد مسبقاً = `auth.users.id` = مفتاح الـidempotency. إعادة المحاولة: `422 email_exists` ← `GET /admin/users/{id}` ← متابعة من الخطوة 3. لا جدول idempotency منفصل لازم.

---

## 3. ما يترتب على النتائج

| # | البند | النوع | الحالة |
|---|---|---|---|
| R1 | V2: البديل المحدد مسبقاً (`postgres` مالكاً) | بديل §12 | مُستبدَل بـR2 — احتياط فقط |
| R2 | V2: **المالك المخصص عبر `app.auth_uid()`** | ✅ **معتمد 2026-09-23** | مُطبَّق في المواصفة و`RLS_MODEL_v1.md` §4.5؛ 17/17 |
| R3 | V3c: `ALTER DEFAULT PRIVILEGES FOR ROLE app_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` + الإنشاء بهوية `app_owner` (صيغة `IN SCHEMA` الأولى بلا أثر — مُصحَّحة) | تطبيق لمتطلب 7 المعتمد | ✅ M01، 21/21 |
| R4 | V2: نقل الملكية يتطلب `grant app_owner to postgres` + `CREATE` لـ`app_owner` على الـschema. **الـschema يبقى ملك `postgres`** (مُصحَّح — انظر V2) | تفصيل تنفيذ | ✅ في M01 |
| R5 | V8e/V8f وإقلاع Supabase الكامل | بيئي | ✅ عبر `scripts/podman-relay.mjs` |

**لا تحقق فشل بما يستدعي إعادة تصميم.** V2 فشل بصيغته الأولى، فطُبِّق البديل المحدد مسبقاً، ثم اعتُمد R2 بعد إثباته عملياً.
