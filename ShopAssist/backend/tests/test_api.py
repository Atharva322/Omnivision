"""End-to-end endpoint tests with the vision model mocked out.

No network calls, no API key required. These check the session flow — set target,
record a preference, walk through sections, arrive, confirm — the same sequence
described in docs/SHOP_ASSIST.md as the curl walkthrough, just automated.
"""

import io

import pytest
from fastapi.testclient import TestClient

from app import main, sessions, vision
from app.sessions import reset_sessions


@pytest.fixture(autouse=True)
def _clean_sessions(tmp_path, monkeypatch):
    # Redirect preference persistence to a throwaway file so tests never touch
    # (or get polluted by) the real ShopAssist/backend/data/preferences.json.
    monkeypatch.setattr(sessions, "DATA_DIR", tmp_path)
    monkeypatch.setattr(sessions, "PREFERENCES_PATH", tmp_path / "preferences.json")
    monkeypatch.setattr(sessions, "_stored_preferences", {})
    reset_sessions()
    yield
    reset_sessions()


@pytest.fixture
def client():
    return TestClient(main.app)


def fake_image():
    return {"image": ("frame.jpg", io.BytesIO(b"fake-bytes"), "image/jpeg")}


def test_set_target_reports_mapped_section(client):
    response = client.post("/set_target", data={"session_id": "s1", "item": "Milk"})
    assert response.status_code == 200
    assert response.json() == {"target": "milk", "target_section": "dairy"}


def test_remember_stores_structured_preference(client):
    response = client.post(
        "/remember",
        data={"session_id": "s1", "category": "milk", "brand": "Oatly", "variant": "Original"},
    )
    assert response.json() == {
        "category": "milk",
        "preference": {"brand": "Oatly", "variant": "Original", "attributes": {}},
    }


def test_preference_survives_a_server_restart(client):
    client.post(
        "/remember",
        data={"session_id": "s1", "category": "milk", "brand": "Oatly", "variant": "Original"},
    )
    assert sessions.PREFERENCES_PATH.exists()

    # Simulate a real process restart: both the per-session state AND the
    # in-memory preferences cache are gone. Only the file on disk survives.
    reset_sessions()
    sessions._stored_preferences.clear()
    sessions._stored_preferences.update(sessions._load_all_preferences())

    session = sessions.get_session("s1")
    assert session["preferences"]["milk"] == {"brand": "Oatly", "variant": "Original", "attributes": {}}


def test_remember_photo_uses_vision_extraction(client, monkeypatch):
    monkeypatch.setattr(
        vision,
        "call_vision_json",
        lambda image_b64, system_prompt, user_prompt: {
            "category": "milk",
            "brand": "Oatly",
            "variant": "Original",
            "attributes": {"sugar_free": True},
        },
    )
    response = client.post("/remember_photo", data={"session_id": "s1", "category": "milk"}, files=fake_image())
    assert response.json() == {
        "category": "milk",
        "preference": {"brand": "Oatly", "variant": "Original", "attributes": {"sugar_free": True}},
    }


def test_locate_wandering_then_arrival_then_confirmation(client, monkeypatch):
    client.post("/set_target", data={"session_id": "s1", "item": "milk"})
    client.post(
        "/remember", data={"session_id": "s1", "category": "milk", "brand": "Oatly", "variant": "Original"}
    )

    # Frame 1: wrong section entirely.
    monkeypatch.setattr(vision, "call_vision_json", lambda *a, **k: {"section": "snacks", "products": []})
    resp = client.post("/locate", data={"session_id": "s1"}, files=fake_image())
    assert resp.json()["guidance_text"] == "You're in the snacks section. Keep walking toward dairy."

    # Frame 2: right section, target visible on a shelf.
    monkeypatch.setattr(
        vision,
        "call_vision_json",
        lambda *a, **k: {
            "section": "dairy",
            "products": [
                {
                    "name": "Oatly Original Oat Milk",
                    "brand": "Oatly",
                    "variant": "Original",
                    "category": "milk",
                    "position": {"horizontal": "left", "vertical": "top"},
                    "held_close": False,
                }
            ],
        },
    )
    resp = client.post("/locate", data={"session_id": "s1"}, files=fake_image())
    assert resp.json()["guidance_text"] == "Your usual Oatly Original is top left."

    # Frame 3: wearer picked it up and holds it to the camera.
    monkeypatch.setattr(
        vision,
        "call_vision_json",
        lambda *a, **k: {
            "section": "dairy",
            "products": [
                {
                    "name": "Oatly Original Oat Milk",
                    "brand": "Oatly",
                    "variant": "Original",
                    "category": "milk",
                    "position": {"horizontal": "center", "vertical": "middle"},
                    "held_close": True,
                }
            ],
        },
    )
    resp = client.post("/locate", data={"session_id": "s1"}, files=fake_image())
    assert resp.json()["guidance_text"] == "Yes, this is your Oatly Original."


def test_ask_uses_last_located_products_as_context(client, monkeypatch):
    client.post("/set_target", data={"session_id": "s1", "item": "milk"})
    monkeypatch.setattr(
        vision,
        "call_vision_json",
        lambda *a, **k: {
            "section": "dairy",
            "products": [{"name": "Oatly Original", "category": "milk", "attributes": {"sugar_free": True}}],
        },
    )
    client.post("/locate", data={"session_id": "s1"}, files=fake_image())

    captured = {}

    def fake_ask(context, question):
        captured["context"] = context
        captured["question"] = question
        return "Yes, it's sugar free."

    monkeypatch.setattr(vision, "ask_about_context", fake_ask)
    resp = client.post("/ask", data={"session_id": "s1", "question": "Is this sugar free?"})

    assert resp.json() == {"answer": "Yes, it's sugar free."}
    assert captured["question"] == "Is this sugar free?"
    assert captured["context"]["visible_products"][0]["name"] == "Oatly Original"


def test_sessions_are_isolated_by_session_id(client, monkeypatch):
    client.post("/set_target", data={"session_id": "a", "item": "milk"})
    client.post("/set_target", data={"session_id": "b", "item": "bread"})

    monkeypatch.setattr(vision, "call_vision_json", lambda *a, **k: {"section": "bakery", "products": []})

    resp_a = client.post("/locate", data={"session_id": "a"}, files=fake_image())
    resp_b = client.post("/locate", data={"session_id": "b"}, files=fake_image())

    assert resp_a.json()["guidance_text"] == "You're in the bakery section. Keep walking toward dairy."
    assert resp_b.json()["guidance_text"] == "You're in the bakery section. Look around for bread."
