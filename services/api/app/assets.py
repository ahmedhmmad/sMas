"""Phase 2B-4 — ملف المدرسة وأصولها (M45؛ E1–E10).

المسار الوحيد للسلطة كبقية الـAPI: JWT ← معاملة `authenticated` ← RLS ودوال app.* تقرر. FastAPI لا يقرر صلاحية.

الرفع (E5) — **ليس معاملة ذرية بين PostgreSQL و Storage**، بل Saga موثقة:
  1. في معاملة المستخدم: `app.register_school_asset` تتحقق (الصلاحية حسب النوع، النطاق، الحالة) وتكتب الصف وتشتق المسار
     — من لا يملك الصلاحية لا يرفع بايتاً واحداً؛
  2. رفع الكائن إلى المسار الذي اشتقته DB (معرّف جديد لهذا الطلب)؛
  3. commit.
  فشل الرفع ← rollback (لا صف). فشل بعد بدء الرفع (ومنه فشل الـcommit أو timeout) ← حذف **الكائن الذي رفعه هذا الطلب
  وحده** (مساره يحمل معرّفاً وُلد هنا — لا يمكن أن يكون ملفاً قديماً). تعذّر التنظيف ← `500 asset_cleanup_failed`
  مرئياً ومسجلاً بالمسار للتشخيص — لا نجاح للمستخدم. الكائن اليتيم المحتمل يكشفه `app.school_asset_consistency()` (E9).
الرابط الموقّع (E7، E8): `app.authorize_asset_url` (تقرر وتدقّق الإصدار للختم/التوقيع) ← توقيع 60 ثانية ← commit؛
  فشل التوقيع ← rollback فلا تدقيق لرابط لم يصدر. الرابط لا يُخزَّن ولا يُدقَّق نصّه.
"""

import hashlib
import logging
import uuid

import psycopg
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel, ConfigDict, Field

from .db import Database
from .deps import claims, db, http_error
from .images import MAX_BYTES, ImageRejected, inspect
from .storage_admin import URL_SECONDS, StorageAdmin, StorageError

router = APIRouter()
log = logging.getLogger("smas.assets")

_PROFILE = "id, school_id, address, phone_e164, email, website, principal_display_name"
_ASSET = "id, school_id, kind, signer_title, content_type, byte_size, width, height, sha256, status, retired_at, created_at"


def storage(request: Request) -> StorageAdmin:
    return request.app.state.storage


class ProfileBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    address: str | None = Field(default=None, max_length=500)
    phone_e164: str | None = Field(default=None, max_length=16)
    email: str | None = Field(default=None, max_length=254)
    website: str | None = Field(default=None, max_length=500)
    principal_display_name: str | None = Field(default=None, max_length=200)


class Reason(BaseModel):
    model_config = ConfigDict(extra="forbid")
    reason: str = Field(min_length=1, max_length=500)


def _tx(c: dict, database: Database, work):
    try:
        with database.as_user(c) as conn:
            return work(conn)
    except psycopg.Error as exc:
        raise http_error(exc) from exc


def _school_visible(conn: psycopg.Connection, school_id: uuid.UUID) -> None:
    if conn.execute("select 1 from public.schools where id = %s", [school_id]).fetchone() is None:
        raise HTTPException(status_code=404, detail="not_found")


