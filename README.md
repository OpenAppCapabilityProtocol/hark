# Hark

**An open-source voice assistant that discovers and controls Android apps using on-device AI.**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Protocol](https://img.shields.io/badge/OACP-v0.3--preview-green)](https://github.com/OpenAppCapabilityProtocol/oacp)
[![Flutter](https://img.shields.io/badge/Flutter-3.11+-02569B.svg)](https://flutter.dev)

---

> The name "Hark" means *"to listen"*.

Hark is the reference voice assistant for [OACP](https://github.com/OpenAppCapabilityProtocol/oacp) (Open App Capability Protocol). It discovers what your installed apps can do and lets you control them by voice, entirely on-device, no cloud, no account, no data collection. When triggered by the assistant gesture, a lightweight overlay panel appears instantly over your current app, so you never lose context.

```
"Hey Hark, what's the weather?"
    -> discovers Breezy Weather's OACP capabilities
    -> dispatches broadcast intent
    -> app returns data in background
    -> Hark speaks: "Currently 22 degrees, partly cloudy"
```

---

## How It Works

1. **Listen** - On-device speech-to-text captures your voice command
2. **Discover** - Scans installed apps for OACP capability manifests via Android ContentProvider
3. **Resolve** - Two-stage on-device AI pipeline matches your command to the right app action and extracts parameters
4. **Dispatch** - Fires an Android Intent to the target app (broadcast for background, activity for foreground)
5. **Respond** - Receives async results from the app, shows them in chat, and speaks them aloud

The user never leaves their current app. The overlay appears instantly on top, apps do the work in the background, and results stream back as chat bubbles.

## On-Device AI Pipeline

Hark does not use cloud AI. Everything runs locally on your phone:

| Stage | Model | What it does |
|-------|-------|-------------|
| Intent selection | [EmbeddingGemma](https://ai.google.dev/gemma/docs/core/embedding_gemma) 308M | Semantic similarity ranking against all discovered capabilities. Confidence-gated at 0.35. |
| Slot filling | [Qwen3 0.5B](https://huggingface.co/Qwen/Qwen3-0.6B) | Extracts parameters (numbers, names, durations) from the matched utterance |

This two-stage approach follows what production voice assistants actually use: **encoder models for classification, generative models for extraction** - not a single LLM for everything.

## OACP-Enabled Apps

Hark works with any app that implements OACP. These are tested and working today:

| App | What you can do |
|-----|----------------|
| [Breezy Weather](https://github.com/OpenAppCapabilityProtocol/breezy-weather) | "What's the weather?" - async result spoken back |
| [Binary Eye](https://github.com/OpenAppCapabilityProtocol/BinaryEye) | "Open the QR scanner" / "Create QR code for hello world" |
| [Voice Recorder](https://github.com/OpenAppCapabilityProtocol/Voice-Recorder) | "Start audio recording" |
| [Libre Camera](https://github.com/OpenAppCapabilityProtocol/librecamera) | "Take a selfie in 5 seconds" - camera opens in selfie mode |
| [Wikipedia](https://github.com/OpenAppCapabilityProtocol/apps-android-wikipedia) | "Search Wikipedia for Flutter" |
| [ArchiveTune](https://github.com/OpenAppCapabilityProtocol/ArchiveTune) | "Play Lonely by Akon" - music playback by voice |

Each is a fork showing exactly what was added to support OACP. Check the diff against upstream to see how simple the integration is.

Want to add OACP to your own app? See the [OACP Getting Started Guide](https://github.com/OpenAppCapabilityProtocol/oacp/blob/main/docs/getting-started.md).

## Android Assistant Integration

Hark can register as your device's default voice assistant:

- **Long-press Home** or assistant gesture launches a dedicated lightweight overlay panel over your current app with instant startup, chat bubbles, and auto-mic
- The overlay runs in its own Flutter engine (via `FlutterEngineGroup`), keeping startup under 200ms
- Tap **"Open full app"** to continue the conversation in the full chat screen
- Implements Android's `VoiceInteractionService` framework
- Continuous listening mode: mic auto-restarts after each command
- Uses `RoleManager` on Android 10+ to request ROLE_ASSISTANT

## Wake Word

Hark supports hands-free activation with the wake phrase **"Hey Hark"**. Wake word detection runs entirely on-device using [openWakeWord](https://github.com/dscripka/openWakeWord) (Apache 2.0) with ONNX Runtime, so no audio ever leaves your phone.

- Works on any Android device, no special hardware required
- Custom-trained wake word model (201KB ONNX), lightweight enough to run continuously
- **Background foreground service** with a persistent "Listening for Hey Hark" notification so detection keeps running when the app is backgrounded or swiped from Recents
- **Launches the overlay from any screen** via the system `VoiceInteractionService.showSession()` path — say "Hey Hark" anywhere and the assistant panel appears instantly
- Notification has a **Stop** action to release the mic without relaunching the app
- Mutually exclusive with speech-to-text: the wake word engine pauses while STT is active, then resumes after
- Toggle on/off from the in-app **Settings** screen — the preference persists across cold starts

## Settings

Hark has an in-app Settings screen (gear icon in the chat header) with:

- **Permissions** — live status for microphone, notifications, and the default assistant role, each with a one-tap fix button
- **Wake word** — On/Off toggle with persistent preference, plus model and threshold info
- **Models** — read-only rows for EmbeddingGemma 308M and Qwen3 0.6B
- **About** — app version, OACP protocol version, GitHub link

## Getting Started

### Prerequisites

- Flutter SDK (stable channel, >= 3.11)
- Android device (physical device strongly recommended - emulators lack microphone, GPU, and some intent features)
- ~500MB free storage for on-device AI models

### Build and run

```bash
git clone https://github.com/OpenAppCapabilityProtocol/hark.git
cd hark
flutter pub get
flutter run
```

### First launch

1. Grant microphone permission when prompted
2. Download the on-device models from the Local Models screen (EmbeddingGemma + Qwen3)
3. Install any OACP-enabled app (see list above)
4. Tap the mic and try a voice command

### Set as default assistant (optional)

Hark will prompt you to set it as the default assistant on first launch. You can also do this manually:

**Settings > Apps > Default apps > Digital assistant app > Hark**

Once set, long-pressing the Home button launches Hark directly.

## Project Structure

```
lib/
├── main.dart                          # Entry point
├── overlay_main.dart                  # Overlay engine entrypoint (thin UI shell)
├── models/
│   ├── agent_manifest.dart            # OACP manifest JSON parsing
│   ├── assistant_action.dart          # Action definitions and metadata
│   ├── command_resolution.dart        # Resolution result types
│   ├── discovered_app.dart            # Discovered app data model
│   ├── discovered_app_status.dart     # Discovery state enum
│   └── resolved_action.dart           # Intent resolution output
├── screens/
│   ├── chat_screen.dart               # Main chat UI with voice I/O
│   ├── available_actions_screen.dart   # Browse discovered capabilities
│   ├── overlay_screen.dart            # Compact overlay panel with chat bubbles
│   └── splash_screen.dart             # Startup splash
├── services/
│   ├── app_discovery_service.dart      # Pigeon bridge to native discovery
│   ├── capability_help_service.dart    # "What can you do?" query handler
│   ├── capability_registry.dart        # Aggregates capabilities from all apps
│   ├── command_resolver.dart           # Abstract resolver interface
│   ├── inference_logger.dart           # JSONL logging for debugging
│   ├── intent_dispatcher.dart          # Android Intent dispatch
│   ├── logging_command_resolver.dart   # Logging decorator for resolver
│   ├── nlu_command_resolver.dart       # Embedding-based intent ranking
│   ├── oacp_result_service.dart        # HarkResultFlutterApi callback handler
│   ├── overlay_bridge_service.dart     # State relay between main and overlay engines
│   ├── stt_service.dart                # Speech-to-text
│   └── tts_service.dart                # Text-to-speech
└── state/
    ├── chat_notifier.dart              # Chat message list state
    ├── chat_state.dart                 # Chat state model
    ├── embedding_notifier.dart         # On-device embedding inference
    ├── slot_filling_notifier.dart      # Parameter extraction via Qwen3
    ├── init_notifier.dart              # Startup sequencing
    ├── services_providers.dart         # Riverpod service providers
    ├── registry_provider.dart          # Capability registry provider
    ├── resolver_provider.dart          # Command resolver provider
    └── app_icon_provider.dart          # App icon loading provider

android/app/src/main/kotlin/com/oacp/hark/
├── MainActivity.kt                  # Main Flutter activity + HarkMainApi
├── OverlayActivity.kt               # Translucent overlay, relays between engines
├── HarkApplication.kt               # FlutterEngineGroup, engine caching
├── HarkVoiceInteractionService.kt   # System assistant service
├── HarkSessionService.kt            # Voice interaction session factory
├── HarkSession.kt                   # Launches OverlayActivity on assist gesture
└── HarkRecognitionService.kt        # Recognition service stub

packages/hark_platform/
├── pigeons/
│   └── messages.dart                  # Pigeon schema (host + Flutter APIs)
├── lib/
│   └── hark_platform.dart             # Public API for platform communication
└── android/.../
    └── HarkPlatformPlugin.kt          # Plugin implementation (discovery, dispatch, models)
```

## Documentation

- [Architecture](docs/architecture.md) - How Hark works: discovery, resolution, dispatch, async results
- [NLU Architecture](docs/nlu-architecture.md) - Design rationale for the two-stage AI pipeline
- [On-Device LLM Research](docs/on-device-llm-research.md) - Model evaluation and selection decisions
- [Demo Walkthrough](docs/demo-walkthrough.md) - Step-by-step Libre Camera integration demo
- [Tool-Calling Runtime](docs/tool-calling-runtime.md) - Dynamic tool generation from OACP capabilities

## OACP Protocol

Hark is one implementation of OACP. The protocol is independent - any assistant can consume it.

| | |
|---|---|
| **Protocol spec** | [OpenAppCapabilityProtocol/oacp](https://github.com/OpenAppCapabilityProtocol/oacp) |
| **Android SDK** | [OpenAppCapabilityProtocol/oacp-android-sdk](https://github.com/OpenAppCapabilityProtocol/oacp-android-sdk) |
| **Organization** | [github.com/OpenAppCapabilityProtocol](https://github.com/OpenAppCapabilityProtocol) |

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full plan. Key priorities:

- **Action chips and disambiguation** - Tappable chips for capability help, disambiguation when top scores are close
- **Wake word polish** - Sensitivity slider, privacy indicator, battery measurement, barge-in research
- **Better STT** - Evaluate whisper.cpp / sherpa-onnx for fully on-device speech recognition
- **Release packaging** - Proper signing, GitHub Releases, F-Droid submission

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
