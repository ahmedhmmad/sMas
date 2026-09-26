"""دخول الطالب بـOfficial ID أو Temporary ID (D1).

المسار: (tenant، مدرسة، معرّف) ← `app.resolve_student_login` تحت دور `service_role` (قبل وجود JWT) ←
البريد الاصطناعي ← Supabase Auth (password grant) ← الجلسة كما يصدرها Supabase Auth نفسه. لا JWT يُصنع هنا.

- الـtenant والمدرسة يحددان **أين يُبحث** فقط (الـslug فريد داخل الـTenant)؛ لا يمنحان سلطة — الجلسة الناتجة
  هوية الطالب وحدها، والسياق يُشتق في قاعدة البيانات كأي مستخدم (F4). في F3 يأتيان من الـsubdomain.
- **استجابة واحدة لكل فشل** (`401 invalid_credentials`): لا يميّز العميل بين معرّف غير موجود وكلمة مرور خاطئة،
  ولا مدرسة ولا tenant ولا حالة الطالب. وحتى عند فشل البحث يُستدعى Supabase Auth ببريد عشوائي كي لا يكشف
  الزمن وجود المعرّف.
- **حدّ المحاولات** لكل معرّف ولكل عنوان: `429` بالشرط نفسه سواء وُجد المعرّف أم لا.
- هذا الملف ثاني موضع (بعد audit.py) يبدّل إلى دور `service_role` — لجملة الحل وحدها.
"""

import threading
import time
import uuid
from collections import defaultdict, deque

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .auth_admin import student_email
from .db import Database
from .deps import db

router = APIRouter()

_INVALID = HTTPException(status_code=401, detail="invalid_credentials")
_TOO_MANY = HTTPException(status_code=429, detail="too_many_attempts")
SESSION_FIELDS = ("access_token", "refresh_token", "expires_in", "token_type")


class AttemptLimiter:
    """نافذة منزلقة في الذاكرة. حدّ لكل عملية؛ تعدد النسخ يحتاج مخزناً مشتركاً (ملاحظة F2)."""

    def __init__(self, limit: int, window_s: float):
        self.limit, self.window_s = limit, window_s
        self._hits: dict[str, deque] = defaultdict(deque)
        self._lock = threading.Lock()

    def hit(self, *keys: str) -> bool:
        now = time.monotonic()
        with self._lock:
            allowed = True
            for key in keys:
                q = self._hits[key]
                while q and now - q[0] > self.window_s:
                    q.popleft()
                if len(q) >= self.limit:
                    allowed = False
                q.append(now)
            return allowed

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()


class StudentLogin(BaseModel):
    tenant: str = Field(min_length=1, max_length=32)
    school: str = Field(min_length=1, max_length=63)
    identifier: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


def resolve(database: Database, body: StudentLogin) -> uuid.UUID | None:
    with database.transaction() as conn:
        conn.execute("select set_config('role', 'service_role', true)")
        return conn.execute(
            "select app.resolve_student_login(%s, %s, %s) as id", [body.tenant, body.school, body.identifier]
        ).fetchone()["id"]


@router.post("/auth/student/login")
def student_login(body: StudentLogin, request: Request, database: Database = Depends(db)) -> dict:
    state = request.app.state
    client_ip = request.client.host if request.client else "-"
    key = f"id:{body.tenant.strip().upper()}|{body.school.strip().lower()}|{body.identifier.strip().upper()}"
    if not state.login_limiter.hit(key, f"ip:{client_ip}"):
        raise _TOO_MANY

    account = resolve(database, body)
    email = student_email(account if account is not None else uuid.uuid4())
    r = httpx.post(
        f"{state.settings.jwt_issuer}/token?grant_type=password",
        headers={"apikey": state.settings.publishable_key},
        json={"email": email, "password": body.password},
        timeout=10,
    )
    if account is None or r.status_code != 200:
        raise _INVALID
    session = r.json()
    return {k: session[k] for k in SESSION_FIELDS}
