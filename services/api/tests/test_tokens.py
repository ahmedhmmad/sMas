"""F4 §1 — التحقق من JWT: صالح / غير صالح / مُعدَّل / مفاتيح لا تمثل مستخدماً."""

import base64
import json
import time
import uuid

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

from app.security import TokenVerifier
from conftest import ENV, auth, token

ISS, AUD = "https://issuer.test/auth/v1", "authenticated"


# ---------- وحدة: TokenVerifier بمفتاح ES256 محلي (يتيح رموزاً منتهية ومعيبة لا يصدرها Supabase) ----------

@pytest.fixture(scope="module")
def keys():
    private = ec.generate_private_key(ec.SECP256R1())
    return private, private.public_key()


@pytest.fixture(scope="module")
def verifier(keys):
    return TokenVerifier(lambda _t: keys[1], algorithms=("ES256",), audience=AUD, issuer=ISS)


def _claims(**over):
    now = int(time.time())
    c = {"iss": ISS, "aud": AUD, "sub": str(uuid.uuid4()), "role": "authenticated", "iat": now, "exp": now + 300}
    c.update(over)
    return {k: v for k, v in c.items() if v is not None}


def _sign(keys, claims, alg="ES256"):
    return jwt.encode(claims, keys[0], algorithm=alg, headers={"kid": "k1"})


def _rejected(verifier, tok):
    with pytest.raises(HTTPException) as e:
        verifier.verify(tok)
    return e.value.status_code


def test_unit_valid_token_accepted(verifier, keys):
    c = _claims()
    assert verifier.verify(_sign(keys, c))["sub"] == c["sub"]


@pytest.mark.parametrize("case,claims", [
    ("expired", {"exp": int(time.time()) - 10}),
    ("wrong audience", {"aud": "anon"}),
    ("wrong issuer", {"iss": "https://evil.test/auth/v1"}),
    ("anon role", {"role": "anon"}),
    ("service_role", {"role": "service_role"}),
    ("missing sub", {"sub": None}),
    ("missing role", {"role": None}),
    ("non-uuid sub", {"sub": "admin"}),
])
def test_unit_bad_claims_rejected(verifier, keys, case, claims):
    assert _rejected(verifier, _sign(keys, _claims(**claims))) == 401, case


def test_unit_other_key_rejected(verifier):
    other = ec.generate_private_key(ec.SECP256R1())
    assert _rejected(verifier, jwt.encode(_claims(), other, algorithm="ES256")) == 401


def test_unit_alg_none_and_hs256_rejected(verifier):
    unsigned = jwt.encode(_claims(), None, algorithm="none")
    hs = jwt.encode(_claims(), "x" * 32, algorithm="HS256")
    assert _rejected(verifier, unsigned) == 401
    assert _rejected(verifier, hs) == 401


# ---------- تكامل: عبر الـAPI و Supabase Auth الحقيقي ----------

def test_valid_jwt_is_accepted(client):
    assert client.get("/me", headers=auth("secretary")).status_code == 200


@pytest.mark.parametrize("header", [
    None,
    "Bearer",
    "Bearer not-a-jwt",
    "Basic dXNlcjpwYXNz",
])
def test_invalid_jwt_is_401(client, header):
    r = client.get("/me", headers={"Authorization": header} if header else {})
    assert r.status_code == 401 and r.json()["detail"] == "invalid_token"


def _tamper(tok: str, **changes) -> str:
    """تعديل الـpayload مع إبقاء التوقيع الأصلي."""
    h, p, s = tok.split(".")
    payload = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    payload.update(changes)
    p2 = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=").decode()
    return f"{h}.{p2}.{s}"


@pytest.mark.parametrize("changes", [
    {"sub": "a0000000-0000-4000-8000-000000000001"},                 # انتحال tenant_admin
    {"app_metadata": {"role": "tenant_admin", "tenant_id": "x"}},    # ادعاء دور/tenant
    {"exp": 4102444800},                                             # تمديد الصلاحية
])
def test_tampered_jwt_is_401(client, changes):
    r = client.get("/me", headers={"Authorization": f"Bearer {_tamper(token('secretary'), **changes)}"})
    assert r.status_code == 401


def test_signature_swapped_is_401(client):
    a, b = token("secretary").split("."), token("school_admin").split(".")
    r = client.get("/me", headers={"Authorization": f"Bearer {a[0]}.{a[1]}.{b[2]}"})
    assert r.status_code == 401


@pytest.mark.parametrize("key", ["TEST_SERVICE_ROLE_KEY", "TEST_ANON_KEY"])
def test_project_api_keys_are_not_user_tokens(client, key):
    """مفتاحا المشروع (HS256) ليسا هوية مستخدم: service_role لا يفتح الـAPI، ولا anon."""
    assert client.get("/me", headers={"Authorization": f"Bearer {ENV[key]}"}).status_code == 401
