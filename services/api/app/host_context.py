"""F3 — سياق الـhost (قرار 2026-10-01).

    {school}.{tenant}.{base}  → سياق مدرسة
    {tenant}.{base}           → سياق Tenant
    admin.{base}              → المنصة

**السياق «أين يُبحث» فقط — ليس سلطة ولا إثبات هوية:**  Origin → أين يُبحث · JWT → من المستخدم · DB/RLS → ما
يصل إليه. لا كود هنا ولا في غيره يستنتج صلاحية من السياق. `Origin` يزوّره أي عميل غير المتصفح — ولا ثغرة في ذلك
لأنه لا يُستعمل تفويضاً.

القواعد نفسها في الواجهة (apps/web/src/context/hostContext.ts) وفي قاعدة البيانات (M30:
platform_tenants_host_label_chk / _reserved، schools_slug_chk)؛ متجهات الاختبار المشتركة:
docs/contracts/host_context_vectors.json — حتى لا يختلف «Origin مقبول» عن «hostname مقبول».
"""

import re
from dataclasses import dataclass

# labels DNS (RFC 1123): تبدأ وتنتهي بحرف أو رقم، ≤ 63 — M30b
TENANT_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")   # platform_tenants_host_label_chk (1–63)
SCHOOL_SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,61}[a-z0-9]")         # schools_slug_chk (2–63)
RESERVED = frozenset({"admin", "api", "www"})             # platform_tenants_host_label_reserved
PLATFORM_LABEL = "admin"

# Origin كما يرسله المتصفح: scheme://host[:port] — بلا مسار ولا مستخدم ولا نقطة ختامية؛ أحرف صغيرة فقط
_ORIGIN = re.compile(r"(https?)://([a-z0-9.-]+)(?::([0-9]{1,5}))?")
_DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
_DEFAULT_PORT = {"http": "80", "https": "443"}


@dataclass(frozen=True)
class HostContext:
    kind: str                    # 'school' | 'tenant' | 'platform'
    tenant: str | None = None    # host_label
    school: str | None = None    # slug


def _tenant_label(label: str) -> bool:
    return TENANT_LABEL.fullmatch(label) is not None and label not in RESERVED


def parse_host(hostname: str, base: str) -> HostContext | None:
    """hostname (كما في URL، بلا منفذ) ← السياق، أو None لكل ما سوى الأشكال الثلاثة."""
    if not base or not hostname.endswith("." + base):
        return None
    labels = hostname[: -len(base) - 1].split(".")
    if len(labels) == 1:
        label = labels[0]
        if label == PLATFORM_LABEL:
            return HostContext("platform")
        return HostContext("tenant", tenant=label) if _tenant_label(label) else None
    if len(labels) == 2:
        school, tenant = labels
        if _tenant_label(tenant) and SCHOOL_SLUG.fullmatch(school):
            return HostContext("school", tenant=tenant, school=school)
    return None


@dataclass(frozen=True)
class OriginBase:
    """أصل الواجهة الأساسي (API_CORS_ORIGIN_BASE): scheme + base host + منفذ — ترسيخ كامل، لا wildcard."""

    scheme: str
    host: str
    port: str | None

    @classmethod
    def parse(cls, value: str) -> "OriginBase":
        m = _ORIGIN.fullmatch(value.strip())
        labels = m[2].split(".") if m else []
        if not m or not all(_DNS_LABEL.fullmatch(x) for x in labels) or not labels[-1][0].isalpha():
            raise ValueError(
                "API_CORS_ORIGIN_BASE must be scheme://base-domain[:port] (e.g. https://smas.example); '*' is not allowed")
        return cls(m[1], m[2], _port(m[1], m[3]))

    def context(self, origin: str | None) -> HostContext | None:
        """Origin ← السياق بقواعد parse_host نفسها؛ None إن غاب أو خرج عن الأصل الأساسي."""
        m = _ORIGIN.fullmatch(origin or "")
        if not m or m[1] != self.scheme or _port(m[1], m[3]) != self.port:
            return None
        return parse_host(m[2], self.host)


def _port(scheme: str, port: str | None) -> str | None:
    return None if port is None or port == _DEFAULT_PORT[scheme] else port