# ------------------------------------------------------------------ profile (E1)
@router.get("/schools/{school_id}/profile")
def get_profile(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _school_visible(conn, school_id)
        row = conn.execute(f"select {_PROFILE} from public.school_profiles where school_id = %s", [school_id]).fetchone()
        return row or {"id": None, "school_id": str(school_id), "address": None, "phone_e164": None, "email": None,
                       "website": None, "principal_display_name": None}
    return _tx(c, database, work)


@router.put("/schools/{school_id}/profile")
def put_profile(school_id: uuid.UUID, body: ProfileBody, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """إنشاء كسول ثم تعديل في المكان (بلا تاريخ نسخ — E1). القرار في RLS والحارس."""
    values = body.model_dump()

    def work(conn):
        _school_visible(conn, school_id)
        existing = conn.execute("select id from public.school_profiles where school_id = %s", [school_id]).fetchone()
        cols = list(values)
        if existing is None:
            conn.execute(f"insert into public.school_profiles (school_id, {', '.join(cols)}) values (%s, {', '.join(['%s'] * len(cols))})",
                         [school_id, *values.values()])
        elif conn.execute(f"update public.school_profiles set {', '.join(f'{k} = %s' for k in cols)} where school_id = %s returning id",
                          [*values.values(), school_id]).fetchone() is None:
            raise HTTPException(status_code=403, detail="forbidden")
        row = conn.execute(f"select {_PROFILE} from public.school_profiles where school_id = %s", [school_id]).fetchone()
        if row is None:
            raise HTTPException(status_code=403, detail="forbidden")
        return row
    return _tx(c, database, work)


# ------------------------------------------------------------------ assets (B3، E2–E8)
@router.get("/schools/{school_id}/assets")
def list_assets(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """البيانات الوصفية وحدها — لا روابط ولا مسارات."""
    def work(conn):
        _school_visible(conn, school_id)
        return {"rows": conn.execute(f"select {_ASSET} from public.school_assets where school_id = %s order by kind, created_at desc, id",
                                     [school_id]).fetchall()}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/assets", status_code=201)
def upload_asset(school_id: uuid.UUID, kind: str = Form(pattern="^(logo|stamp|signature)$"), reason: str = Form(min_length=1, max_length=500),
                 signer_title: str | None = Form(default=None, max_length=100), file: UploadFile = File(...),
                 c: dict = Depends(claims), database: Database = Depends(db), store: StorageAdmin = Depends(storage)) -> dict:
    data = file.file.read(MAX_BYTES + 1)
    try:
        content_type, width, height = inspect(data)             # E6: من البايتات لا من العميل
    except ImageRejected as exc:
        raise HTTPException(status_code=422, detail=f"invalid_file_{exc}") from exc
    sha256 = hashlib.sha256(data).hexdigest()                    # E6: للبايتات التي ستُخزَّن فعلاً
    asset_id = uuid.uuid4()
    path: str | None = None
    attempted = False
    try:
        with database.as_user(c) as conn:
            path = conn.execute("select app.register_school_asset(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) as p",
                                [asset_id, school_id, kind, signer_title, content_type, len(data), width, height, sha256, reason]).fetchone()["p"]
            attempted = True
            store.upload(path, data, content_type)
            row = conn.execute(f"select {_ASSET} from public.school_assets where id = %s", [asset_id]).fetchone()
        return row                                                # بعد الـcommit
    except Exception as exc:
        if attempted and path is not None:
            _cleanup(store, path)
        if isinstance(exc, HTTPException):
            raise
        if isinstance(exc, psycopg.Error):
            raise http_error(exc) from exc
        if isinstance(exc, StorageError):
            raise HTTPException(status_code=503, detail="storage_unavailable") from exc
        raise


def _cleanup(store: StorageAdmin, path: str) -> None:
    """تعويض E5: الكائن الذي رفعه هذا الطلب وحده. تعذّره خطأ مرئي لا نجاح."""
    try:
        store.delete(path)
    except StorageError as exc:
        log.error("asset cleanup failed — orphan object may remain: %s (%s)", path, exc)
        raise HTTPException(status_code=500, detail="asset_cleanup_failed") from exc


@router.post("/assets/{asset_id}/retire")
def retire_asset(asset_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        conn.execute("select app.retire_school_asset(%s, %s)", [asset_id, body.reason])
        return conn.execute(f"select {_ASSET} from public.school_assets where id = %s", [asset_id]).fetchone()
    return _tx(c, database, work)


@router.get("/assets/{asset_id}/url")
def asset_url(asset_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db), store: StorageAdmin = Depends(storage)) -> dict:
    def work(conn):
        path = conn.execute("select app.authorize_asset_url(%s) as p", [asset_id]).fetchone()["p"]
        try:
            url = store.signed_url(path)
        except StorageError as exc:                                # rollback: لا تدقيق لرابط لم يصدر
            raise HTTPException(status_code=503, detail="storage_unavailable") from exc
        return {"url": url, "expires_in": URL_SECONDS}
    return _tx(c, database, work)
