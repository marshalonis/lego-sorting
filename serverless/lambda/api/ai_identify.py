import base64
import io
import json
import os
import re
import anthropic
from PIL import Image

# ---------------------------------------------------------------------------
# AWS Bedrock — region is set automatically by Lambda via AWS_REGION env var
# ---------------------------------------------------------------------------

client = anthropic.AnthropicBedrock(
    aws_region=os.environ.get("AWS_REGION", "us-east-1"),
)

_MODEL = os.environ.get(
    "BEDROCK_MODEL_ID",
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
)

SYSTEM_PROMPT = """You are an expert LEGO part identifier. When given an image of a LEGO part, identify it and respond ONLY with a JSON object — no markdown, no explanation.

JSON fields:
- part_num: string or null — the official LEGO part number (e.g. "3001", "32524"). Use null if unsure.
- name: string — common name (e.g. "2x4 Brick", "Technic Axle 5")
- category: string — one of: Brick, Plate, Slope, Tile, Technic, Minifig, Wheel, Window, Door, Plant, Animal, Other
- color: string — color name (e.g. "Red", "Dark Bluish Gray", "Transparent Blue")
- description: string — brief description of the part's shape and features
- confidence: number — 0.0 to 1.0, your confidence in the identification

If you cannot identify the part, still provide your best guess with a low confidence score."""


_MAX_BYTES = 4 * 1024 * 1024  # 4MB — safely under the 5MB Bedrock limit


def _compress_image(image_bytes: bytes) -> tuple[bytes, str]:
    """Resize/compress image to fit within Bedrock's 5MB limit."""
    img = Image.open(io.BytesIO(image_bytes))
    img = img.convert("RGB")
    quality = 85
    while True:
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=quality)
        data = buf.getvalue()
        if len(data) <= _MAX_BYTES or quality <= 40:
            return data, "image/jpeg"
        # Reduce quality first, then scale down
        if quality > 40:
            quality -= 15
        else:
            w, h = img.size
            img = img.resize((w // 2, h // 2), Image.LANCZOS)
            quality = 70


def identify_part(image_bytes: bytes, media_type: str = "image/jpeg", model_id: str = None) -> dict:
    """Send image to Claude vision and return structured identification."""
    if len(image_bytes) > _MAX_BYTES:
        image_bytes, media_type = _compress_image(image_bytes)
    b64 = base64.standard_b64encode(image_bytes).decode("utf-8")

    message = client.messages.create(
        model=model_id or _MODEL,
        max_tokens=512,
        system=SYSTEM_PROMPT,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": media_type,
                            "data": b64,
                        },
                    },
                    {
                        "type": "text",
                        "text": "Identify this LEGO part.",
                    },
                ],
            }
        ],
    )

    raw = message.content[0].text.strip()
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)

    try:
        result = json.loads(raw)
    except json.JSONDecodeError:
        result = {
            "part_num": None,
            "name": "Unknown Part",
            "category": "Other",
            "color": "Unknown",
            "description": raw,
            "confidence": 0.0,
        }

    result.setdefault("part_num", None)
    result.setdefault("name", "Unknown Part")
    result.setdefault("category", "Other")
    result.setdefault("color", "Unknown")
    result.setdefault("description", "")
    result.setdefault("confidence", 0.5)

    return result
