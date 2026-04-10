# Phase 4 — Overlay Assistant Screen

**Status**: plan drafted, not yet started. Starts after Phase 3 (splash UX) ships.

## The key discovery

**Hark already has the overlay infrastructure registered.** The `HarkVoiceInteractionService` + `HarkSessionService` in `AndroidManifest.xml` register Hark as `VoiceInteractionService` + `ROLE_ASSISTANT`. When the assist gesture fires, Android creates a `VoiceInteractionSession` which has its own **system-managed overlay window** via `onCreateContentView()`. This window draws over the current app without needing `SYSTEM_ALERT_WINDOW`.

This is the same mechanism Google Assistant and Gemini use for their compact overlay panel. We don't need `flutter_overlay_window` or any third-party overlay package. The system already provides the window — we just need to put a `FlutterView` in it.

## Architecture: hybrid approach

### Path 1 — VoiceInteractionSession overlay (primary, no extra permission)

The assist gesture (long-press home / swipe from corner) triggers `HarkSessionService` → creates a `VoiceInteractionSession`. Currently, Hark's session just launches the full `MainActivity`. Instead:

1. Override `onCreateContentView()` in `HarkVoiceInteractionSession` to return a compact overlay View.
2. Embed a `FlutterView` (connected to the app's existing `FlutterEngine` via `FlutterEngineGroup` or the singleton engine) inside that View.
3. The overlay renders: mic button + one-line status + results chip. Minimal UI.
4. State bridges to the existing Riverpod pipeline via the same Flutter engine — **no second engine, no IPC, no state sync problem**.
5. `showWindow()` / `hide()` control visibility. The system handles the overlay lifecycle.

**Why this is the right primary path:**
- Zero new permissions — `VoiceInteractionSession` window is system-managed, not `SYSTEM_ALERT_WINDOW`.
- Single Flutter engine — Riverpod state stays intact, ChatNotifier + resolver + dispatcher all work as-is.
- Android-blessed pattern — this is literally what `ROLE_ASSISTANT` + `VoiceInteractionService` exist for.
- Same pattern Google/Gemini uses for compact overlay.

**What we need to change in the existing Kotlin code:**
- `HarkSessionService` currently creates a session that delegates to `MainActivity`. Replace with a custom `HarkVoiceInteractionSession` that returns a compact overlay via `onCreateContentView()`.
- The `FlutterView` in the overlay connects to the same `FlutterEngine` that powers `MainActivity`.
- The overlay's Dart code is the same app — just a different widget tree rendered in a different window. Could be a dedicated `OverlayWidget` route or a conditional render based on "am I in overlay mode?".

### Path 2 — Floating mic bubble (secondary, needs SYSTEM_ALERT_WINDOW)

For "always available" access beyond the assist gesture — a small floating mic button that sits on top of any app, like Facebook Messenger's chat heads.

1. Native Kotlin foreground `Service` with `WindowManager.addView()` using `TYPE_APPLICATION_OVERLAY`.
2. The bubble is a simple native View: circular mic icon, draggable, tap to activate.
3. On tap: either (a) triggers the `VoiceInteractionSession` flow from Path 1, or (b) opens a minimal native chat panel.
4. State bridges to the main Flutter engine via `MethodChannel` / `EventChannel`.
5. Requires `SYSTEM_ALERT_WINDOW` permission + a foreground service with notification.

**Why native Kotlin, not flutter_overlay_window:**
- `flutter_overlay_window` creates a **second FlutterEngine** in a separate Dart isolate. That means Riverpod state can't be shared — you'd need `shareData()` IPC between two engines for every mic press, STT chunk, resolver result, and dispatch outcome. Clunky and fragile.
- Native Kotlin bubble is <200 lines, fully under our control, single Flutter engine, simple MethodChannel bridge.
- `flutter_overlay_window` has ~145 GitHub stars and one maintainer — bus-factor-1 for a core UX feature.
- `system_alert_window` package can't render Flutter widgets — dealbreaker for any UI beyond a simple bubble.

### Permission model

| Trigger | Overlay mechanism | Permission needed |
|---|---|---|
| Assist gesture (long-press home, corner swipe) | `VoiceInteractionSession` window | **None** (system-managed) |
| Floating mic bubble always visible | `WindowManager.addView()` + foreground Service | `SYSTEM_ALERT_WINDOW` + `FOREGROUND_SERVICE` |

**Recommendation**: ship Path 1 first. It covers the most common invocation (assist gesture) with zero new permissions. Path 2 (floating bubble) is a follow-up that adds always-on access for users who want it and are willing to grant the overlay permission.

## Implementation plan

### Slice 4.1 — VoiceInteractionSession compact overlay (L effort)

This is the core slice. Replace the current "launch full MainActivity" session with a compact overlay panel.

**Android-side changes:**
- `android/app/src/main/kotlin/com/oacp/hark/HarkVoiceInteractionSession.kt` (NEW) — custom session class. Overrides:
  - `onCreateContentView()` → returns a `FrameLayout` hosting a `FlutterView`.
  - `onShow(args, showFlags)` → starts listening via the Flutter engine.
  - `onHide()` → stops listening, clears state.
- `HarkSessionService.kt` (MODIFY) — return the new `HarkVoiceInteractionSession` from `onNewSession()`.
- `AndroidManifest.xml` — no changes (VIS + session service already registered).

**Flutter-side changes:**
- `lib/screens/overlay_screen.dart` (NEW) — compact overlay widget: mic button + status line + result chip. Consumes the same `ChatNotifier` state.
- `hark_router.dart` (MODIFY) — add `/overlay` route for the overlay screen. The session's `FlutterView` renders this route.
- `lib/state/chat_notifier.dart` (MINOR) — add an "overlay mode" flag so TTS and dispatch behavior can adapt (e.g., shorter TTS confirmations in overlay mode).

**Key technical question**: can a `FlutterView` in the `VoiceInteractionSession` window connect to the SAME `FlutterEngine` that `MainActivity` uses? If yes (via `FlutterEngineGroup` or a cached engine), single-engine architecture works. If not, we fall back to a lightweight second engine with MethodChannel IPC.

**Investigation needed before coding**: read Flutter's `FlutterEngineGroup` docs and test whether a `FlutterView` in a non-Activity context (a Service's window) can attach to an existing engine. This is the single biggest technical risk in Phase 4.

