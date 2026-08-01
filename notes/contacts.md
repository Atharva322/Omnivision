# Private notes — NOT committed to GitHub

## Meta contact
Myan has a **direct text-message contact at Meta**. Use for fast answers instead of
formal channels or waiting on docs.

Good things to text them:
- **AUP question (open):** is an on-device, *unlabeled* face embedding permitted? Ours carries
  no identity until a name is spoken aloud, never leaves the device, deletable on command.
  If not permitted → flip the `FaceCluster` feature flag off; spoken-name identity is unaffected.
- **Sample bug (found 2026-07-31):** `samples/CameraAccess` does not run on a clean setup.
  Info.plist is missing `UISupportedExternalAccessoryProtocols` (`com.meta.ar.wearable`) and the
  `external-accessory` background mode, and `MetaAppID` resolves to an empty string instead of `"0"`.
  Symptom: `registerWasSuccessful 0`, no privacy LED, no frames. Adding those three fixed it.
- **Roadmap questions:** microphone access for Web Apps? captouch/Neural Band on Gen 2?
  status of third-party voice invocation? does the v0.8 WiFi transport carry the video stream?
