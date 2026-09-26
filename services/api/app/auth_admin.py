"""Supabase Auth Admin API — الموضع الوحيد في الخدمة الذي يقرأ المفتاح السري (`SUPABASE_SECRET_KEY`).

إدارة حسابات Auth فقط (إنشاء، كلمة مرور، حذف تعويضي، إصدار جلسة). لا يمنح FastAPI أي سلطة على البيانات:
كل كتابة في قاعدة البيانات تتم بـJWT المستدعي تحت RLS/T8.

الهوية الاصطناعية (D1، D3/I2): معرّف حساب Auth = معرّف الكيان (student_id / guardian_id / staff_id)، وبريده
`<id>@<kind>.smas.invalid` — لا يراه أحد ولا يغادر الخادم، ولا يستقبل بريداً (`.invalid` محجوز، RFC 2606).
الهاتف/البريد الحقيقي في جدول الكيان، لا في `auth.users` (فلا تصادم ولا كشف عبر الـTenants).

الجلسة (D3): `generate_link` (magiclink، لا يُرسل شيئاً) ثم `/verify` بالـtoken_hash — Supabase Auth يصدر الجلسة؛
الـtoken_hash لا يغادر هذا الملف، وما يعود للمستدعي حقول الجلسة وحدها.
"""

import os
import secrets
import uuid

import httpx

DOMAINS = {"student": "students", "guardian": "guardians", "staff": "staff"}
SESSION_FIELDS = ("access_token", "refresh_token", "expires_in", "token_type")


def account_email(kind: str, account_id: uuid.UUID | str) -> str:
    return f"{account_id}@{DOMAINS[kind]}.smas.invalid"


def student_email(student_id: uuid.UUID | str) -> str:
    return account_email("student", student_id)


class AuthAdminError(RuntimeError):
    pass


class AuthAdmin:
    def __init__(self, supabase_url: str, publishable_key: str):
        self._auth = f"{supabase_url}/auth/v1"
        self._users = f"{self._auth}/admin/users"
        self._publishable = publishable_key
        self._http = httpx.Client(timeout=10, headers={"apikey": os.environ["SUPABASE_SECRET_KEY"]})

    def close(self) -> None:
        self._http.close()

    def create_account(self, kind: str, account_id: uuid.UUID) -> bool:
        """كلمة مرور عشوائية لا يعرفها أحد. True = أُنشئ الآن؛ False = موجود من محاولة سابقة (استئناف)."""
        email = account_email(kind, account_id)
        r = self._http.post(self._users, json={
            "id": str(account_id), "email": email, "password": secrets.token_urlsafe(32), "email_confirm": True})
        if r.status_code in (200, 201):
            return True
        existing = self._http.get(f"{self._users}/{account_id}")
        if existing.status_code == 200 and existing.json().get("email") == email:
            return False
        raise AuthAdminError(f"create failed: {r.status_code}")

    def create_student_account(self, student_id: uuid.UUID) -> bool:
        return self.create_account("student", student_id)

    def set_password(self, user_id: uuid.UUID, password: str) -> None:
        r = self._http.put(f"{self._users}/{user_id}", json={"password": password})
        if r.status_code != 200:
            raise AuthAdminError(f"set password failed: {r.status_code}")

    def delete(self, user_id: uuid.UUID) -> None:
        r = self._http.delete(f"{self._users}/{user_id}")
        if r.status_code not in (200, 404):
            raise AuthAdminError(f"delete failed: {r.status_code}")

    def issue_session(self, kind: str, account_id: uuid.UUID) -> dict | None:
        """جلسة يصدرها Supabase Auth لحساب تحققت قاعدة البيانات منه (OTP). None إن رفض Supabase Auth (حظر...)."""
        link = self._http.post(f"{self._auth}/admin/generate_link",
                               json={"type": "magiclink", "email": account_email(kind, account_id)})
        if link.status_code != 200:
            return None
        r = httpx.post(f"{self._auth}/verify", headers={"apikey": self._publishable}, timeout=10,
                       json={"type": "magiclink", "token_hash": link.json()["hashed_token"]})
        if r.status_code != 200:
            return None
        session = r.json()
        return {k: session[k] for k in SESSION_FIELDS}
