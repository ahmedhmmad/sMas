"""قناة إرسال رمز OTP (D3/I7).

القناة الحقيقية (WhatsApp عبر SendWhats، SMS، البريد) خارج D3 — المرحلة 5. هنا الواجهة ومرسل محلي للاختبار.
`API_OTP_SENDER=local` يفعّل المرسل المحلي؛ بدونه لا قناة ⇒ مسارات OTP ترد `503` (لا رمز يُصدر بلا وسيلة إيصال).
"""

import os
import threading
from typing import Protocol


class OtpSender(Protocol):
    def send(self, kind: str, contact: str, code: str) -> None: ...


class LocalOutbox:
    """مرسل تطوير/اختبار: يحفظ الرسائل في الذاكرة. لا يُعرض عبر أي مسار HTTP."""

    def __init__(self) -> None:
        self.messages: list[tuple[str, str, str]] = []
        self._lock = threading.Lock()

    def send(self, kind: str, contact: str, code: str) -> None:
        with self._lock:
            self.messages.append((kind, contact, code))


def load_sender() -> OtpSender | None:
    return LocalOutbox() if os.environ.get("API_OTP_SENDER") == "local" else None
