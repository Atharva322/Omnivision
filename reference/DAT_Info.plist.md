# Working DAT Info.plist configuration

Meta's `samples/CameraAccess` does **not** run on a clean setup. Four keys are missing or wrong.
These are the exact fixes that took us from `registerWasSuccessful 0` / no privacy LED / no frames
to a working stream and photo capture. Copy into Omnivision's Info.plist.

| Key | Sample shipped | Correct |
|---|---|---|
| `MWDAT.MetaAppID` | `$(META_APP_ID)` → **empty string** | `0` (documented dev-mode value) |
| `UISupportedExternalAccessoryProtocols` | **absent** | `["com.meta.ar.wearable"]` |
| `UIBackgroundModes` | missing `external-accessory` | add it |
| `LSApplicationQueriesSchemes` | **absent** | `["fb-viewapp"]` (lets SDK detect Meta AI) |

The missing accessory protocol is the root cause: iOS will not open an iAP2 channel to an MFi
accessory unless the app declares the protocol, so `iapd`/`iap2d` never launch. Symptom is
Bluetooth control working (audible click) while the camera never activates.

```xml
<key>LSApplicationQueriesSchemes</key>
<array><string>fb-viewapp</string></array>

<key>UISupportedExternalAccessoryProtocols</key>
<array><string>com.meta.ar.wearable</string></array>

<key>UIBackgroundModes</key>
<array>
  <string>processing</string>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
  <string>external-accessory</string>
</array>

<key>MWDAT</key>
<dict>
  <key>AppLinkURLScheme</key><string>omnivision://</string>
  <key>MetaAppID</key><string>0</string>
  <key>TeamID</key><string>$(DEVELOPMENT_TEAM)</string>
</dict>

<key>NSMicrophoneUsageDescription</key>
<string>Needed to capture conversation audio from your glasses microphone.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Speech is transcribed entirely on this device. Audio never leaves your phone.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Needed to connect to Meta AI Glasses</string>
```

## Verified environment (2026-07-31)

Xcode 26.6 · MetaWearablesDAT **0.8.0** · iOS 26.5.2 on iPhone 16 Pro Max · glasses v126 ·
Meta AI app 283.0.0.28.165 · free personal team signing.

Personal teams **cannot** use `Access Wi-Fi Information` or `Hotspot` — delete both capabilities
or signing fails. They exist for v0.8's WiFi transport, which we do not use.
