# Shop Assist — macOS runbook

`README.md` is PowerShell (written on Windows). These are the macOS equivalents.

## Install

```bash
cd ShopAssist/backend
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
```

## Tests — no API key needed

```bash
.venv/bin/python -m pytest -q     # expect: 22 passed
```

Every vision call is monkeypatched, so this validates logic and wiring but **never touches the
model**. That is the gap the next step closes.

## The real-model check — needs a key

```bash
export OPENAI_API_KEY=sk-...
.venv/bin/python real_model_check.py
```

Drives all five committed sample photos through the real GPT-4o call and prints the section,
products, `held_close` flag, per-call latency and the resulting guidance sentence. No server, no
phone, no glasses.

The system prompt in `app/vision.py` has never once been sent to the model, so this is the first
time it is exercised. A failure here is the prompt or the API — the wiring is already covered by
the unit tests.

**What to judge, beyond "did it not crash":**

- Section correct on `01_coffee_area` and `02_fruit_area` (both should be wrong-section)
- `held_close` true on `04` and **false on everything else** — the mode switch depends entirely on it
- Latency per call. A wearer is standing in an aisle waiting; anything over ~3 s changes the UX
- Whether it distinguishes similar products on `03_dairy_shelf`

## Serve it

```bash
export OPENAI_API_KEY=sk-...
.venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Expose to a phone with `ngrok http 8000`.

## Note on the sample photos

The five JPEGs are 2–3 MB each, ~15 MB total, and they are the input to a vision API that does not
need that resolution. Downscaling them to roughly 200 KB before this branch merges would keep the
repo small; after it merges they are in git history permanently.
