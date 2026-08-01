"""Run the full shop-assist flow against the REAL GPT-4o model.

Everything in the test suite monkeypatches `call_vision_json`, so the system prompt in
`app/vision.py` has never once been sent to the model. This script is the missing half: it drives
the real API with the sample photos already committed to the repo, and prints what came back.

    export OPENAI_API_KEY=sk-...
    .venv/bin/python real_model_check.py

No server, no phone, no glasses. It calls `build_guidance` directly with real model output, so a
failure here is either the prompt or the model — never the wiring, which the unit tests cover.

Exit code is 0 only if every stage returned usable JSON.
"""

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from app.guidance import SECTION_MAP, build_guidance  # noqa: E402
from app.vision import LOCATE_SYSTEM_PROMPT, call_vision_json  # noqa: E402

PHOTOS = Path(__file__).parent / "sample_photos"

# Ordered to mirror the real wearer journey: save a preference, wander through two wrong
# sections, arrive at the right shelf, then hold the product up.
STAGES = [
    ("00_green_milk_preference.jpeg", "preference photo — what the wearer likes"),
    ("01_coffee_area.jpeg", "wandering — wrong section"),
    ("02_fruit_area.jpg.jpeg", "wandering — still wrong"),
    ("03_dairy_shelf.jpeg", "arrived — target section, product on shelf"),
    ("04_held_close_green_milk.jpeg", "held close — confirmation"),
]


def encode(path: Path) -> str:
    import base64
    return base64.b64encode(path.read_bytes()).decode()


def main() -> int:
    if not os.environ.get("OPENAI_API_KEY"):
        print("OPENAI_API_KEY is not set. Export it and re-run.")
        return 2

    session = {"target": "milk", "last_products": [], "preferences": {}}
    target_section = SECTION_MAP.get("milk", "milk")
    failures = 0

    print(f"target: milk  ->  section: {target_section}\n" + "=" * 72)

    for filename, description in STAGES:
        path = PHOTOS / filename
        if not path.exists():
            print(f"MISSING  {filename}")
            failures += 1
            continue

        size_mb = path.stat().st_size / 1_048_576
        print(f"\n{filename}  ({size_mb:.1f} MB)\n  {description}")

        started = time.time()
        try:
            result = call_vision_json(
                encode(path),
                LOCATE_SYSTEM_PROMPT,
                "What section is this, and what products are visible?",
            )
        except Exception as exc:  # noqa: BLE001 - this script exists to surface real API failures
            print(f"  API ERROR: {type(exc).__name__}: {exc}")
            failures += 1
            continue
        elapsed = time.time() - started

        section = (result.get("section") or "").lower()
        products = result.get("products") or []
        print(f"  {elapsed:.1f}s   section={section!r}   {len(products)} product(s)")
        for product in products[:4]:
            held = "  HELD_CLOSE" if product.get("held_close") else ""
            position = product.get("position") or {}
            where = f"{position.get('vertical','')} {position.get('horizontal','')}".strip()
            print(
                f"     - {product.get('brand','?')} {product.get('variant','')}"
                f"  [{product.get('category','?')}]  {where}{held}"
            )

        # First photo defines the preference, exactly as /remember_photo would.
        if filename.startswith("00") and products:
            first = products[0]
            session["preferences"]["milk"] = {
                "brand": first.get("brand"),
                "variant": first.get("variant"),
            }
            print(f"  saved preference: {json.dumps(session['preferences']['milk'])}")
            continue

        session["last_products"] = products
        print(f"  GUIDANCE: {build_guidance(session, section)}")

    print("\n" + "=" * 72)
    if failures:
        print(f"{failures} stage(s) failed — the prompt or the API, not the wiring.")
        return 1

    print("All stages returned usable JSON.")
    print(
        "\nNow check the WORDING against docs/SHOP_ASSIST.md, and specifically:"
        "\n  - did it get the section right on the two wandering photos?"
        "\n  - did it set held_close ONLY on 04?"
        "\n  - is latency per call acceptable for a wearer standing in an aisle?"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
