"""Phase 2B-4 — ملف المدرسة وأصولها عبر FastAPI (M45؛ E1–E10).

قسمان:
  • **بلا Storage (إلزامي في CI):** الملف؛ التحقق من البايتات (E6)؛ القرار في DB قبل أي رفع (E5)؛ الـSaga كاملة بمخزن
    مزيّف يسجل كل نداء ويحاكي الفشل (فشل الرفع، timeout بعد التخزين، تعذّر التنظيف)؛ التقاعد؛ الرابط وتدقيقه (E7، E8).
  • **`storage` (محلياً مع storage-api — مستبعد في CI صراحةً، E10):** رفع حقيقي وقراءة بالرابط؛ الوصول المباشر إلى
    Storage بجلسة المستخدم مرفوض؛ التعويض الحقيقي؛ الاتساق.
"""

import hashlib
import struct
import uuid
import zlib

import httpx
import pytest

from app import assets
from app.storage_admin import StorageError
from conftest import ENV, auth, token


def png(width: int = 120, height: int = 60) -> bytes:
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))   # noqa: E731
    raw = b"".join(b"\x00" + b"\x00\x00\x00" * width for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def jpeg(width: int = 80, height: int = 40) -> bytes:
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, height, width, 3) + b"\x01\x11\x00\x02\x11\x01\x03\x11\x01"
    return b"\xff\xd8" + app0 + sof0 + b"\xff\xd9"


class FakeStorage:
    """يسجل النداءات؛ يُحاكي الفشل حسب الطلب."""

    def __init__(self, upload_error: bool = False, delete_error: bool = False):
        self.calls: list[tuple[str, str]] = []
        self.upload_error, self.delete_error = upload_error, delete_error

    def upload(self, path, data, content_type):
        self.calls.append(("upload", path))
        self.uploaded = (path, hashlib.sha256(data).hexdigest(), content_type)
        if self.upload_error:
            raise StorageError("upload: ReadTimeout")          # النتيجة غير معروفة — قد يكون خُزِّن

    def delete(self, path):
        self.calls.append(("delete", path))
        if self.delete_error:
            raise StorageError("delete: 500")

    def signed_url(self, path):
        self.calls.append(("sign", path))
        return f"https://storage.example/object/sign/school-assets/{path}?token=secret"


@pytest.fixture
def fake(client):
    store = FakeStorage()
    client.app.dependency_overrides[assets.storage] = lambda: store
    yield store
    client.app.dependency_overrides.pop(assets.storage, None)


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin, ids, client):
    yield
    seed = ", ".join(f"'{ids['school'][s]}'" for s in ("SA", "SB", "SS"))
    # الكائنات الحقيقية أولاً (محلياً مع Storage)، ثم الصفوف — وإلا تبقى كائنات يتيمة يكشفها فحص الاتساق (E9)
    stored = [r["name"] for r in admin.execute(
        f"select o.name from storage.objects o join public.school_assets a on a.object_path = o.name"
        f" where o.bucket_id = 'school-assets' and a.school_id in ({seed})").fetchall()]
    for path in stored:
        client.app.state.storage.delete(path)
    admin.execute(f"delete from public.school_assets where school_id in ({seed})")
    admin.execute(f"delete from public.school_profiles where school_id in ({seed})")


