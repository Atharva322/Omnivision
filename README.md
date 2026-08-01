# Omnivision

Omnivision is an audio-first social-memory assistant for blind and low-vision users of Ray-Ban Meta
glasses. The glasses provide microphone, camera, and speaker I/O; the paired iPhone performs local
speech processing, evidence-based identity resolution, persistence, and narration.

## Portable Swift package

The current branch packages the hardware-independent Track A and Track C implementation as
`AccessLensTrackC`:

```text
Sources/AccessLensTrackC/
├── Core/          models, protocols, EventLog, SessionMachine, social-memory coordinator
├── Identity/      extraction, evidence, resolver, PersonStore, FaceCluster
├── Audio/         wake-word command grammar
├── Evaluation/    fixture runner
├── Resources/     name denylist
└── Text/          tokenization and name formatting
```

Run the portable tests on a Mac with Swift installed:

```bash
swift test
swift run trackc-eval Fixtures
```

On Linux with Docker:

```bash
scripts/swift-linux.sh test
scripts/swift-linux.sh run trackc-eval Fixtures
```

## Documentation

- [`docs/TRACK_A.md`](docs/TRACK_A.md) — Track A implementation audit, remaining work, correction and
  deletion flows, and exact Mac/Xcode verification
- [`docs/TRACK_C.md`](docs/TRACK_C.md) — extraction algorithms and hardware calibration handoff
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — system behavior and evidence rules
- [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) — complete hackathon build plan
