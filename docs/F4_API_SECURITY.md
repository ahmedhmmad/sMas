# Gate F4 — هيكل FastAPI وحد الأمان

**الحالة:** ✅ منفذ (2026-09-26) — بانتظار المراجعة · **الكود:** `services/api/` · **الاختبارات:** 48/48 (pytest، CI)

---

## 1. المبدأ

```text
JWT ──► FastAPI (تحقق من التوقيع فقط) ──► قاعدة البيانات (RLS + app.*) ──► البيانات
```

**وليس** `JWT → FastAPI authorization → DB → RLS` — مصدران للحقيقة.

| الطبقة | تفعل | لا تفعل |
|---|---|---|
| FastAPI | تتحقق من JWT؛ تفتح معاملة باسم المستخدم؛ تطرح الأسئلة على دوال DB القائمة؛ تكتب تدقيق القراءة/التصدير | لا تقرأ tenant/school/دور/صلاحية من الـclaims ولا من الطلب؛ لا تعيد تنفيذ `has_permission` أو `can_access_*` |
| قاعدة البيانات | RLS، `app.has_permission`، `app.can_access_school`، الدوال المتحكَّم بها، T7 | — مصدر الحقيقة |

---

## 2. القرار — مسار الوصول إلى قاعدة البيانات (2026-09-26)

**FastAPI تتصل بدور `authenticator` — آلية PostgREST نفسها.** كل طلب = معاملة واحدة:

```sql
select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', <الـpayload الذي تحقق منه FastAPI>, true);
-- ثم الاستعلامات: RLS ودوال app.* تقرر
```

| لماذا | |
|---|---|
| `authenticator` | `LOGIN NOINHERIT`، عضو في `authenticated`/`anon`/`service_role` — لا يملك بذاته شيئاً؛ لا دور جديد ولا migration |
| الدوال المتحكَّم بها | schema `app` غير معروض عبر PostgREST؛ FastAPI قناتها (§1.1 بند 13: «FastAPI orchestrates and invokes the operation») |
| التدقيق الذري | صف تدقيق القراءة/التصدير في المعاملة نفسها ← فشله يلغي الاستجابة (fail closed) |
| لا مفتاح `service_role` | الخدمة لا تحمله؛ تبدّل إلى دور `service_role` لجملة إدراج التدقيق وحدها (`audit.py`) — §7.4 من المواصفة |

البديل المرفوض: تمرير JWT إلى PostgREST — لا يصل إلى `app.*` إلا بعرض schema `app` أو wrappers في `public`، والتدقيق غير ذري.

**التحقق من JWT:** بالمفتاح العام من JWKS (`/auth/v1/.well-known/jwks.json`)، خوارزمية مثبتة `ES256` (قابلة للضبط بـ`API_JWT_ALGORITHMS`)، `aud = authenticated`، `iss = {SUPABASE_URL}/auth/v1`، `exp`/`iat`/`sub`/`role` إلزامية، `role = authenticated`، `sub` UUID. المفتاحان القديمان `anon`/`service_role` (HS256) لا يمران.

---

## 3. نقاط الإثبات (endpoints)

| المسار | يثبت |
|---|---|
| `GET /me` | السياق مشتق من DB: `current_profile_id` / `current_tenant_id` / `current_system_user_id` |
| `GET /schools/{id}`، `GET /schools/{id}/students` | قراءة تحت RLS؛ غير المرئي = `404` (لا يُكشف وجوده) |
| `GET /schools/{id}/students/export` | **P3:** `app.has_permission('student.export') AND app.can_access_school(id)` — مفتاح التصدير نفسه بصيغة السياسات؛ الصفوف نفسها تحت RLS؛ تدقيق |
| `GET /platform/tenants/{id}` | **N5:** سياق المنصة من DB (G10)؛ الصف بسياسة `has_platform_permission('tenant.read')`؛ تدقيق قبل الإرجاع |

**تدقيق الوصول** (`action` = `read` / `export`): سجل وصول منفصل عن صلاحية `audit.read` (عرض السجل). الفاعل من DB تحت هوية المستخدم (تصنيف T7). **التصدير: صف لكل طالب مُصدَّر** (`entity_type = students`) مع `export_id` يجمعها — فتتبع الرؤية سياسات M18 كما هي: من يرى الطالب/المدرسة يرى الصف، و**Platform Admin لا يراه** (F11). صف `entity_type = schools` كان سيظهر لـPlatform Admin.

---

## 4. التتبع — جدول اختبارات F4 المطلوب

