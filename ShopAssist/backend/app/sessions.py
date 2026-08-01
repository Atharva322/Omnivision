"""Per-session state. Preferences persist to a JSON file; everything else (current
target, last-seen products) is only relevant for the current shopping trip and stays
in memory only — no reason to survive a restart.
"""

import json
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
PREFERENCES_PATH = DATA_DIR / "preferences.json"

sessions: dict[str, dict] = {}


def _load_all_preferences() -> dict:
    if PREFERENCES_PATH.exists():
        return json.loads(PREFERENCES_PATH.read_text(encoding="utf-8"))
    return {}


_stored_preferences = _load_all_preferences()


def get_session(session_id: str) -> dict:
    if session_id not in sessions:
        sessions[session_id] = {
            "target": None,
            "preferences": dict(_stored_preferences.get(session_id, {})),
            "last_products": [],
        }
    return sessions[session_id]


def persist_preferences(session_id: str) -> None:
    """Write this session's current preferences to disk. Call after any change."""
    session = get_session(session_id)
    _stored_preferences[session_id] = session["preferences"]
    DATA_DIR.mkdir(exist_ok=True)
    PREFERENCES_PATH.write_text(
        json.dumps(_stored_preferences, indent=2, ensure_ascii=False), encoding="utf-8"
    )


def reset_sessions() -> None:
    sessions.clear()
