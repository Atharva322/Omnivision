# Shop Assist — independent track

Development note for the Omnivision team, in the same spirit as [`TRACK_C.md`](./TRACK_C.md): what's
implemented, what's tested, and what still needs hardware this track doesn't have.

Per [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md): "one teammate handles shop assist
independently, leaving 4 engineers" on the social-memory build. This is that independent track. It
does not touch `Core/Protocols.swift`, does not run on the glasses, and is not part of the Swift app
— it's a standalone Python service, developed and tested entirely without a Mac or the glasses
hardware, because neither is available on this track.

**Nothing in this document reports a measurement against a real store or real glasses hardware.**
Every number below comes from mocked vision responses and unit tests. See §5.

---

## Product scope — deliberately narrower than in-store navigation

The wearer names a product; the system reports what's currently in the camera's view and, once the
right thing is visible, where it is or whether it's the right one. There is no turn-by-turn routing
and no physical infrastructure (QR codes, AprilTags) placed in the venue — earlier drafts of this
idea included both, and both were cut for this track because they require controlling the demo
venue, which this track cannot assume. What's left is two phases, both driven purely by the current
frame:

1. **Wandering** — report which section is in view (`"You're in the snacks section. Keep walking
   toward dairy."`). No directional instructions; the wearer moves themselves and the section report
   is the only feedback loop.
2. **Arrived** — once the current section matches the target category, locate the target product in
   the frame and report its position (`"Your usual Oatly Original is top left."`). If the product now
   fills the frame — the wearer picked it up and is holding it to the camera — switch to a yes/no
   confirmation instead of a position (`"Yes, this is your Oatly Original."` / `"This isn't your usual
   pick — it's Silk Unsweetened."`).

The mode switch is not computed from geometry or distance. The vision model is asked directly
whether a product fills the frame (`held_close: true/false`) — see §4 for why.

---

## What is implemented

