"""قناة إرسال رمز OTP (D3/I7).

القناة الحقيقية (WhatsApp عبر SendWhats، SMS، البريد) خارج D3 — المرحلة 5. هنا الواجهة ومرسلا تطوير:

  API_OTP_SENDER=local        ← في الذاكرة (pytest، نفس العملية)
  API_OTP_SENDER=file:<path>  ← سطر JSON لكل رسالة في ملف (E2E المتصفح — F1): المسار خارج apps/web، بلا أي
                                مسار HTTP يقرؤه، ويُنظَّف بين الاختبارات
  بلا قيمة                    ← لا قناة ⇒ مسارات OTP ترد 503 (لا رمز يُصدر بلا وسيلة إيصال)

كلا المرسلين للتطوير فقط: يُرفضان عند `API_ENVIRONMENT=production`.
"""

import json
import os
import pathlib
import threading
from typing import Protocol

WEB_APP = (pathlib.Path(__file__).resolve().parents[3] / "apps" / "web").resolve()


class OtpSender(Protocol):
    def send(self, kind: str, contact: str, code: str) -> None: ...


class LocalOutbox:
    """في الذاكرة. لا يُعرض عبر أي مسار HTTP."""

    def __init__(self) -> None:
        self.messages: list[tuple[str, str, str]] = []
        self._lock = threading.Lock()

    def send(self, kind: str, contact: str, code: str) -> None:
        with self._lock:
            self.messages.append((kind, contact, code))


class FileOutbox:
    """سطر JSON لكل رسالة. لا يُعرض عبر أي مسار HTTP."""

    def __init__(self, path: str) -> None:
        self.path = pathlib.Path(path).resolve()
        if self.path == WEB_APP or WEB_APP in self.path.parents:
            raise ValueError("the OTP outbox file must be outside apps/web")
        self._lock = threading.Lock()

    def send(self, kind: str, contact: str, code: str) -> None:
        with self._lock, self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"kind": kind, "contact": contact, "code": code}) + "\n")


def load_sender(environment: str = "development") -> OtpSender | None:
    value = os.environ.get("API_OTP_SENDER", "")
    if value and environment == "production":
        raise ValueError("development OTP senders are not allowed in production")
    if value == "local":
        return LocalOutbox()
    if value.startswith("file:"):
        return FileOutbox(value[len("file:"):])
    return None
