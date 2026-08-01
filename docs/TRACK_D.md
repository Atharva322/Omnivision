# Track D — HCI narration, consent, validation, and demo

This is the Track D source of truth. The audio interface is implemented inside the existing
`AccessLensTrackC` package so its safety rules can be tested without glasses. Apple builds use
`AVSpeechSynthesizer` and `AVAudioPlayer`; tests inject silent or recording outputs.

## Implementation status

| Responsibility | Implementation | Status |
|---|---|---|
| Priority TTS queue and `repeatLast()` | `HCI/Narrator.swift` | implemented |
| Never speak over the other person | `SpeechActivityMonitor` + narrator queue | implemented, tested with a controlled silence gate |
| Five distinct earcons | `HCI/EarconLibrary.swift` | implemented as runtime-generated tones |
| Approved spoken strings and hard caps | `HCI/NarrationCopy.swift` | implemented, tested |
| Assert / hedge separation | `.known` and `.likely` mappings | implemented, regression-tested |
| Consent script and audible recording tone | `ConsentDecisionParser` + `consentResponse` | implemented |
| One-second pronunciation clip | `PronunciationClipRecorder` | implemented for Apple platforms |
| Replay pronunciation instead of TTS | `.pronunciation` cue with safe fallback | implemented, tested |
| Human time | `HumanTimeFormatter` | implemented, tested |
| 20-trial screen-free validation | run sheet below | requires people, glasses, and a noisy room |
| Two-minute live demo and backup video | scripts below | written; recording still requires the team |

## Non-negotiable integration order

1. Create one `SpeechActivityMonitor` and pass it to `Narrator`.
2. Feed every VAD-positive other-channel buffer to `narrator.noteOtherSpeech(at:)`, and every
   finalized Track B utterance to `narrator.observe(_:)`. Live VAD prevents a queued line from
   starting mid-turn; finalized utterances extend the tailoff. Wearer speech does neither.
3. Run consent **before** `SocialMemoryCoordinator.beginCapture`. A decline or unclear answer may
   not create a person, transcript, face association, or summary.
4. Pass every returned `SocialMemoryAction` to `narrator.perform(_:)`.
5. On a glasses disconnect, immediately perform `NarrationCopy.glassesDisconnected`. It is
   critical, cancels a normal silence hold, plays the urgent earcon, and speaks the failure.
6. If `AudioSpining.isGlassesRoute` is false, perform `NarrationCopy.usingPhoneMicrophone`.

Normal and discreet speech call `holdUntilSilence()` immediately before playback. Critical
capability failures are the only exception because a blind wearer cannot see that the system has
stopped sensing.

## Consent and pronunciation flow

Approved first-meeting exchange:

```text
SYSTEM  “May I remember your name and this conversation? Say yes to continue.”
PERSON  “Yes.”
SYSTEM  “Please say your name after the tone.”
SYSTEM  ♪ captureOn
PERSON  “Priya.”                         [at most one second is stored]
SYSTEM  ♪ captureOff
```

`ConsentPronunciationFlow` implements this flow over Track B's existing PCM stream. It never
installs a second audio tap. The returned path is attached after a person is created with
`PersonStore.setNamePronunciationPath(_:for:)`. A decline says “Okay. Nothing was saved.” An
ambiguous answer asks for yes or no and remains outside capture.

The clip owner restricts deletion to its own Application Support directory. The complete “forget
them” adapter must delete this clip and the Track A face artifacts before deleting the person record.

## Approved spoken copy

These strings are product behavior, not placeholder prose. Keep the assertion verbs intact.

| State | Spoken output |
|---|---|
| New person, asserted | “Priya. Saved.” |
| Face-only or weak evidence | “This **might be** Priya. Say Lumen, that's wrong, if not.” |
| Conflicting names | “Did you meet Priya or Marcus?” |
| No name | “I didn't catch a name.” |
| Correction | “Understood. I don't know who this is.” |
| Acquaintance | “Priya. Stripe. Three weeks ago. Latency work.” |
| Familiar | “Marcus. Tuesday. The budget.” |
| Inner | no name or full card; optional pending note only |
| Wrong microphone | “Using the phone microphone.” |
| Disconnect | urgent earcon + “Glasses disconnected.” |

