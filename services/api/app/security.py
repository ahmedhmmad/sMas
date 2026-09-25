"""التحقق من Supabase JWT.

ما يُتحقَّق منه هنا: التوقيع (بالمفتاح العام من JWKS، بخوارزمية مثبتة)، `exp`، `aud`، `iss`، وأن الرمز لمستخدم
(`role = authenticated`) بـ`sub` صالح. **لا شيء غير ذلك**: لا tenant ولا school ولا دور ولا صلاحية تُقرأ من الـclaims
لتحديد السلطة — السياق كله يُشتق في قاعدة البيانات من `auth.uid()` (CLAUDE.md §1.1، ERD §9).
"""

import uuid
from typing import Any, Callable

import jwt
from fastapi import HTTPException, Request, status

# رمز الخطأ رمز آلة لا نص معروض (CLAUDE.md §1 بند 13)
_UNAUTHORIZED = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="invalid_token",
    headers={"WWW-Authenticate": "Bearer"},
)

REQUIRED_CLAIMS = ["exp", "iat", "sub", "aud", "iss", "role"]


class TokenVerifier:
    """`key_resolver(token) -> key` يعيد المفتاح العام المطابق لـ`kid`؛ في الخدمة: PyJWKClient على JWKS."""

    def __init__(self, key_resolver: Callable[[str], Any], *, algorithms: tuple[str, ...], audience: str, issuer: str):
        self._key_resolver = key_resolver
        self._algorithms = list(algorithms)
        self._audience = audience
        self._issuer = issuer

    @classmethod
    def from_jwks(cls, jwks_url: str, **kwargs) -> "TokenVerifier":
        client = jwt.PyJWKClient(jwks_url, cache_keys=True, lifespan=300)
        return cls(lambda token: client.get_signing_key_from_jwt(token).key, **kwargs)

    def verify(self, token: str) -> dict[str, Any]:
        try:
            # الخوارزمية تُثبَّت قبل أي شيء: alg=none و HS256 (المفاتيح القديمة) لا تصل إلى فك التوقيع
            if jwt.get_unverified_header(token).get("alg") not in self._algorithms:
                raise _UNAUTHORIZED
            claims = jwt.decode(
                token,
                self._key_resolver(token),
                algorithms=self._algorithms,
                audience=self._audience,
                issuer=self._issuer,
                options={"require": REQUIRED_CLAIMS},
            )
        except jwt.PyJWKClientConnectionError as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="jwks_unavailable") from exc
        except jwt.PyJWTError as exc:
            raise _UNAUTHORIZED from exc
        # رمز مستخدم فقط؛ anon و service_role ليسا هوية يُنفَّذ باسمها طلب
        if claims.get("role") != "authenticated":
            raise _UNAUTHORIZED
        try:
            uuid.UUID(str(claims["sub"]))
        except ValueError as exc:
            raise _UNAUTHORIZED from exc
        return claims


def bearer_token(request: Request) -> str:
    scheme, _, token = request.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise _UNAUTHORIZED
    return token.strip()