| الاختبار | المتوقع | الاختبار في `services/api/tests/` | |
|---|---|---|---|
| Valid JWT | وصول وفق صلاحيات DB | `test_tokens::test_valid_jwt_is_accepted`، `test_isolation::test_context_is_derived_from_db` | ✅ |
| Invalid JWT | 401 | `test_tokens::test_invalid_jwt_is_401` (بلا header، Bearer فارغ، نص، Basic)؛ وحدة: منتهٍ، aud/iss خاطئ، بلا sub/role، sub غير UUID | ✅ |
| Tampered JWT | 401 | `test_tampered_jwt_is_401` (انتحال `sub`، ادعاء دور/tenant في `app_metadata`، تمديد `exp`)، `test_signature_swapped_is_401`، وحدة: مفتاح آخر، `alg=none`، HS256 | ✅ |
| User A → School A | سماح حسب الصلاحية | `test_user_a_reaches_school_a` | ✅ |
| User A → School B | رفض | `test_user_a_cannot_reach_school_b` (SB في المجموعة نفسها، SS مستقلة) + ضابط إيجابي: `tenant_admin` يراهما | ✅ |
| تغيير `school_id` في الطلب | لا يرفع authority | `test_forged_school_context_does_not_raise_authority` (headers + query) | ✅ |
| إضافة/تغيير role | لا يرفع authority | `test_forged_role_and_tenant_do_not_change_context`، `test_forged_role_does_not_grant_export` | ✅ |
| إضافة/تغيير tenant | لا يرفع authority | `test_forged_role_and_tenant_do_not_change_context`، `test_forged_platform_claim_does_not_open_platform_route` | ✅ |
| Read بدون Export | read يعمل، export مرفوض | `test_export::test_read_without_export` (secretary، accountant — بلا صف تدقيق)؛ `test_export_outside_scope_is_rejected`؛ إيجابي: `test_export_with_permission_is_audited_per_student` | ✅ |
| Platform Admin sensitive read | بصلاحية المنصة فقط + audit | `test_platform_read`: مُدقَّق بفاعل `platform_admin` = system_user من DB؛ مستخدمو Tenant ← 403؛ سحب الإسناد ← 404 بلا تدقيق؛ fail closed؛ فشل بعد الكتابة يلغيها | ✅ |
| `service_role` في browser | غير ممكن | `test_tokens::test_project_api_keys_are_not_user_tokens`؛ `test_service_role`: الخدمة لا تقرأ المفتاح، التبديل إلى `service_role` في `audit.py` وحده، كل معاملة `authenticated`، لا استجابة تحمل مفتاحاً أو اتصال DB | ✅ جانب الخادم — الواجهة F1 |
| Suspended tenant | سلوك M21b قائم | `test_suspension`: السياق NULL، المدرسة 404، التصدير 403؛ المنصة ترى `suspended`؛ إعادة التفعيل تعيد الوصول | ✅ |

### 4.1 الضوابط السلبية — الاختبارات تفشل حين يُكسر التصميم

| # | الكسر المتعمَّد | فشل |
|---|---|---|
| b | بوابة التصدير بـ`student.read` بدل `student.export` | 3 (secretary، accountant، الدور المزوَّر) |
| c | فك JWT بلا تحقق من التوقيع | 8 (المُعدَّل، التوقيع المبدَّل، aud/iss، مفتاح آخر) |
| d | مسار المنصة بلا تدقيق | 2 |
| e | المعاملة بدور `authenticator` بلا انتقال إلى `authenticated` | 7 |

(`alg=none` و HS256 بقيا مرفوضين في (c) لأن الخوارزمية تُثبَّت قبل فك الرمز.)

---

## 5. ملاحظات للمراجعة — لا تغيير

| # | الملاحظة |
|---|---|
| O1 | **`tenant_admin` يرى صفوف قراءة Platform Admin لـTenant نفسه** (صف tenant-level بلا `school_id` — فرع `can_access_tenant` في `audit_log_tenant_select`، M18). شفافية للعميل بما قرأه مشغّل المنصة؛ نتيجة السياسات القائمة لا سياسة جديدة. إن كان غير مرغوب فقرار مستقل |
| O2 | تصدير بلا صفوف لا يكتب صف تدقيق (لا كيان يُسجَّل عليه ولا بيانات خرجت) |
| O3 | `404` لغير المرئي (لا يميّز «غير موجود» من «خارج النطاق»)؛ `403` لرفض صلاحية صريح (التصدير، مسار المنصة) |
| O4 | `ip_address` في صفوف تدقيق الوصول فارغ — يُضاف مع F1/البنية (proxy موثوق) |
| O5 | الإنتاج: إن بقي مشروع Supabase على مفتاح JWT قديم (HS256) فالتحقق يحتاج السر المشترك — التصميم الحالي يفترض مفاتيح توقيع غير متماثلة (JWKS)؛ يُحسم مع هدف النشر |
| O6 | endpoints الإثبات بصيغة JSON؛ صيغ التصدير (CSV/PDF) وحدود الحجم مع وحداتها |

**خارج F4:** F1 (الواجهة)، F2 (المصادقة: معرّف الطالب الاصطناعي، OTP ولي الأمر)، F3 (subdomain — اختبار أنه لا يرفع السلطة يُكتب هناك؛ F4 أثبت أن أي سياق في الطلب لا يؤثر).

---

## 6. التشغيل

```bash
export DOCKER_HOST=npipe:////./pipe/podman-machine-default     # محلياً (CLAUDE.md §2)
npx supabase db reset                                         # seed E5 مطلوب للاختبارات
cd services/api
python -m venv .venv && .venv/Scripts/python -m pip install -r requirements.txt
.venv/Scripts/python -m pytest                                # المتغيرات من `supabase status` تلقائياً
```

الخدمة: `SUPABASE_URL` و`API_DATABASE_URL` (انظر `.env.example`) ثم `uvicorn app.main:app`.