def upload(client, who, school_id, kind, data, reason="r", signer_title=None, filename="x.png", ctype="image/png"):
    fields = {"kind": kind, "reason": reason, **({"signer_title": signer_title} if signer_title else {})}
    return client.post(f"/schools/{school_id}/assets", data=fields, files={"file": (filename, data, ctype)}, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


# ------------------------------------------------------------------ الملف (E1)
def test_profile_lazy_create_edit_and_permissions(client, ids):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    empty = get(client, "secretary", f"/schools/{sa}/profile")
    assert empty.status_code == 200 and empty.json()["id"] is None
    body = {"address": "Cairo", "phone_e164": "+201000000009", "email": "info@sa.example", "website": "https://sa.example", "principal_display_name": "Mr. A"}
    made = client.put(f"/schools/{sa}/profile", json=body, headers=auth("school_admin"))
    assert made.status_code == 200 and made.json()["phone_e164"] == "+201000000009"
    assert client.put(f"/schools/{sa}/profile", json={**body, "address": "Giza"}, headers=auth("school_admin")).json()["address"] == "Giza"
    assert get(client, "secretary", f"/schools/{sa}/profile").json()["address"] == "Giza"
    assert client.put(f"/schools/{sa}/profile", json=body, headers=auth("secretary")).status_code == 403
    assert client.put(f"/schools/{sb}/profile", json=body, headers=auth("school_admin")).status_code == 404
    assert client.put(f"/schools/{sa}/profile", json={**body, "phone_e164": "0100"}, headers=auth("school_admin")).status_code == 422
    assert client.put(f"/schools/{sa}/profile", json={**body, "school_id": sb}, headers=auth("school_admin")).status_code == 422


# ------------------------------------------------------------------ E6: البايتات
@pytest.mark.parametrize("data, detail", [
    (b"<svg xmlns='http://www.w3.org/2000/svg'/>", "invalid_file_format"),
    (b"GIF89a" + b"\x00" * 20, "invalid_file_format"),
    (b"\x89PNG\r\n\x1a\n" + b"\x00" * 1_048_577, "invalid_file_size"),
    (png(5000, 10), "invalid_file_dimensions"),
    (b"", "invalid_file_size"),
], ids=["svg", "gif", "over_1mib", "over_4000px", "empty"])
def test_bytes_decide_not_the_client(client, ids, fake, data, detail):
    r = upload(client, "school_admin", ids["school"]["SA"], "logo", data, filename="logo.png", ctype="image/png")
    assert (r.status_code, r.json()["detail"]) == (422, detail)
    assert fake.calls == []                                                   # لا DB ولا Storage


# ------------------------------------------------------------------ E5: DB أولاً — لا بايت بلا صلاحية
def test_no_permission_no_upload(client, ids, fake):
    sa = ids["school"]["SA"]
    assert upload(client, "secretary", sa, "logo", png()).status_code == 403
    assert upload(client, "group_manager", sa, "stamp", png()).status_code == 403      # B5: school.update لا يكفي للختم
    assert upload(client, "school_admin", ids["school"]["SB"], "logo", png()).status_code == 404
    assert upload(client, "school_admin", sa, "signature", png()).status_code == 422   # E2: التوقيع بلا صفة
    assert fake.calls == []


def test_upload_saga_success_path_and_hash(client, ids, fake, admin):
    sa = ids["school"]["SA"]
    tenant = admin.execute("select platform_tenant_id::text t from public.schools where id = %s", [sa]).fetchone()["t"]
    data = jpeg()
    r = upload(client, "school_admin", sa, "logo", data, filename="evil.svg", ctype="image/svg+xml")   # الاسم والنوع المعلَنان يُهملان
    assert r.status_code == 201, r.text
    row = r.json()
    path, digest, ctype = fake.uploaded
    assert path == f"{tenant}/{sa}/logo/{row['id']}.jpg"                     # E4: مشتق في DB
    assert (row["content_type"], ctype, row["width"], row["height"]) == ("image/jpeg", "image/jpeg", 80, 40)
    assert row["sha256"] == digest == hashlib.sha256(data).hexdigest()       # E6: للبايتات المرفوعة فعلاً
    assert fake.calls == [("upload", path)]
    assert "object_path" not in row
    listed = get(client, "secretary", f"/schools/{sa}/assets").json()["rows"]
    assert any(a["id"] == row["id"] and a["status"] == "active" for a in listed) and all("object_path" not in a for a in listed)


def test_upload_failure_rolls_back_and_cleans_only_its_own_object(client, ids, admin):
    store = FakeStorage(upload_error=True)
    client.app.dependency_overrides[assets.storage] = lambda: store
    try:
        before = admin.execute("select count(*) n from public.school_assets").fetchone()["n"]
        r = upload(client, "school_admin", ids["school"]["SA"], "stamp", png(), reason="timeout case")
        assert (r.status_code, r.json()["detail"]) == (503, "storage_unavailable")
        assert admin.execute("select count(*) n from public.school_assets").fetchone()["n"] == before          # rollback: لا صف
        (_, path), (op, cleaned) = store.calls
        assert (op, cleaned) == ("delete", path)                                 # التنظيف لمسار هذا الطلب وحده
    finally:
        client.app.dependency_overrides.pop(assets.storage, None)


def test_cleanup_failure_is_a_visible_error(client, ids, admin):
    store = FakeStorage(upload_error=True, delete_error=True)
    client.app.dependency_overrides[assets.storage] = lambda: store
    try:
        r = upload(client, "school_admin", ids["school"]["SA"], "stamp", png(), reason="cleanup fails")
        assert (r.status_code, r.json()["detail"]) == (500, "asset_cleanup_failed")   # لا نجاح للمستخدم
        assert [op for op, _ in store.calls] == ["upload", "delete"]
    finally:
        client.app.dependency_overrides.pop(assets.storage, None)


def test_retire_and_versions(client, ids, fake):
    sa = ids["school"]["SA"]
    first = upload(client, "school_admin", sa, "stamp", png(), reason="stamp v1").json()
    second = upload(client, "school_admin", sa, "stamp", png(100, 100), reason="stamp v2").json()
    rows = {a["id"]: a for a in get(client, "school_admin", f"/schools/{sa}/assets").json()["rows"]}
    assert (rows[first["id"]]["status"], rows[second["id"]]["status"]) == ("retired", "active")    # B3
    assert client.post(f"/assets/{second['id']}/retire", json={"reason": "r"}, headers=auth("group_manager")).status_code == 403
    done = client.post(f"/assets/{second['id']}/retire", json={"reason": "stamp withdrawn"}, headers=auth("school_admin"))
    assert done.status_code == 200 and done.json()["status"] == "retired" and done.json()["retired_at"]
    assert client.post(f"/assets/{second['id']}/retire", json={"reason": "again"}, headers=auth("school_admin")).status_code == 422
    assert client.delete(f"/assets/{second['id']}", headers=auth("school_admin")).status_code in (404, 405)   # E3: لا مسار حذف
    assert any(a["id"] == second["id"] for a in get(client, "school_admin", f"/schools/{sa}/assets").json()["rows"])


def test_signed_url_rules_and_issuance_audit(client, ids, fake, admin):
    sa = ids["school"]["SA"]
    logo = upload(client, "school_admin", sa, "logo", png(), reason="logo").json()
    stamp = upload(client, "school_admin", sa, "stamp", png(), reason="stamp").json()
    fake.calls.clear()
    since = admin.execute("select coalesce(max(id), 0) n from public.audit_log").fetchone()["n"]
    ok = get(client, "secretary", f"/assets/{logo['id']}/url")
    assert ok.status_code == 200 and ok.json()["expires_in"] == 60                # E7
    assert get(client, "secretary", f"/assets/{stamp['id']}/url").status_code == 403
    assert get(client, "group_manager", f"/assets/{stamp['id']}/url").status_code == 403
    assert get(client, "school_admin", f"/assets/{stamp['id']}/url").status_code == 200
    assert [op for op, _ in fake.calls] == ["sign", "sign"]                      # لا توقيع لمن رُفض
    rows = admin.execute("select entity_id, new_values::text v from public.audit_log where action = 'asset_url' and id > %s", [since]).fetchall()
    assert [r["entity_id"] for r in rows] == [stamp["id"]]                         # E8: الختم وحده
    assert "token" not in rows[0]["v"] and "http" not in rows[0]["v"]             # E8: لا رابط ولا token
    other = ids["school"]["SB"]
    assert get(client, "school_admin", f"/schools/{other}/assets").status_code == 404


# ------------------------------------------------------------------ Storage حقيقي (محلياً — مستبعد في CI صراحةً)
STORAGE = f"{ENV['SUPABASE_URL']}/storage/v1"


@pytest.mark.storage
def test_real_upload_read_by_signed_url_and_consistency(client, ids, admin):
    sa = ids["school"]["SA"]
    data = png(64, 32)
    r = upload(client, "school_admin", sa, "logo", data, reason="real upload")
    assert r.status_code == 201, r.text
    asset = r.json()
    url = get(client, "secretary", f"/assets/{asset['id']}/url").json()["url"]
    fetched = httpx.get(url, timeout=10)
    assert fetched.status_code == 200 and fetched.content == data and hashlib.sha256(fetched.content).hexdigest() == asset["sha256"]
    tampered = httpx.get(url[:-4] + "AAAA", timeout=10)
    assert tampered.status_code in (400, 401, 403)
    issues = admin.execute("select issue, object_path from app.school_asset_consistency() where object_path like %s", [f"%{asset['id']}%"]).fetchall()
    assert issues == []                                                          # E9: الصف والكائن متسقان


@pytest.mark.storage
def test_no_direct_storage_access_with_a_user_session(client, ids, admin):
    """B4/E10: لا رفع ولا قراءة إلا عبر مسار FastAPI المصرح به — جلسة المستخدم مرفوضة مباشرة على Storage."""
    sa = ids["school"]["SA"]
    tenant = admin.execute("select platform_tenant_id::text t from public.schools where id = %s", [sa]).fetchone()["t"]
    headers = {"apikey": ENV["SUPABASE_PUBLISHABLE_KEY"], "Authorization": f"Bearer {token('school_admin')}"}
    path = f"{tenant}/{sa}/logo/{uuid.uuid4()}.png"
    put = httpx.post(f"{STORAGE}/object/school-assets/{path}", content=png(), headers={**headers, "content-type": "image/png"}, timeout=10)
    assert put.status_code in (400, 401, 403), put.text
    existing = admin.execute("select object_path from public.school_assets where school_id = %s and status = 'active' and kind = 'logo'", [sa]).fetchone()
    if existing:
        read = httpx.get(f"{STORAGE}/object/authenticated/school-assets/{existing['object_path']}", headers=headers, timeout=10)
        assert read.status_code in (400, 401, 403, 404)
    assert admin.execute("select count(*) n from storage.objects where name = %s", [path]).fetchone()["n"] == 0


@pytest.mark.storage
def test_real_compensation_after_upload(client, ids, admin):
    """E5 حقيقياً: الكائن يُخزَّن ثم يفشل ما بعده ← يُحذف كائن هذا الطلب وحده، ويبقى ما قبله."""
    real = client.app.state.storage
    before = {r["name"] for r in admin.execute("select name from storage.objects where bucket_id = 'school-assets'").fetchall()}

    class AfterUploadFailure:
        def upload(self, path, data, content_type):
            real.upload(path, data, content_type)
            raise StorageError("upload: ReadTimeout")       # خُزِّن فعلاً ثم «انقطع»

        def delete(self, path):
            real.delete(path)

        def signed_url(self, path):
            return real.signed_url(path)

    client.app.dependency_overrides[assets.storage] = lambda: AfterUploadFailure()
    try:
        r = upload(client, "school_admin", ids["school"]["SA"], "logo", png(), reason="compensate")
        assert r.status_code == 503
    finally:
        client.app.dependency_overrides.pop(assets.storage, None)
    after = {r["name"] for r in admin.execute("select name from storage.objects where bucket_id = 'school-assets'").fetchall()}
    assert after == before                                                      # لا يتيم، ولا حذف لما سبق
