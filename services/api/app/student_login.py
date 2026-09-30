"""دخول الطالب بـOfficial ID أو Temporary ID (D1).

المسار: (سياق الـhost، معرّف) ← `app.resolve_student_login` تحت دور `service_role` (قبل وجود JWT) ←
البريد الاصطناعي ← Supabase Auth (password grant) ← الجلسة كما يصدرها Supabase Auth نفسه. لا JWT يُصنع هنا.

- F3: الـtenant والمدرسة من `Origin` وحده (`{school}.{tenant}.{base}`) — لا حقل لهما في الجسم (حقل زائد ← 422).
  يحددان **أين يُبحث** فقط (الـslug فريد داخل الـTenant)؛ لا يمنحان سلطة — الجلسة الناتجة هوية الطالب وحدها،
  والسياق يُشتق في قاعدة البيانات كأي مستخدم (F4). سياق غير مدرسي أو غائب ← الفشل العام نفسه.
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
from pydantic import BaseModel, ConfigDict, Field

from .auth_admin import student_email
from .db import Database
from .deps import db, login_context
from .host_context import HostContext

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
    model_config = ConfigDict(extra="forbid")          # F3: لا tenant ولا school من الجسم — لا context drift
    identifier: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


def resolve(database: Database, ctx: HostContext, body: StudentLogin) -> uuid.UUID | None:
    with database.transaction() as conn:
        conn.execute("select set_config('role', 'service_role', true)")
        return conn.execute(
            "select app.resolve_student_login(%s, %s, %s) as id", [ctx.tenant, ctx.school, body.identifier]
        ).fetchone()["id"]


@router.post("/auth/student/login")
def student_login(body: StudentLogin, request: Request, database: Database = Depends(db),
                  ctx: HostContext | None = Depends(login_context)) -> dict:
    state = request.app.state
    client_ip = request.client.host if request.client else "-"
    where = f"{ctx.tenant}|{ctx.school}" if ctx else "-"
    if not state.login_limiter.hit(f"id:{where}|{body.identifier.strip().upper()}", f"ip:{client_ip}"):
        raise _TOO_MANY
    if ctx is None or ctx.kind != "school":                # الطالب يدخل من host مدرسته فقط
        raise _INVALID

    account = resolve(database, ctx, body)
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
