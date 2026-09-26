"""إعدادات الخدمة — من متغيرات البيئة فقط؛ لا قيمة سرية في الكود (PLAN_v3.md §3.3 بند 12).

لا مفتاح `service_role` هنا. تتصل الخدمة بقاعدة البيانات بدور `authenticator` (آلية PostgREST نفسها) وتنتقل إلى
`authenticated` لكل طلب مستخدم؛ ولا تنتقل إلى دور `service_role` إلا في موضعين: صف التدقيق (audit.py) وحل معرّف
دخول الطالب (student_login.py). المفتاح السري لـAuth Admin API يقرؤه auth_admin.py وحده، لا هذا الملف.
المفتاح المنشور (publishable) عام بطبيعته — يصل إلى المتصفح أصلاً.
"""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    database_url: str
    jwt_algorithms: tuple[str, ...]
    jwt_audience: str
    publishable_key: str
    min_password_length: int

    @property
    def jwt_issuer(self) -> str:
        return f"{self.supabase_url}/auth/v1"

    @property
    def jwks_url(self) -> str:
        return f"{self.jwt_issuer}/.well-known/jwks.json"


def load_settings() -> Settings:
    return Settings(
        supabase_url=os.environ["SUPABASE_URL"].rstrip("/"),
        database_url=os.environ["API_DATABASE_URL"],
        # خوارزميات غير متماثلة فقط: التحقق بالمفتاح العام من JWKS، والمفاتيح القديمة HS256 (anon، service_role) تُرفض
        jwt_algorithms=tuple(a.strip() for a in os.environ.get("API_JWT_ALGORITHMS", "ES256").split(",") if a.strip()),
        jwt_audience=os.environ.get("API_JWT_AUDIENCE", "authenticated"),
        publishable_key=os.environ["SUPABASE_PUBLISHABLE_KEY"],
        # يطابق `minimum_password_length` في إعداد Supabase Auth (كلمة المرور الأولية للطالب = معرّفه)
        min_password_length=int(os.environ.get("API_MIN_PASSWORD_LENGTH", "6")),
    )
