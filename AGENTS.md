# AGENTS.md, Hark Voice Assistant

This file is the authoritative context document for any AI agent working in this repository. Read it before making changes.

---

## What Is Hark

Hark is an open-source voice assistant for Android built on the [OACP protocol](https://github.com/OpenAppCapabilityProtocol/oacp). It discovers installed OACP-enabled apps via ContentProvider, resolves voice commands to actions using on-device AI, dispatches Android intents, and speaks results back, all without leaving the assistant.

**Stack:** Flutter/Dart (UI + Riverpod state) with forui widgets + go_router routing, Kotlin (Android native bridge), on-device AI (EmbeddingGemma 308M + Qwen3 0.5B)

**Package:** `com.oacp.hark`

---

## Repository Structure

```
hark/
├── packages/
│   └── hark_platform/                           # Flutter plugin: Pigeon-based Dart/Kotlin bindings
│       ├── pigeons/messages.dart                 # Pigeon schema (source of truth for all APIs)
│       ├── lib/hark_platform.dart                # Generated + hand-written Dart API surface
│       └── android/.../
│           ├── HarkPlatformPlugin.kt             # Kotlin host API implementations (delegates wake word to WakeWordService)
│           └── WakeWordDetector.kt               # openWakeWord engine wrapper (owned by WakeWordService in app module)
├── lib/
│   ├── main.dart                               # Entry point: ProviderScope + MaterialApp.router + FTheme
│   ├── overlay_main.dart                        # Overlay entrypoint (thin UI shell, no models)
│   ├── models/
│   │   ├── agent_manifest.dart                 # oacp.json parsing (AgentManifest, Capability, Parameter)
│   │   ├── assistant_action.dart               # Runtime action model (AssistantAction, enums)
│   │   ├── command_resolution.dart             # Resolution result types
│   │   ├── discovered_app.dart                 # Discovered app data model
│   │   └── resolved_action.dart                # Intent resolution output
│   ├── theme/
│   │   └── hark_theme.dart                     # FThemes.green.dark.touch builder
│   ├── router/
│   │   └── hark_router.dart                    # GoRouter: /, /chat, /actions + init-gated redirect
│   ├── state/                                   # ALL mutable state lives here, pure Riverpod, no codegen
│   │   ├── embedding_notifier.dart             # Notifier<EmbeddingState>, owns GemmaEmbedder runtime
│   │   ├── slot_filling_notifier.dart          # Notifier<SlotFillingState>, owns Qwen3 runtime
│   │   ├── services_providers.dart             # Plain Providers for STT, TTS, logger, help, result bus
│   │   ├── registry_provider.dart              # FutureProvider<CapabilityRegistry> + IntentDispatcher
│   │   ├── resolver_provider.dart              # Wires LoggingCommandResolver(NluCommandResolver(...))
│   │   ├── init_notifier.dart                  # Aggregates embedding + slot + registry into isReady
│   │   ├── chat_state.dart                     # ChatMessage, ChatRole, InputMode, ChatState data classes
│   │   ├── chat_notifier.dart                  # Notifier<ChatState>, all chat business logic
│   │   └── app_icon_provider.dart              # FutureProvider.family<AppInfo?, String> (installed_apps)
│   ├── screens/
│   │   ├── splash_screen.dart                  # Dark branded splash with per-model progress rows
│   │   ├── chat_screen.dart                    # ConsumerStatefulWidget, forui FScaffold + composer
│   │   ├── available_actions_screen.dart       # Capabilities browser: FAccordion + per-app icons
│   │   ├── overlay_screen.dart                 # Overlay UI: chat bubbles with app icons, mic/keyboard toggle
│   │   └── widgets/                             # Presentational widgets (no Riverpod, no business logic)
│   │       ├── mic_button.dart                  # 80px circular mic with pulse + press scale
│   │       ├── thinking_bubble.dart             # 3-dot pulsing indicator
│   │       ├── chat_bubble.dart                 # Role-themed message bubble with pending states
│   │       └── composer_bar.dart                # AnimatedSwitcher between mic mode and keyboard mode
│   └── services/                                # Stateless services consumed via providers
│       ├── app_discovery_service.dart           # Pigeon HarkCommonApi bridge
│       ├── capability_help_service.dart         # "What can you do?" handler
│       ├── capability_registry.dart             # Central registry: parses manifests, AssistantAction list
│       ├── command_resolver.dart                # Abstract interface for resolvers
│       ├── inference_logger.dart                # JSONL logging for model comparison
│       ├── intent_dispatcher.dart               # Android Intent dispatch (broadcast + activity)
│       ├── logging_command_resolver.dart        # Logging decorator, takes fallbackModelId via ctor
│       ├── nlu_command_resolver.dart            # Embedding-based ranking, takes callables not services
│       ├── oacp_result_service.dart             # HarkResultFlutterApi callback handler
│       ├── overlay_bridge_service.dart          # Main engine state relay to overlay engine
│       ├── stt_service.dart                     # Speech-to-text wrapper
│       └── tts_service.dart                     # Text-to-speech wrapper
├── assets/
│   ├── hark_logo.png                            # Splash + chat empty-state hero (declared in pubspec)
│   └── wakeword/
│       └── hey_harkh.onnx                       # Custom-trained wake word model (201KB)
├── melspectrogram.onnx                           # openWakeWord audio preprocessor (root-level)
├── embedding_model.onnx                          # openWakeWord embedding preprocessor (root-level)
├── android/app/src/main/kotlin/com/oacp/hark/
│   ├── MainActivity.kt                          # Main FlutterActivity, hosts main engine
│   ├── OverlayActivity.kt                       # Translucent FlutterActivity for assist overlay (excludeFromRecents + noHistory)
│   ├── HarkApplication.kt                       # Application subclass, FlutterEngineGroup owner, onWakeWordDetected → showSession()
│   ├── HarkVoiceInteractionService.kt           # Android system assistant service (exposes static instance for overlay launch)
│   ├── HarkSessionService.kt                    # Voice interaction session factory
│   ├── HarkSession.kt                           # Session lifecycle (launches OverlayActivity)
│   ├── HarkRecognitionService.kt                # Stub RecognitionService (required by Android)
│   └── WakeWordService.kt                       # Foreground Service owning WakeWordDetector, persistent notification, START_STICKY
├── cargokit_options.yaml                        # Forces precompiled flutter_embedder binaries
├── docs/                                         # Architecture and design docs
│   └── plans/phase1-ui-redesign.md              # Phase 1 (forui + Riverpod + go_router) history
├── test/                                         # Flutter tests
├── .github/workflows/ci.yml                     # Flutter analyze + test + APK build
├── pubspec.yaml                                  # Flutter dependencies
└── android/app/build.gradle.kts                 # Debug builds restricted to arm64-v8a
```

---

## State Architecture

**Rule: zero `ChangeNotifier` in `lib/`. All state is Riverpod, all providers are hand-written (no codegen).**

- **`Notifier<T>`** (Riverpod 3.x): mutable state classes. Mounted via `NotifierProvider<N, T>(N.new)`. Used for `EmbeddingNotifier`, `SlotFillingNotifier`, `InitNotifier`, `ChatNotifier`.
- **`Provider<T>`**: stateless services (STT, TTS, logger, dispatcher, resolver, etc.).
- **`FutureProvider<T>`**: one-shot async init (`capabilityRegistryProvider`).
- **`FutureProvider.family<T, K>`**: keyed async lookups (`appInfoProvider` by package name).

Providers never import Riverpod codegen packages. Adding `@riverpod` annotations is forbidden for this codebase.

Business logic lives in `ChatNotifier`, not in any screen. Screens are `ConsumerWidget` / `ConsumerStatefulWidget` that watch `chatProvider` / `initProvider` and dispatch actions via `ref.read(provider.notifier).method(...)`.

---

## Routing

`go_router` ^17.2.0 with three routes:

| Path | Name | Screen |
|------|------|--------|
| `/` | splash | `SplashScreen` (held until all on-device deps are ready) |
| `/chat` | chat | `ChatScreen` (main conversation surface) |
| `/actions` | actions | `AvailableActionsScreen` (capabilities browser) |

The router is exposed as `goRouterProvider` (a plain `Provider<GoRouter>`) and wired into `MaterialApp.router` in `main.dart`. A hand-rolled pure `Listenable` (not `ChangeNotifier`) subscribes to `initProvider` so the router refreshes its redirect whenever `isReady` flips between true and false. The redirect holds the user on `/` until ready, then snaps to `/chat`.

---

## AI Pipeline

The NLU pipeline is pure embedding-based, no heuristics, no BM25, no keyword matching:

```
Transcript (from STT, streaming through ChatNotifier onResult)
    │
    ▼
EmbeddingGemma 308M (embedding_notifier.dart)
    Embeds transcript, compares cosine similarity against
    pre-embedded action descriptions (built from description,
    aliases, examples, keywords, parameter metadata)
    │
    ├─ semanticScore < 0.30 → reject (floor)
    ├─ semanticScore < 0.35 → reject (confidence gate)
    │
    ▼
Qwen3 0.5B (slot_filling_notifier.dart)
    Extracts parameters from transcript for the selected action
    │
    ▼
IntentDispatcher → Android broadcast or activity intent
```

`NluCommandResolver` is decoupled from Riverpod: it takes `embedQuery`, `embedDocument`, and `slotFill` callables plus a `modelId` string. `resolver_provider.dart` wires these callables through `ref.read(embeddingProvider.notifier)...` etc. This keeps the resolver testable without a Riverpod container.

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `forui` ^0.20.4 | UI primitives (dark green theme, FScaffold, FHeader, FAccordion, FCard, etc.) |
| `flutter_riverpod` ^3.3.1 | State management, manual providers only, no codegen |
| `go_router` ^17.2.0 | Declarative routing with init-gated redirect |
| `installed_apps` ^2.1.1 | Per-package launcher icon + metadata lookup (Android PackageManager) |
| `flutter_embedder` ^0.1.7 | EmbeddingGemma inference (Rust bridge) |
| `flutter_gemma` ^0.13.0 | Qwen3 model management and inference |
| `speech_to_text` ^7.3.0 | Android SpeechRecognizer |
| `flutter_tts` ^4.2.5 | Text-to-speech |
| `android_intent_plus` ^6.0.0 | Intent dispatch |
| `permission_handler` ^12.0.1 | Runtime permissions |
| `xyz.rementia:openwakeword` 0.1.4 | On-device wake word detection engine (ONNX Runtime, Maven Central) |
| `com.github.gkonovalov.android-vad:silero` 2.0.10 | Voice activity detection for wake word audio pipeline (JitPack) |

| `hark_platform` (path) | Pigeon-based plugin for type-safe Dart/Kotlin platform bindings |
| `pigeon` (dev, in plugin) | Code generator for type-safe platform channels |

**Dependency override:** `flutter_rust_bridge: 2.11.1`, pinned to match flutter_embedder codegen version.

**Build config:** `cargokit_options.yaml` at the project root forces precompiled flutter_embedder binaries instead of source-building Rust. `android/app/build.gradle.kts` restricts debug builds to `arm64-v8a` via `ndk.abiFilters` so clean rebuilds don't compile for x86 ABIs that have no precompiled binaries upstream.

---

## Platform Plugin (hark_platform)

All native platform communication goes through the `hark_platform` plugin at `packages/hark_platform/`. Raw MethodChannel and EventChannel code has been removed from the app.

**Pigeon schema:** `packages/hark_platform/pigeons/messages.dart` is the single source of truth for all platform APIs. To regenerate bindings after editing the schema:

```bash
cd packages/hark_platform
dart run pigeon --input pigeons/messages.dart
```

**API split:**

| API | Direction | Scope |
|-----|-----------|-------|
| `HarkCommonApi` | Dart to Kotlin | Available on all engines (discovery, intent dispatch, permissions, wake word control: start/stop/pause service, query running state) |
| `HarkOverlayApi` | Dart to Kotlin | Overlay engine only (dismiss overlay, relay user input to main engine) |
| `HarkMainApi` | Dart to Kotlin | Main engine only (model control, session management) |
| `HarkResultFlutterApi` | Kotlin to Dart | Callback from native to Dart (async results from OACP apps, wake word detection events via onWakeWordDetected) |
| `HarkOverlayFlutterApi` | Kotlin to Dart | Callback from native to overlay Dart (state updates from main engine) |

The overlay engine is a thin UI shell that loads zero models. It receives state updates (STT transcripts, NLU results, TTS status) from the main engine via the native Pigeon bridge through OverlayActivity.

---

## Overlay Architecture

Hark uses a **FlutterEngineGroup** with two engines:

1. **Main engine** (`main.dart`): Full app with all models loaded (EmbeddingGemma, Qwen3), STT, TTS, and the complete Riverpod state tree. Runs in `MainActivity`.
2. **Overlay engine** (`overlay_main.dart`): Thin UI shell with chat bubbles, mic button, and keyboard input. Loads zero models. Runs in `OverlayActivity`, a translucent `FlutterActivity` that renders on top of the current app.

**State relay:** The overlay engine does not process voice commands directly. User input (voice or text) is relayed from the overlay to the main engine through the native Pigeon bridge in `OverlayActivity`. The main engine runs STT, NLU, and TTS, then pushes state updates back to the overlay for display. `OverlayBridgeService` on the main engine side manages this relay.

**Why zero models in the overlay:** Loading models takes seconds on mid-range hardware. The overlay must appear instantly when the user triggers the assist gesture. By keeping the overlay as a pure UI shell, it launches with no cold-start delay. The main engine, which is already running in the background, handles all processing.

**Session lifecycle:** When the assist gesture fires, `HarkSession` launches `OverlayActivity` instead of `MainActivity`. The overlay connects to the main engine via the native bridge, auto-starts the microphone, and presents the conversation UI. Dismissing the overlay finishes `OverlayActivity` without affecting the main engine.

**Wake word:** "Hey Hark" detection runs in a foreground Service (`WakeWordService`) in the app module with `FOREGROUND_SERVICE_TYPE_MICROPHONE` and a persistent notification. Detection survives swipe-from-recents via the `VoiceInteractionService` system binding plus `START_STICKY`. On detection the service pauses the detector (releasing the mic), then `HarkApplication.onWakeWordDetected()` calls `VoiceInteractionService.showSession()` — the system-sanctioned background activity launch — which triggers `HarkSession.onShow()` and the `OverlayActivity`. The overlay's `onOverlayOpened` callback auto-starts the mic. The notification has a "Stop" action that sends `ACTION_STOP` to the service, releasing the mic without relaunching the app.

---

## Local Development

```bash
flutter pub get
flutter analyze    # must pass with zero issues
flutter test
flutter run        # physical Android device strongly recommended
flutter run --profile    # use this to validate UI performance, debug is 10-100x slower
```

Physical device recommended for: microphone, GPU inference, OACP app discovery, system assistant integration.

---

## Working Rules

1. **Naming:** Always `oacp.json` and `OACP.md`. Never `agent.json` or `AGENT.md`.
2. **No hardcoded app references in Hark:** `grep -ri "flashlight\|music\|wikipedia\|breezy\|librecamera" lib/` should return nothing except UI hint text.
3. **Local-first:** Do not introduce cloud dependencies into the core resolution path.
4. **Stage specific files:** Never `git add -A`. Always stage by name.
5. **Feature branches:** Never commit directly to `main`. Always branch first.
6. **Analyze before committing:** `flutter analyze` must pass clean.
7. **Zero `ChangeNotifier` in `lib/`.** State is Riverpod. Any new `ChangeNotifier` import in `lib/` is a bug; use `Notifier<T>` + `NotifierProvider`.
8. **No Riverpod codegen.** Do not add `riverpod_annotation`, `riverpod_generator`, or `@riverpod` annotations. All providers are hand-written.

---

## Related Repos

| Repo | What |
|------|------|
| [OpenAppCapabilityProtocol/oacp](https://github.com/OpenAppCapabilityProtocol/oacp) | Protocol spec, docs, example app |
| [OpenAppCapabilityProtocol/oacp-android-sdk](https://github.com/OpenAppCapabilityProtocol/oacp-android-sdk) | Kotlin SDK for adding OACP to Android apps |

---

## Known Issues

See [GitHub Issues](https://github.com/OpenAppCapabilityProtocol/hark/issues) for tracked items. Key ones:

- #1: BroadcastReceiver open to injection (no permission protection)
- #2: Release build uses debug signing key
- #6: QUERY_ALL_PACKAGES should be replaced with targeted queries
- #8: Discovery and model deletion run on main thread (ANR risk)
