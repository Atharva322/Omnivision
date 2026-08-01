"""The only place this track calls out to a vision model.

One multimodal call per frame does recognition + OCR + position/confirmation
judgement together — no separate OCR engine, no trained detector. See
docs/SHOP_ASSIST.md for why that's the right tradeoff for a 12-hour track.
"""

import json

from openai import OpenAI

_client: OpenAI | None = None


def get_client() -> OpenAI:
    global _client
    if _client is None:
        _client = OpenAI()  # reads OPENAI_API_KEY from the environment
    return _client


def call_vision_json(image_b64: str, system_prompt: str, user_prompt: str) -> dict:
    response = get_client().chat.completions.create(
        model="gpt-4o",
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
                    },
                ],
            },
        ],
        max_tokens=600,
    )
    return json.loads(response.choices[0].message.content)


LOCATE_SYSTEM_PROMPT = """You are a grocery store scene analysis assistant. Analyze the photo and \
return ONLY JSON in this format:
{
  "section": "dairy | bakery | snacks | beverages | produce | breakfast | other",
  "products": [
    {
      "name": "full product name",
      "brand": "brand name",
      "variant": "flavor/type, e.g. Original, Unsweetened",
      "category": "milk | yogurt | cheese | bread | cereal | chips | soda | other",
      "position": {"horizontal": "left | center | right", "vertical": "top | middle | bottom"},
      "held_close": false,
      "attributes": {"sugar_free": bool, "low_fat": bool},
      "ingredients": "short ingredient description, or \"unknown\" if not visible",
      "allergens": ["list any allergens visible on the label"],
      "expiry_date": "fill in if visible, otherwise null"
    }
  ]
}
held_close means this product is being held up close to the camera, filling the frame (as opposed to
being one of several products on a shelf in the background).
For any field you're unsure about, use "unknown" or null — never make something up."""

REMEMBER_PHOTO_SYSTEM_PROMPT = """Analyze the product in this photo and return ONLY JSON:
{
  "category": "milk | yogurt | cheese | bread | cereal | chips | soda | other",
  "brand": "brand name",
  "variant": "flavor/type",
  "attributes": {"sugar_free": bool, "low_fat": bool}
}
For any field you're unsure about, use "unknown"."""

ASK_SYSTEM_PROMPT = (
    "You are a shopping assistant. Answer the user's question based on the products currently in "
    "view, in one or two short, conversational sentences."
)


def ask_about_context(context: dict, question: str) -> str:
    response = get_client().chat.completions.create(
        model="gpt-4o",
        messages=[
            {"role": "system", "content": ASK_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Current context: {json.dumps(context)}\nQuestion: {question}",
            },
        ],
        max_tokens=200,
    )
    return response.choices[0].message.content
