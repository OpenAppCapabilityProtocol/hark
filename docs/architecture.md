# Hark Architecture

Hark is the reference OACP voice assistant. It discovers app capabilities at
runtime, resolves voice commands to actions using a two-tier on-device pipeline,
dispatches Android intents, and handles async results -- all without the user
leaving the assistant.

---

## Discovery

`OacpDiscoveryHandler.kt` scans for exported `.oacp` ContentProviders via
`PackageManager`. For each provider it reads two paths:

- `/manifest` -- the machine-readable `oacp.json` capability file.
- `/context` -- the LLM-readable `OACP.md` semantic context file.

`OACP.md` is validated for presence but **not currently consumed by the LLM**.
It is reserved for future BYOK (bring-your-own-key) cloud models that have
larger context windows.

## Capability Registry

All discovered manifests are parsed into `AssistantAction` objects. Each action
carries:

- `description`, `aliases`, `examples`, `keywords`
- `disambiguationHints` for overlapping capabilities
- `parameters` with types, constraints, and entity snapshots

The registry is the single source of truth for what the device can do.

## Two-Tier Resolution

Resolution runs in stages, with deterministic shortcuts at every level:

### Stage 0 -- Deterministic Heuristic

Keyword, alias, and example matching runs against the raw transcript. If a
clear winner emerges (score >= 8, gap >= 3 over the runner-up), that action is
selected directly -- no model call needed.

### Tier 1 -- Lean Tool Selection (~500 tokens)

The top 6 candidate actions are sent to **FunctionGemma 270M** as minimal tool
definitions. The model picks one tool.

### Tier 2 -- Parameter Extraction (~400 tokens)

Only the selected tool's description and parameter definitions are sent to the
model. It extracts parameter values from the transcript.

### Deterministic Fallback

At every stage, regex-based extraction handles common patterns: durations,
alarm times, enum values, and entity snapshot lookups.

## Intent Dispatch

Actions are dispatched as Android intents via `android_intent_plus`:

- **Broadcast** for background-safe actions (e.g., set alarm, toggle flashlight).
- **Activity launch** for foreground-required actions (e.g., open a playlist).

Every dispatch includes `org.oacp.extra.REQUEST_ID` for result correlation.

## Async Result Handling

`OacpResultReceiver.kt` (native `BroadcastReceiver`) listens for
`org.oacp.ACTION_RESULT` broadcasts from target apps. Results flow back through:

    OacpResultReceiver (Kotlin)
      -> EventChannel (platform channel)
        -> OacpResultService (Dart)
          -> AssistantScreen (chat bubble + TTS)

The user sees the result in the conversation and hears it spoken aloud, all
without leaving Hark.

## STT / TTS

- **STT**: `speech_to_text` package, backed by Android-native `SpeechRecognizer`
  (cloud recognition by default). Tap-to-cancel and a 10-second silence timeout.
- **TTS**: `flutter_tts` for spoken confirmations and result readback.

## Context Budget

FunctionGemma 270M has a total usable context of roughly **2K tokens**.

| Stage              | Budget     |
|--------------------|------------|
| Tier 1 (tool pick) | ~500 tokens |
| Tier 2 (params)    | ~400 tokens |
| OACP.md (reserved) | 300-800 tokens |

`OACP.md` content is deliberately excluded from the on-device pipeline to stay
within budget. When BYOK cloud models are supported, their larger context
windows will accommodate the extra semantic context.

## Android Assistant Integration

Hark registers as a system-level digital assistant via Android's
`VoiceInteractionService` framework. When the user long-presses Home (or uses
the device's assistant gesture), Android launches Hark and auto-starts listening.

### Required components

Android validates all of these before allowing an app to be selected as the
default assistant:

| Component | File | Purpose |
|-----------|------|---------|
| `HarkVoiceInteractionService` | Kotlin | Background service Android binds to. Must declare `BIND_VOICE_INTERACTION` permission. |
| `HarkSessionService` | Kotlin | Creates `HarkSession` instances when assistant is invoked. |
| `HarkSession` | Kotlin | `onShow()` launches MainActivity with `EXTRA_LAUNCHED_FROM_ASSIST`. |
| `HarkRecognitionService` | Kotlin | Stub `RecognitionService` — required by Android to qualify as assistant. Actual STT handled by Flutter's `speech_to_text`. |
| `voice_interaction_service.xml` | `res/xml/` | Metadata referencing sessionService, recognitionService, and `supportsAssist="true"`. |
| `ACTION_ASSIST` intent filter | Manifest | On MainActivity — required for assistant role qualification. |
| `ACTION_VOICE_ASSIST` intent filter | Manifest | On MainActivity — used by some devices for voice-specific activation. |

### Role management

On Android 10+ (API 29), Hark uses `RoleManager` to request `ROLE_ASSISTANT`
on first launch. If the role isn't held, a system dialog prompts the user.
A banner in the Flutter UI also links to `android.settings.VOICE_INPUT_SETTINGS`
for manual configuration.

### Continuous listening

When launched via the assistant gesture, Hark enters continuous listening mode:
the mic auto-restarts after each command completes and TTS finishes speaking.
Tapping the mic button exits continuous mode.

### How other assistants do it (reverse-engineered)

| | Claude | ChatGPT | Google Assistant |
|---|---|---|---|
| ASSIST Activity | `AssistantOverlayActivity` (dedicated overlay) | `AssistantProxyActivity` → `AssistantActivity` | System-integrated |
| VoiceInteractionService | `ClaudeVoiceInteractionService` | `AssistantVoiceInteractionService` | `GsaVoiceInteractionService` |
| RecognitionService | `ClaudeRecognitionService` | None | `GoogleRecognitionService` |
| VOICE_ASSIST | Yes | No | N/A |

Claude and ChatGPT both use a dedicated overlay/proxy Activity (separate from
their main chat UI) to show a lightweight assistant panel on top of the current
app. Hark currently launches its full MainActivity — a future improvement would
be a dedicated lightweight overlay Activity for a more assistant-like experience.
