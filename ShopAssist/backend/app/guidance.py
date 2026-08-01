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


# The vision model returns the literal string "unknown" for fields it cannot read. Interpolating
# that produced "Found unknown unknown top center." — spoken nonsense to someone who cannot see the
# shelf. Treat it as absent rather than as a name.
_UNREADABLE = {"", "unknown", "unclear", "n/a", "none", "unreadable"}


def readable(value: str | None) -> str:
    """The value if the model actually read it, else empty."""
    text = (value or "").strip()
    return "" if text.lower() in _UNREADABLE else text


def product_label(product: dict) -> str:
    """Display name from whatever was legible. Empty when nothing was."""
    parts = [readable(product.get("brand")), readable(product.get("variant"))]
    return " ".join(p for p in parts if p).strip()


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
        label = product_label(chosen)
        if not label:
            # Held up but illegible. Saying nothing useful is better than naming it wrongly, and
            # the wearer can act on this — it tells them to move it.
            return "I can't tell what this is. Try turning it slowly toward the camera."
        if not preference:
            # Nothing was ever saved for this category — name it, don't imply a "usual" exists.
            return f"This looks like {label}."
        if preferred_matches:
            # "Looks like", not "Yes, this is". Without the barcode step this is a vision-model
            # judgement, and the wording has to match the strength of the evidence — the same
            # assert-vs-hedge rule the social track follows.
            #
            # And say WHICH part matched. A brand-only preference matches every variant, so
            # calling Oatly Chocolate "your usual" when only "Oatly" was ever saved overstates
            # what is known.
            if not (preference.get("variant") or "") and (chosen.get("variant") or ""):
                brand = chosen.get("brand", "")
                return f"This looks like {label}. That matches your usual {brand}, though I don't have a variant saved."
            return f"This looks like your {label}."
        return f"This doesn't look like your usual pick — it looks like {label}. Your usual one should be nearby."

    label = product_label(chosen)
    position_text = describe_position(chosen)
    if not label:
        # Position is still genuinely useful even when the product cannot be named.
        return f"There's something here {position_text}." if position_text else "There's something here."
    if preferred_matches:
        return f"Your usual {label} is {position_text}."
    # Position guidance is help finding something, not a claim about what it is, so "found" is
    # fine here — the identity claim only happens in held_close mode above.
    return f"Found {label} {position_text}."
