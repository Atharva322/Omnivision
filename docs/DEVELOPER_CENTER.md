# Meta Wearables Developer Center — capability audit

Written after Meta staff recommended making fuller use of the Wearables Developer Center. This is the
audit of everything it offers, what we adopt, and what we reject with reasons.

**Headline finding:** the richest capability set — Web Apps, with captouch, Neural Band, motion,
orientation, and GPS — is unavailable to us twice over. It requires Ray-Ban Display hardware, and it
**cannot access the camera or microphone at all**. See §2 before anyone acts on that advice.

---

## 1. Verdict summary

| Capability | Status | Notes |
|---|---|---|
| **DAT MCP server** (live docs) | ✅ **adopt now** | Already wired in — see §3 |
| **llms.txt** full API reference | ✅ adopt | Feed to any AI agent for exact signatures |
| **Repo-native Claude Code plugin** | ✅ adopt | Ships inside the SDK repo; free patterns |
| **Mock Device Kit** | ✅ already planned | Unblocks 3 of 4 engineers |
| **Permission simulation** (v0.6) | ✅ **newly adopted** | Test permission flows with no hardware |
| **Video streaming simulation** (v0.6) | ✅ **newly adopted** | Phone camera stands in for glasses |
| **Release channels + orgs** | ✅ **newly adopted** | Distribute builds to teammates — no TestFlight |
| **DeviceState / ThermalLevel** (v0.7) | ✅ **newly adopted** | We run continuous audio; thermals are real |
| **Sample applications** | ✅ adopt | Start from Meta's sample, don't scaffold from zero |
| **Web Apps** | ❌ **reject** | No camera, no microphone. Fatal. See §2 |
| **Captouch / Neural Band input** | ❌ unavailable | Display-only, and only via Web Apps |
| **MWDATDisplay** | ❌ unavailable | Requires Ray-Ban Display hardware |
| **"Hey Meta" wake word** | ❌ unavailable | Not exposed to third parties |

---

## 2. Why Web Apps cannot work — read before re-raising this

Web Apps are the most capable-sounding surface in the Developer Center. On paper they offer exactly
the input model this product wants: silent, discreet, hands-free.

- Neural Band gesture input
- Captouch temple-strip swipes
- `DeviceMotionEvent` / `DeviceOrientationEvent` — accelerometer, gyroscope, compass
- `navigator.geolocation` via the paired phone
- `localStorage`
- Plain HTML/CSS/JS — no Xcode, no Mac, no Swift

For a blind user this input model would be a genuine upgrade over voice commands. Saying *"Lumen, who
is this"* out loud while standing in front of that person is socially costly. A silent temple swipe
is not.

**But Meta's own Build guide lists Web Apps as not supporting:** camera, microphone, text input,
offline support, notifications, back navigation.

No microphone means no transcription. No camera means no face clustering. **The entire product is
audio and vision.** There is no version of Omnivision that runs as a Web App today, on any hardware.

Two further blockers even if that changed: Web Apps are **Ray-Ban Display only** (glasses v125+, Meta
AI app v272+), and we have Gen 1/2. And DAT enforces **one active session per device**, so a native
app and a Web App likely cannot hold the glasses simultaneously.

**Conclusion: stay native. This is settled, not deferred.**

---

## 3. AI-assisted development — adopted, highest immediate payoff

Meta ships three complementary layers. Use all three.

### 3.1 MCP live-docs server — already configured

```bash
claude mcp add --transport http wearables --scope user https://mcp.developer.meta.com/wearables
claude mcp list   # expect: wearables ... ✔ Connected
```

Exposes `search_dat_docs` — semantic search over DAT guides, API reference, and code examples.
**Every engineer should run this before writing a line of DAT code.** The toolkit is a moving
developer preview; v0.6 broke existing video streaming code between releases. Guessing at API shapes
from memory is how you lose an hour at 3 a.m.

> **Note:** MCP tools only load at session start. After running the command above, **restart Claude
> Code** or the `search_dat_docs` tool will not be callable.

### 3.2 Repo-native plugin — one command

The SDK repo ships `install-skills.sh`, which installs nine DAT skills (camera-streaming,
session-lifecycle, permissions-registration, mockdevice-testing, debugging, dat-conventions,
getting-started, sample-app-guide, display-access) plus a 1,132-line `AGENTS.md`:

