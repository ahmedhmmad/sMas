"""Supabase Auth Admin API — الموضع الوحيد في الخدمة الذي يقرأ المفتاح السري (`SUPABASE_SECRET_KEY`).

يُستعمل لإدارة حسابات Auth فقط (إنشاء، كلمة مرور، حذف تعويضي) في Saga إنشاء الطالب (§5.4). لا يمنح
FastAPI أي سلطة على البيانات: كل كتابة في قاعدة البيانات تتم بـJWT المستدعي تحت RLS/T8.

D1: حساب الطالب معرّفه = student_id، وبريده اصطناعي `<student_id>@students.smas.invalid` — لا يراه الطالب،
ولا يستقبل بريداً (`.invalid` محجوز، RFC 2606)، ولا يتغير حين يتحول Temporary ID إلى Official ID.
"""

import os
import secrets
import uuid

import httpx

STUDENT_EMAIL_DOMAIN = "students.smas.invalid"


def student_email(student_id: uuid.UUID | str) -> str:
    return f"{student_id}@{STUDENT_EMAIL_DOMAIN}"


class AuthAdminError(RuntimeError):
    pass


class AuthAdmin:
    def __init__(self, supabase_url: str):
        self._users = f"{supabase_url}/auth/v1/admin/users"
        self._http = httpx.Client(timeout=10, headers={"apikey": os.environ["SUPABASE_SECRET_KEY"]})

    def close(self) -> None:
        self._http.close()

    def create_student_account(self, student_id: uuid.UUID) -> bool:
        """ينشئ الحساب بكلمة مرور عشوائية لا يعرفها أحد. True = أُنشئ الآن؛ False = موجود من محاولة سابقة (استئناف)."""
        r = self._http.post(self._users, json={
            "id": str(student_id),
            "email": student_email(student_id),
            "password": secrets.token_urlsafe(32),
            "email_confirm": True,
        })
        if r.status_code in (200, 201):
            return True
        existing = self._http.get(f"{self._users}/{student_id}")
        if existing.status_code == 200 and existing.json().get("email") == student_email(student_id):
            return False
        raise AuthAdminError(f"create failed: {r.status_code}")

    def set_password(self, user_id: uuid.UUID, password: str) -> None:
        r = self._http.put(f"{self._users}/{user_id}", json={"password": password})
        if r.status_code != 200:
            raise AuthAdminError(f"set password failed: {r.status_code}")

    def delete(self, user_id: uuid.UUID) -> None:
        r = self._http.delete(f"{self._users}/{user_id}")
        if r.status_code not in (200, 404):
            raise AuthAdminError(f"delete failed: {r.status_code}")
