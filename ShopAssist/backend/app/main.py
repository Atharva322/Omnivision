import base64

from fastapi import FastAPI, UploadFile, Form

from . import vision
from .guidance import SECTION_MAP, build_guidance
from .sessions import get_session, persist_preferences
from .vision import LOCATE_SYSTEM_PROMPT, REMEMBER_PHOTO_SYSTEM_PROMPT

# vision.call_vision_json / vision.ask_about_context are called through the module
# below (not imported by name) so tests can monkeypatch them — see tests/test_api.py.

app = FastAPI()


@app.post("/set_target")
async def set_target(session_id: str = Form(...), item: str = Form(...)):
    session = get_session(session_id)
    session["target"] = item.lower()
    return {"target": session["target"], "target_section": SECTION_MAP.get(item.lower(), item.lower())}


@app.post("/remember_photo")
async def remember_photo(session_id: str = Form(...), category: str = Form(...), image: UploadFile = None):
    session = get_session(session_id)
    image_bytes = await image.read()
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")

    result = vision.call_vision_json(image_b64, REMEMBER_PHOTO_SYSTEM_PROMPT, "Identify this product.")
    preference = {
        "brand": result.get("brand"),
        "variant": result.get("variant"),
        "attributes": result.get("attributes", {}),
    }
    session["preferences"][category.lower()] = preference
    persist_preferences(session_id)
    return {"category": category.lower(), "preference": preference}


@app.post("/remember")
async def remember(
    session_id: str = Form(...),
    category: str = Form(...),
    brand: str = Form(...),
    variant: str = Form(""),
):
    session = get_session(session_id)
    preference = {"brand": brand, "variant": variant, "attributes": {}}
    session["preferences"][category.lower()] = preference
    persist_preferences(session_id)
    return {"category": category.lower(), "preference": preference}


@app.post("/locate")
async def locate(session_id: str = Form(...), image: UploadFile = None):
    session = get_session(session_id)
    image_bytes = await image.read()
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")

    result = vision.call_vision_json(image_b64, LOCATE_SYSTEM_PROMPT, "Analyze this grocery shelf photo.")
    session["last_products"] = result.get("products", [])
    current_section = result.get("section", "unknown")

    guidance_text = build_guidance(session, current_section)

    return {
        "current_section": current_section,
        "products": result.get("products", []),
        "guidance_text": guidance_text,
    }


@app.post("/ask")
async def ask(
    session_id: str = Form(...),
    question: str = Form(...),
    product_context: str = Form(""),
):
    session = get_session(session_id)
    context = {
        "visible_products": session["last_products"],
        "preferences": session["preferences"],
    }
    if product_context:
        # docs/SHOP_SCREEN_PLAN.md Task 7: the Swift client does its own on-device recognition
        # and never calls /locate, so session["last_products"] is never populated in that flow.
        # It sends what it currently sees directly instead — raw OCR'd package text, not a
        # structured product list, since that's what on-device text recognition actually produces.
        context["currently_visible_text"] = product_context
    return {"answer": vision.ask_about_context(context, question)}