| Plan item | File | State |
|---|---|---|
| Section report + no-navigation wandering guidance | `app/guidance.py` | done, unit tested |
| Preference matching (brand, optional variant) | `app/guidance.py::matches_preference` | done, unit tested |
| Held-close confirmation vs. position guidance | `app/guidance.py::build_guidance` | done, unit tested |
| One vision call for recognition + OCR + position + confirmation signal | `app/vision.py` | done, mocked in tests |
| `/set_target`, `/remember`, `/remember_photo`, `/locate`, `/ask` | `app/main.py` | done, endpoint tested |
| Per-session state (target, preferences, last seen products) | `app/sessions.py` | done |
| Section→demo-store-area lookup table | `app/guidance.py::SECTION_MAP` | done, fixed 7-category demo table |
| Preference persistence across restarts | `app/sessions.py::persist_preferences` | done, unit tested (flat JSON, same approach as Omnivision's `PersonStore`) |
| Recognition logic walked through with real store photos | — | **partially validated — see §5, still needs the real model** |
| Phone or glasses client | — | **not started — no Mac on this track, see §6** |
| Latency under real network conditions | — | **not measured** |

---

## Running it

No Apple toolchain, no glasses, no API key required for the test suite — every vision call is
monkeypatched. From `ShopAssist/backend/`:

```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements-dev.txt
pytest -v
```

Current results (Python 3.14.6, Windows):

```
tests/test_api.py       7 passed
tests/test_guidance.py 14 passed
                       21 passed in 1.47s
```

`app/guidance.py` has no dependency on FastAPI, OpenAI, or any I/O — every branch of
`build_guidance` (wandering, arrived-no-candidate, arrived-with-position,
arrived-preferred-vs-first-candidate, held-close-confirm, held-close-mismatch,
held-close-no-preference) is exercised directly with plain dicts. `tests/test_api.py` drives the
FastAPI app through `TestClient` with `app.vision.call_vision_json` and `app.vision.ask_about_context`
replaced by fixtures, so it validates the session/endpoint wiring without a network call.

Running against the real model, with a key, from the same directory:

```powershell
$env:OPENAI_API_KEY = "sk-..."
uvicorn app.main:app --reload --port 8000
```

`README.md` in this directory has the full curl walkthrough — set a preference from a photo, set a
target, and step through wrong-section → right-section → held-close frames — entirely on a laptop,
with photos taken on a phone and copied over. That sequence is identical to what a real client will
call; only the image source changes.

---

## Public interface

```
POST /set_target      session_id, item                      -> { target, target_section }
POST /remember         session_id, category, brand, variant   -> { category, preference }
POST /remember_photo   session_id, category, image            -> { category, preference }
POST /locate           session_id, image                      -> { current_section, products, guidance_text }
POST /ask              session_id, question                   -> { answer }
```

`guidance_text` is the only field a client needs to speak. `products` is exposed mainly for a demo
mirror (see `ARCHITECTURE.md` §8 for why Omnivision has one — the same argument applies here: a judge
cannot hear what's in the wearer's ear).

---

## Why one vision call, and why no barcode ground truth

**One multimodal call per frame** does section classification, product recognition, OCR, position,
and the `held_close` signal together. No separate OCR engine, no trained object detector, no
geometry code to infer "is this close to the camera" — the model is simply asked. This is the same
reasoning Track C applies to precision-over-recall: solve it with the model's judgement where a
bespoke pipeline would cost more time than it's worth on this schedule.

**No barcode scan as a final ground-truth check** — unlike an earlier draft of the broader team's
grocery concept, which used barcode matching specifically so the system could *never* assert a wrong
product. This track doesn't have that guarantee. Confirmation in `held_close` mode is a vision-model
judgement, not a deterministic match, and it can be wrong. That's a real accuracy gap relative to a
barcode-verified design, accepted here in exchange for not needing a maintained product/barcode
catalog or a barcode reader — out of scope for what this track can build alone. If accuracy on real
products turns out to be a problem, the fix is a barcode-scan step at the `held_close` confirmation
point specifically, not a redesign of the section/position logic.

---

## Still to be validated — nothing below can be faked from mocked responses

1. **The real GPT-4o model, specifically.** The full end-to-end scenario — set a preference from a
   photo, walk through an irrelevant section, arrive at the right one, distinguish between several
   similar products on the shelf, and confirm a held-close item — was walked through with real photos
   taken in an actual store, fed through the real `build_guidance()` code. That validated the *logic*.
   It did not validate `app/vision.py`'s actual API call: the JSON each step consumed was produced by
   manually reading the photo, not by calling GPT-4o. The system prompt in `app/vision.py` has never
   once been sent to the real model. That call — and how its output compares to the manual read —
   is the remaining gap, ideally tested with photos from the actual demo venue.
2. **A client.** This track has produced a backend only. No Mac was available to build a native
   glasses client, and the plan explicitly scoped glasses integration to the other four engineers'
   track. The fallback is a phone-browser page (camera input + fetch + speech synthesis) if no other
   client materializes in time — not yet built.
3. **Preference-photo extraction quality.** `/remember_photo` asks the model to read brand/variant off
   a single photo of a liked product. Walked through manually with two real preference photos (read by
   hand, pushed through the real endpoint and `persist_preferences`) — worked for both. Not yet tested
   with the real API, or with packaging that doesn't have brand/variant text as legible as a milk
   carton's.
4. **Latency per `/locate` call** under real network conditions (this matters more here than for
   Omnivision's on-device pipeline, since every frame is a round trip to a hosted model).

---

## Notes for the rest of the team

- This track is intentionally decoupled from `Core/Protocols.swift` and the rest of the Swift app —
  it was scoped out of the social-memory build from the start, so there's nothing here for Tracks
  A/B/C/D to integrate against.
- If a client ends up needed and someone on the Omnivision side has spare time near the end, the only
  useful contribution is a thin client that POSTs a frame to `/locate` and speaks back
  `guidance_text` — the backend contract above is the whole surface.
