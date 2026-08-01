# Shop Assist backend

See [`docs/SHOP_ASSIST.md`](../../docs/SHOP_ASSIST.md) for design rationale, what's tested, and what
still needs a real device. This file is just setup and commands.

## 1. Install

```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements-dev.txt
```

## 2. Run the tests (no API key needed)

```powershell
pytest -v
```

All vision calls are mocked in tests — nothing here talks to the network.

## 3. Run the server for real

```powershell
$env:OPENAI_API_KEY = "sk-..."
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## 4. Expose it to a phone for demo

```powershell
ngrok http 8000
```

## 5. Walk the flow with curl (no phone/glasses needed to validate the logic)

Take a few reference photos on your phone and copy them over: a shot of the product you like
(`milk_i_like.jpg`), a wrong-section shelf (`shelf_wrong_section.jpg`), the right shelf
(`shelf_dairy.jpg`), and the product held up close (`held_close.jpg`).

```powershell
curl -X POST http://localhost:8000/remember_photo -F "session_id=test1" -F "category=milk" -F "image=@milk_i_like.jpg"

curl -X POST http://localhost:8000/set_target -F "session_id=test1" -F "item=milk"

curl -X POST http://localhost:8000/locate -F "session_id=test1" -F "image=@shelf_wrong_section.jpg"
curl -X POST http://localhost:8000/locate -F "session_id=test1" -F "image=@shelf_dairy.jpg"
curl -X POST http://localhost:8000/locate -F "session_id=test1" -F "image=@held_close.jpg"

curl -X POST http://localhost:8000/ask -F "session_id=test1" -F "question=Is this sugar free?"
```

The same sequence is what a phone/glasses client calls once one exists — only the image source
changes, the API contract does not.

## API summary

| Endpoint | Purpose |
|---|---|
| `POST /set_target` | `session_id`, `item` → what the wearer is looking for |
| `POST /remember_photo` | `session_id`, `category`, `image` → derive + save a preference from a photo |
| `POST /remember` | `session_id`, `category`, `brand`, `variant` → save a preference by hand |
| `POST /locate` | `session_id`, `image` → `current_section`, `products`, `guidance_text` |
| `POST /ask` | `session_id`, `question` → free-form Q&A over the last `/locate` result |
