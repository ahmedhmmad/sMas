"""تدقيق ما لا يلتقطه T7: قراءة Platform Admin لبيانات Tenant (N5) وكل عملية `*.export`
(DB_IMPLEMENTATION_SPEC_v1.md §7.4: «FastAPI يكتب صفاً بـservice role»).

- **داخل معاملة الطلب نفسها:** فشل الكتابة يُلغي المعاملة ويمنع إرجاع البيانات (fail closed).
- **الفاعل من قاعدة البيانات** تحت هوية المستخدم (`current_profile_id` / `current_system_user_id`) قبل تبديل الدور —
  لا من الـclaims؛ التصنيف مطابق لـT7 (tenant_user ← platform_admin).
- **`service_role` لجملة الإدراج وحدها** ثم العودة إلى `authenticated`؛ هذا الملف هو الموضع الوحيد في الخدمة الذي
  يبدّل إلى `service_role` (يحرسه اختبار).
- `action` = `read` / `export`: سجل وصول، منفصل عن صلاحية `audit.read` (عرض السجل) — الرؤية بسياسات M18 كما هي.
"""

from typing import Any

import psycopg
from psycopg.types.json import Jsonb


class AuditActorMissing(RuntimeError):
    """طلب بلا فاعل في قاعدة البيانات لا يُسجَّل باسم أحد — ولا يُرجَع."""


def write_access_audit(
    conn: psycopg.Connection,
    *,
    action: str,
    entity_type: str,
    entity_ids: list[str],
    platform_tenant_id: Any,
    school_id: Any = None,
    details: dict[str, Any] | None = None,
) -> None:
    actor = conn.execute(
        "select app.current_profile_id() as profile_id, app.current_system_user_id() as system_user_id"
    ).fetchone()
    if actor["profile_id"] is not None:
        actor_type, actor_id = "tenant_user", actor["profile_id"]
    elif actor["system_user_id"] is not None:
        actor_type, actor_id = "platform_admin", actor["system_user_id"]
    else:
        raise AuditActorMissing()

    conn.execute("select set_config('role', 'service_role', true)")
    with conn.cursor() as cur:
        cur.executemany(
            "insert into public.audit_log"
            " (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, source)"
            " values (%s, %s, %s, %s, %s, %s, %s, %s, 'api')",
            [
                (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, str(eid), Jsonb(details))
                for eid in entity_ids
            ],
        )
    conn.execute("select set_config('role', 'authenticated', true)")