Dynamic text is collapsed to one fragment, sentence punctuation is removed from model/store
details, and every TTS line is capped at 110 characters.

## Screen-free 20-trial run sheet

Run with the phone face-down. A second teammate logs the `EventLog` and actual spoken output. Do
not mark a hardware trial passed from unit-test results.

| # | Scenario | Pass condition | Result |
|---|---|---|---|
| 1–3 | Wearer echoes a new name | correct bind; saved earcon; no mid-conversation TTS | ⬜ |
| 4–5 | “Lumen, this is X” | explicit bind succeeds | ⬜ |
| 6–7 | Other person self-introduces; wearer silent | assert only above calibrated threshold; otherwise hedge | ⬜ |
| 8–9 | Re-encounter with spoken name | asserted, tier-appropriate recall | ⬜ |
| 10–11 | Face match only | exact “might be” hedge; never an assertion | ⬜ |
| 12 | Wearer rejects hedge | correction copy; rejected pair not suggested again | ⬜ |
| 13–14 | Inner-tier encounter | chime or pending note; no name, org, or full card | ⬜ |
| 15 | Noisy room; name unintelligible | “I didn't catch a name.” | ⬜ |
| 16 | Person declines consent | no persisted person, transcript, face link, or clip | ⬜ |
| 17 | Other person talks while output is queued | output waits through the complete quiet period | ⬜ |
| 18 | Glasses disconnect mid-capture | immediate urgent earcon and critical spoken warning | ⬜ |
| 19 | Pending note on re-encounter | right note for the right person; short copy | ⬜ |
| 20 | “Lumen, pause” mid-conversation | instant halt; no confirmation prompt | ⬜ |

Pass condition: **zero false assertions** and **zero trial-17 interruptions**. Trials 10, 11, and 15
pass by hedging or declining to name. Record the room, distance, route, software commit, expected
line, actual line, and evidence disposition for every trial.

## Two-minute live demo

**0:00–0:15 — problem.** “Remembering names is visual and socially time-sensitive. A blind wearer
cannot check a screen before greeting someone, and a wrong confident name is worse than no name.”

**0:15–0:30 — trust rule.** Show the judge mirror. “Omnivision only asserts a name from spoken-name
evidence. A face match alone is always phrased as a possibility.”

**0:30–1:05 — first meeting.** Volunteer grants consent and says their name after the tone. Wearer
says “Lumen, remember this,” converses, naturally echoes the name, and ends with “Lumen, stop.” The
system stays silent during the conversation, then says “Priya. Saved.” Point to E1 wearer evidence.

**1:05–1:35 — re-encounter hedge.** Return with face-only evidence. The system says “This might be
Priya,” never “This is Priya.” Reject it once with “Lumen, that's wrong” and show that the rejected
pair is not suggested again.

**1:35–1:50 — failure honesty.** Simulate disconnect. The urgent earcon and warning interrupt the
normal silence hold. Explain that otherwise silence would falsely imply the room was empty.

**1:50–2:00 — close.** “The product claim is not perfect recognition. It is useful memory with zero
false assertions, explicit consent, and an audio interface that knows when to stay quiet.”

## Backup video shot list

Record one continuous phone plus judge-mirror shot before final rehearsal:

1. Slate the commit hash, glasses route, room, and date.
2. Capture the consent and first-meeting flow with the other speaker visible.
3. Keep a real-time clock in frame to prove the narrator stays silent during conversation.
4. Show the EventLog evidence and the deferred “Saved” line.
5. Cut to face-only re-encounter and capture the exact hedge.
6. Reject the hedge and show the negative association.
7. Trigger a disconnect and capture the urgent earcon.
8. End on the 20-trial scorecard; do not claim trials that were not run.

Keep an exported local copy on two teammates' phones. The live demo should not depend on network
access, GitHub, or a fresh model response.
