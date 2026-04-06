# Libre Camera Demo

This document describes the Libre Camera demo integration for OACP and Hark,
and how to test it on Android.

## What was added

Libre Camera was extended to expose camera actions through OACP:

- `take_photo`
- `take_photo_front_camera`
- `take_photo_rear_camera`
- `start_video_recording`
- `start_video_recording_front_camera`
- `start_video_recording_rear_camera`

These actions are declared in the app's [`oacp.json`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/assets/oacp.json).

## Why activity transport is used

Camera actions require the target app to be in the foreground before execution.
Using a background broadcast and then trying to bring the app to the foreground
from inside the target app is unreliable on modern Android versions.

For that reason, Libre Camera declares these actions with:

- `requiresForeground: true`
- `invoke.android.type: "activity"`

That lets Hark perform a single foreground handoff directly into Libre Camera.

## End-to-end flow

1. Hark discovers Libre Camera through the exported OACP metadata provider.
2. Hark reads `oacp.json` and `OACP.md`.
3. The local model resolves the spoken command to a Libre Camera action.
4. Hark checks the action transport:
   - `broadcast` for background-safe actions
   - `activity` for foreground-required actions
5. For Libre Camera photo/video actions, Hark launches Libre Camera with the
   action and parameters in the same Android activity intent.
6. Libre Camera receives that action in `MainActivity`, forwards it into
   Flutter, waits until the camera UI is ready, and then executes the command.

## Key files

OACP / Hark side:

- [`protocol/SPEC.md`](https://github.com/OpenAppCapabilityProtocol/oacp/blob/main/protocol/SPEC.md)
- [`protocol/oacp.schema.json`](https://github.com/OpenAppCapabilityProtocol/oacp/blob/main/protocol/oacp.schema.json)
- [`lib/services/capability_registry.dart`](../lib/services/capability_registry.dart)
- [`lib/services/intent_dispatcher.dart`](../lib/services/intent_dispatcher.dart)

Libre Camera side:

- [`assets/oacp.json`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/assets/oacp.json)
- [`assets/OACP.md`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/assets/OACP.md)
- [`AndroidManifest.xml`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/android/app/src/main/AndroidManifest.xml)
- [`MainActivity.kt`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/android/app/src/main/kotlin/com/iakmds/librecamera/MainActivity.kt)
- [`OacpMetadataProvider.kt`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/android/app/src/main/kotlin/com/iakmds/librecamera/OacpMetadataProvider.kt)
- [`oacp_command_service.dart`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/lib/src/oacp/oacp_command_service.dart)
- [`camera_page.dart`](https://github.com/OpenAppCapabilityProtocol/librecamera/blob/main/lib/src/pages/camera_page.dart)

## Rebuild and install

From the Libre Camera repo:

```bash
cd librecamera  # clone from https://github.com/OpenAppCapabilityProtocol/librecamera
flutter clean
flutter pub get
flutter install -d <device-id>
```

To find the device id:

```bash
flutter devices
```

## Test commands

After rebuilding Libre Camera and refreshing Hark's app discovery, test these:

- "Take photo"
- "Take photo with front camera"
- "Take photo with rear camera in 4 seconds"
- "Start video recording"
- "Start video recording with front camera"
- "Start video recording with rear camera"

## Expected behavior

- Hark resolves the command to the matching Libre Camera action.
- Libre Camera is brought to the foreground automatically for these actions.
- A photo action starts the countdown and captures.
- A video action opens Libre Camera and starts recording.

## Debugging notes

- If Hark resolves the action correctly but Libre Camera does not open, verify
  that the installed Libre Camera build includes the updated activity
  intent-filters.
- If Libre Camera opens but no action runs, verify that `MainActivity` forwards
  the launch intent into Flutter and that the app was rebuilt after the changes.
- If Hark does not pick the Libre Camera action, refresh OACP discovery in Hark
  and confirm the installed app exposes the latest manifest through the OACP
  metadata provider.
