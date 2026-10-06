"""Phase 2B-4 (E6) — التحقق من الصورة **من بايتاتها الفعلية** لا مما يرسله العميل.

التوقيع السحري (PNG أو JPEG فقط — لا SVG)، الأبعاد من الترويسة، الحجم ≤ 1MiB. النوع (`content_type`) يُحدَّد من التوقيع؛
اسم الملف ونوعه المعلَن من العميل يُهملان. بلا مكتبة صور وبلا إعادة ترميز (قرار E6): قراءة الترويسة وحدها.
"""

import struct

MAX_BYTES = 1_048_576
MAX_SIDE = 4000
_PNG = b"\x89PNG\r\n\x1a\n"
_JPEG = b"\xff\xd8\xff"


class ImageRejected(ValueError):
    """السبب: size | format | dimensions — لا تفاصيل أخرى تعود للعميل."""


def inspect(data: bytes) -> tuple[str, int, int]:
    """(content_type, width, height) أو ImageRejected."""
    if not data or len(data) > MAX_BYTES:
        raise ImageRejected("size")
    if data.startswith(_PNG):
        if len(data) < 24 or data[12:16] != b"IHDR":
            raise ImageRejected("format")
        width, height = struct.unpack(">II", data[16:24])
        content_type = "image/png"
    elif data.startswith(_JPEG):
        width, height = _jpeg_size(data)
        content_type = "image/jpeg"
    else:
        raise ImageRejected("format")
    if not (1 <= width <= MAX_SIDE and 1 <= height <= MAX_SIDE):
        raise ImageRejected("dimensions")
    return content_type, width, height


def _jpeg_size(data: bytes) -> tuple[int, int]:
    """يمشي على مقاطع JPEG حتى أول SOFn (عدا DHT/JPG/DAC) ويقرأ الارتفاع والعرض."""
    i = 2
    while i + 9 <= len(data):
        if data[i] != 0xFF:
            raise ImageRejected("format")
        marker = data[i + 1]
        if marker == 0xFF:                                  # حشو
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:  # بلا طول
            i += 2
            continue
        (length,) = struct.unpack(">H", data[i + 2:i + 4])
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        if marker in (0xDA, 0xD9) or length < 2:            # بداية البيانات أو النهاية قبل SOF
            break
        i += 2 + length
    raise ImageRejected("format")
