from app.guidance import build_guidance, describe_position, matches_preference


def make_session(target=None, preferences=None, last_products=None) -> dict:
    return {
        "target": target,
        "preferences": preferences or {},
        "last_products": last_products or [],
    }


def make_product(**overrides) -> dict:
    product = {
        "name": "Oatly Original Oat Milk",
        "brand": "Oatly",
        "variant": "Original",
        "category": "milk",
        "position": {"horizontal": "left", "vertical": "top"},
        "held_close": False,
        "attributes": {},
    }
    product.update(overrides)
    return product


# --- matches_preference -----------------------------------------------------


def test_no_preference_never_matches():
    assert matches_preference(make_product(), None) is False
    assert matches_preference(make_product(), {}) is False


def test_brand_only_preference_matches_any_variant():
    preference = {"brand": "Oatly"}
    assert matches_preference(make_product(variant="Barista"), preference) is True


def test_brand_and_variant_must_both_match():
    preference = {"brand": "Oatly", "variant": "Original"}
    assert matches_preference(make_product(variant="Barista"), preference) is False
    assert matches_preference(make_product(variant="Original"), preference) is True


def test_wrong_brand_never_matches():
    preference = {"brand": "Silk"}
    assert matches_preference(make_product(brand="Oatly"), preference) is False


# --- describe_position -------------------------------------------------------


def test_describe_position_combines_vertical_and_horizontal():
    product = make_product(position={"horizontal": "right", "vertical": "bottom"})
    assert describe_position(product) == "bottom right"


def test_describe_position_handles_missing_fields():
    assert describe_position(make_product(position={})) == ""
    assert describe_position(make_product(position=None)) == ""


# --- build_guidance: wandering phase (no active navigation) -----------------


def test_no_target_just_reports_section():
    session = make_session(target=None)
    assert build_guidance(session, "dairy") == "You're in the dairy section."


def test_wrong_section_names_the_target_section_without_directions():
    session = make_session(target="milk")
    text = build_guidance(session, "snacks")
    assert text == "You're in the snacks section. Keep walking toward dairy."
    assert "turn" not in text.lower()  # no turn-by-turn instructions by design


# --- build_guidance: arrived phase, no matching candidates -------------------


def test_right_section_no_candidates_asks_to_look_around():
    session = make_session(target="milk", last_products=[make_product(category="chips")])
    text = build_guidance(session, "dairy")
    assert text == "You're in the dairy section. Look around for milk."


# --- build_guidance: arrived phase, position guidance ------------------------


def test_right_section_with_candidate_no_preference_reports_position():
    session = make_session(target="milk", last_products=[make_product()])
    text = build_guidance(session, "dairy")
    assert text == "Found Oatly Original top left."


def test_right_section_with_saved_preference_prioritises_it():
    session = make_session(
        target="milk",
        preferences={"milk": {"brand": "Oatly", "variant": "Original"}},
        last_products=[
            make_product(brand="Silk", variant="Unsweetened", position={"horizontal": "left", "vertical": "top"}),
            make_product(brand="Oatly", variant="Original", position={"horizontal": "right", "vertical": "middle"}),
        ],
    )
    text = build_guidance(session, "dairy")
    assert text == "Your usual Oatly Original is middle right."


# --- build_guidance: confirmation phase (held_close) -------------------------


def test_held_close_matching_preference_confirms():
    session = make_session(
        target="milk",
        preferences={"milk": {"brand": "Oatly", "variant": "Original"}},
        last_products=[make_product(held_close=True)],
    )
    text = build_guidance(session, "dairy")
    assert text == "This looks like your Oatly Original."


def test_held_close_not_matching_preference_flags_the_mismatch():
    session = make_session(
        target="milk",
        preferences={"milk": {"brand": "Oatly", "variant": "Original"}},
        last_products=[make_product(brand="Silk", variant="Unsweetened", held_close=True)],
    )
    text = build_guidance(session, "dairy")
    assert text == "This doesn't look like your usual pick — it looks like Silk Unsweetened. Your usual one should be nearby."


def test_held_close_with_no_saved_preference_states_identity_only():
    # No preference was ever recorded for this category — must not claim a "usual" exists.
    session = make_session(target="milk", last_products=[make_product(held_close=True)])
    text = build_guidance(session, "dairy")
    assert text == "This looks like Oatly Original."


def test_brand_only_preference_does_not_claim_the_variant_is_your_usual():
    """A preference saved from one photo often has no variant, and brand-only matching then
    matches every variant. The match may stand, but the wording must not call an unverified
    variant "your usual" — that is a confident wrong confirmation to a blind wearer.
    """
    session = {
        "target": "milk",
        "last_products": [
            {"brand": "Oatly", "variant": "Chocolate", "category": "milk", "held_close": True}
        ],
        "preferences": {"milk": {"brand": "Oatly"}},
    }
    text = build_guidance(session, "dairy")
    assert "your usual Oatly" in text
    assert "your Oatly Chocolate" not in text
    assert "don't have a variant saved" in text


def test_unidentified_product_is_not_narrated_as_a_name():
    """The real model returns brand/variant "unknown" for products it cannot read on a shelf.
    Interpolating that produced "Found unknown unknown top center." — spoken nonsense. The
    position is still useful, so say where it is without pretending to know what it is.
    """
    session = {
        "target": "milk",
        "last_products": [
            {
                "brand": "unknown",
                "variant": "unknown",
                "category": "milk",
                "held_close": False,
                "position": {"vertical": "top", "horizontal": "center"},
            }
        ],
        "preferences": {},
    }
    text = build_guidance(session, "dairy")
    assert "unknown" not in text.lower()
    assert "top center" in text


def test_partially_identified_product_uses_only_the_part_it_knows():
    session = {
        "target": "milk",
        "last_products": [
            {
                "brand": "unknown",
                "variant": "Almondmilk",
                "category": "milk",
                "held_close": False,
                "position": {"vertical": "top", "horizontal": "right"},
            }
        ],
        "preferences": {},
    }
    text = build_guidance(session, "dairy")
    assert "unknown" not in text.lower()
    assert "Almondmilk" in text


def test_held_close_unidentified_product_admits_it_cannot_tell():
    session = {
        "target": "milk",
        "last_products": [
            {"brand": "unknown", "variant": "unknown", "category": "milk", "held_close": True}
        ],
        "preferences": {},
    }
    text = build_guidance(session, "dairy")
    assert "unknown" not in text.lower()
    assert "can't tell" in text.lower() or "cannot tell" in text.lower()