### Slice 4.2 — Overlay UX polish (M effort)

After 4.1 works end-to-end:
- Dismiss gestures: swipe down, tap outside, timeout after 10s of inactivity.
- Result display: show a compact card with the action result (like the Breezy Weather data).
- Continuous mode: after dispatch, auto-listen for the next command (same as current continuous mode).
- Transition to full app: a "See more" button that opens `MainActivity` and transfers context.

### Slice 4.3 — Floating mic bubble (M effort, separate from assist overlay)

**Only after 4.1 and 4.2 ship.** Adds the always-on floating bubble for users who want overlay access without the assist gesture.

**Android-side changes:**
- `android/app/src/main/kotlin/com/oacp/hark/OverlayBubbleService.kt` (NEW) — foreground Service + WindowManager.addView. Draggable mic button.
- `AndroidManifest.xml` — add `SYSTEM_ALERT_WINDOW` permission + `<service>` for `OverlayBubbleService` with `FOREGROUND_SERVICE` type.

**Flutter-side changes:**
- Settings toggle: "Show floating mic button" (default off, requires SYSTEM_ALERT_WINDOW grant).
- Permission request flow: explain what the permission does, send user to Settings, detect grant on return.
- On bubble tap: trigger the VoiceInteractionSession from 4.1, or fall back to launching MainActivity.

### Slice 4.4 — Assist gesture redirect (S effort)

Currently the assist gesture opens the full `MainActivity`. After 4.1:
- If overlay feature is enabled: the gesture opens the compact overlay (4.1 path).
- If overlay feature is disabled: the gesture opens `MainActivity` as before.
- User setting: "Assist gesture opens: compact overlay / full app" (default: compact overlay once 4.1 ships).

## Lifecycle edge cases

| Scenario | Behavior |
|---|---|
| Screen off while overlay visible | Session window pauses; resumes on screen on |
| User opens MainActivity while overlay visible | Auto-dismiss overlay, transfer context to main activity |
| Device rotation | Session window reconfigures; overlay layout adapts or stays portrait-locked |
| Main Activity killed by OS | Session is hosted by the Service, survives Activity death |
| Incoming call during overlay | Android system manages window z-order; call UI draws on top |

## Research sources

- `VoiceInteractionSession.onCreateContentView()` — Android API reference
- Google Gemini compact overlay — uses VoiceInteractionSession, same pattern
- `flutter_overlay_window` (pub.dev, 145 stars) — uses second FlutterEngine, rejected for state-sharing complexity
- `system_alert_window` (pub.dev, 121 stars) — can't render Flutter widgets, rejected
- Flutter `FlutterEngineGroup` docs — multi-engine with shared memory, ~180KB per additional engine
- Prior art: no known open-source Flutter app combines floating overlay + voice + chat

## Critical files

- `android/app/src/main/kotlin/com/oacp/hark/HarkSessionService.kt` — currently delegates to MainActivity; to be modified
- `android/app/src/main/kotlin/com/oacp/hark/HarkVoiceInteractionSession.kt` — NEW, core of 4.1
- `android/app/src/main/AndroidManifest.xml` — 4.3 adds SYSTEM_ALERT_WINDOW + bubble service
- `lib/screens/overlay_screen.dart` — NEW, compact overlay Flutter UI
- `hark_router.dart` — add `/overlay` route
- `lib/state/chat_notifier.dart` — overlay mode flag

## Open questions (need investigation before Slice 4.1 starts)

1. **Can a FlutterView in VoiceInteractionSession connect to the same FlutterEngine?** This is the single biggest technical risk. If yes: single-engine, Riverpod works. If no: need a lightweight second engine with MethodChannel IPC — more complex but still better than flutter_overlay_window's approach.

2. **Does the VoiceInteractionSession window support transparent background?** If not, the overlay will have an opaque card background (fine, but less "floaty").

3. **What happens if the user has not set Hark as the default assistant?** The assist gesture goes to Google Assistant instead. Need to detect this and show an onboarding prompt ("Set Hark as your default assistant to use the overlay").

4. **What's the maximum size of the VoiceInteractionSession window?** Can it be a full-width bottom sheet? Or is it constrained to a specific size?