```bash
git clone --depth 1 https://github.com/facebook/meta-wearables-dat-ios.git
cd meta-wearables-dat-ios && ./install-skills.sh claude   # or: codex | cursor | copilot | all
```

Already installed in this repo at `.claude/skills/` with `AGENTS.md` at the root. Two runnable
samples ship too — **`samples/CameraAccess`** is the one to start from; do not scaffold from zero.

### 3.3 Repo-native plugin (reference)

The SDK repos ship pre-configured AI tooling: `.claude-plugin/marketplace.json` for Claude Code,
`.codex-plugin/plugin.json` for Codex, plus `.github/copilot-instructions.md`, `.cursor/rules/*.mdc`,
and `AGENTS.md`. These cover setup, streaming patterns, MockDeviceKit testing, session lifecycle,
permissions, debugging, and sample-app guidance.

Clone the SDK repo locally rather than consuming it only through SPM — you get the tooling for free.

### 3.3 Full API reference

```
https://wearables.developer.meta.com/llms.txt            # index
https://wearables.developer.meta.com/llms.txt?full=true  # complete API surface
```

Meta's recommended layering: **repo plugin for patterns → MCP for live docs → llms.txt for exact
signatures.**

---

## 4. Distribution — release channels instead of TestFlight

The Developer Center provides organizations and release channels for distributing builds to test
users. For a 5-person team this removes a real bottleneck: teammates can run the build on their own
glasses without an App Store review or a TestFlight round trip.

- [ ] Create the org and add all 5 members — **Hour 0**, not hour 6
- [ ] Create a `demo` release channel
- [ ] Push the first build to it as soon as G2 passes, so the freeze build is not the first upload anyone has ever attempted

Publishing to the public is **not** available during developer preview. Internal distribution is,
which is all a hackathon needs.

---

## 5. Simulation — newly adopted, expands parallel work

The plan already used Mock Device Kit. Two more v0.6 features were being left on the table:

**Video streaming simulation via phone camera.** Frames come from the phone instead of the glasses,
through the same code path. Track A can develop and tune `FaceCluster` without ever holding the
glasses.

**Permission and configuration simulation via the Meta AI app.** Permission flows are the classic
source of hour-9 demo failures — a dialog nobody saw during development. Simulate and rehearse them.

Combined effect: **only Track B needs the physical glasses.** A, C, and D are fully unblocked, which
matters when there is one pair between four people.

---

## 6. Newly discovered constraints — fold into the build

**One active session per device.** If the Meta AI app or any other integration holds a session, ours
fails to acquire one. Add this to the pre-demo checklist: force-quit competing apps and confirm no
other session is live before the run.

**Split permission model.** Camera access is granted through the **Meta AI app**; microphone access
through **standard platform dialogs**. Two different flows, two different failure modes — Track B
owns both, and both get rehearsed.

**Registration is a deeplink** into the Meta AI app. Not an in-app flow. It is a visible context
switch the wearer cannot see, so the Narrator must speak through it.

**Module split:** `MWDATCore` (registration, discovery, permissions, telemetry), `MWDATCamera`
(video/photo, frame delivery, resolution), `MWDATDisplay` (Display glasses only — not used).

**`DeviceState` and `ThermalLevel` (v0.7).** We hold an always-on HFP session. Surface thermal state
and warn the wearer audibly before throttling degrades capture. Silent degradation is the failure
mode this product can least afford.

---

## 7. Take these back to Meta

The recommendation to "use the full capabilities" is worth clarifying, since the fullest capability
set is the one that cannot work:

1. **Did you mean Web Apps?** They have no camera or microphone access, so an audio-and-vision
   accessibility product cannot use them. Is mic access on the Web Apps roadmap?
2. **Is there any path to captouch or Neural Band input on Ray-Ban Meta Gen 2**, or through the
   native SDK on any device? It is a materially better interaction model for a blind user than
   speaking commands aloud in public.
3. **What is the status of voice invocation?** Documented as in progress. Third-party wake-word
   support would let us drop our custom keyword spotting entirely.
4. **Can a native DAT session and a Web App coexist** on one device, given the one-session-per-device
   rule? If so, a Display + native hybrid becomes interesting post-hackathon.
5. **Is anonymous face clustering permitted** under the DAT Acceptable Use Policy? We never infer
   identity from a face — clusters stay unlabeled until a name is spoken aloud. Confirming this
   directly with Meta is faster and more reliable than reading the AUP ourselves.

Question 5 is the one to ask first. It is the only one that can force a design change.
