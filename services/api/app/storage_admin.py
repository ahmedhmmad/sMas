"""Supabase Storage — **الموضع الثاني** في الخدمة الذي يقرأ المفتاح السري (`SUPABASE_SECRET_KEY`؛ الأول `auth_admin.py`).

Phase 2B-4 (B4، E5، E7): الـbucket `school-assets` خاص ولا سياسة عليه لأي دور عميل؛ الخدمة وحدها ترفع وتحذف وتوقّع.
لا يقرر هذا الملف شيئاً: كل رفع يسبقه `app.register_school_asset` بجلسة المستخدم، وكل رابط يسبقه `app.authorize_asset_url`.
الحذف الوحيد: تعويض الـSaga للكائن الذي رفعه **الطلب نفسه** (E3، E5) — لا ملف قديم ولا ملف لا يخص العملية.
المفتاح لا يغادر الخادم (الثابت 14)؛ الرابط الموقّع قصير العمر ولا يُخزَّن ولا يُدقَّق نصّه (E8).
"""

import os
from urllib.parse import quote

import httpx

BUCKET = "school-assets"
URL_SECONDS = 60


class StorageError(RuntimeError):
    pass


class StorageAdmin:
    def __init__(self, supabase_url: str):
        self._base = f"{supabase_url}/storage/v1"
        self._http = httpx.Client(timeout=10, headers={"apikey": os.environ["SUPABASE_SECRET_KEY"]})

    def close(self) -> None:
        self._http.close()

    def _object(self, path: str) -> str:
        return f"{self._base}/object/{BUCKET}/{quote(path)}"

    def upload(self, path: str, data: bytes, content_type: str) -> None:
        try:
            r = self._http.post(self._object(path), content=data, headers={"content-type": content_type, "x-upsert": "false"})
        except httpx.HTTPError as exc:                  # timeout أو انقطاع: النتيجة غير معروفة — المستدعي ينظّف المسار
            raise StorageError(f"upload: {type(exc).__name__}") from exc
        if r.status_code not in (200, 201):
            raise StorageError(f"upload: {r.status_code}")

    def delete(self, path: str) -> None:
        """تعويض: 404 = لم يُخزَّن أصلاً، فلا شيء يُنظَّف."""
        try:
            r = self._http.delete(self._object(path))
        except httpx.HTTPError as exc:
            raise StorageError(f"delete: {type(exc).__name__}") from exc
        if r.status_code not in (200, 204, 404) and not (r.status_code == 400 and "not found" in r.text.lower()):
            raise StorageError(f"delete: {r.status_code}")

    def signed_url(self, path: str) -> str:
        try:
            r = self._http.post(f"{self._base}/object/sign/{BUCKET}/{quote(path)}", json={"expiresIn": URL_SECONDS})
        except httpx.HTTPError as exc:
            raise StorageError(f"sign: {type(exc).__name__}") from exc
        if r.status_code != 200:
            raise StorageError(f"sign: {r.status_code}")
        return f"{self._base}{r.json()['signedURL']}"
