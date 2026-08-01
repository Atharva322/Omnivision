"""Pure decision logic: no navigation, no markers, no barcode ground truth.

Two phases only, driven entirely by what the current camera frame shows:

1. Wandering  — report which section is in view. No "turn left" style instructions;
   the wearer moves themselves and the section report is the only feedback.
2. Arrived    — once the current section matches the target category, locate the
   target product within the frame and report its position. If the held product
   fills the frame (`held_close`), switch to a yes/no confirmation instead of a
   position.

This intentionally has no barcode-scan step. Confirmation is a vision-model
judgement, not a deterministic match — see docs/SHOP_ASSIST.md for why that
tradeoff was made for this track.
"""

# Product category -> demo store section. Small fixed table, matches the demo catalog.
SECTION_MAP = {
    "milk": "dairy",
    "yogurt": "dairy",
    "cheese": "dairy",
    "bread": "bakery",
    "cereal": "breakfast",
    "chips": "snacks",
    "soda": "beverages",
}


def matches_preference(product: dict, preference: dict | None) -> bool:
    """A product matches a saved preference only on brand (+ variant if one is set).

    No preference recorded -> nothing can match it. This is deliberate: with no
    preference, `build_guidance` falls through to "first candidate in view" rather
    than silently matching everything.
    """
    if not preference:
        return False
    brand = (preference.get("brand") or "").lower()
    variant = (preference.get("variant") or "").lower()
    product_brand = (product.get("brand") or "").lower()
    product_variant = (product.get("variant") or "").lower()

    brand_match = bool(brand) and brand in product_brand
    variant_match = (not variant) or variant in product_variant
    return brand_match and variant_match


def describe_position(product: dict) -> str:
    position = product.get("position") or {}
    vertical = position.get("vertical", "")
    horizontal = position.get("horizontal", "")
    return f"{vertical} {horizontal}".strip()


def build_guidance(session: dict, current_section: str) -> str:
    target = session.get("target")
    if not target:
        return f"You're in the {current_section} section."

    target_section = SECTION_MAP.get(target, target)

    if current_section != target_section:
        return f"You're in the {current_section} section. Keep walking toward {target_section}."

    candidates = [p for p in session["last_products"] if (p.get("category") or "").lower() == target]
    if not candidates:
        return f"You're in the {target_section} section. Look around for {target}."

    preference = session["preferences"].get(target)
    preferred_matches = [p for p in candidates if matches_preference(p, preference)] if preference else []
    chosen = preferred_matches[0] if preferred_matches else candidates[0]

    # The chosen product fills the frame -> the wearer is holding it up. Switch to confirmation.
    if chosen.get("held_close"):
        label = f"{chosen.get('brand', '')} {chosen.get('variant', '')}".strip()
        if not preference:
            # Nothing was ever saved for this category — state identity, don't imply a "usual" exists.
            return f"This is {label}."
        if preferred_matches:
            return f"Yes, this is your {label}."
        return f"This isn't your usual pick — it's {label}. Your usual one should be nearby."

    label = f"{chosen.get('brand', '')} {chosen.get('variant', '')}".strip()
    position_text = describe_position(chosen)
    if preferred_matches:
        return f"Your usual {label} is {position_text}."
    return f"Found {label} {position_text}."
