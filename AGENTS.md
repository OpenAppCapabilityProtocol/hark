# AGENTS.md — Hark Voice Assistant

This file is the authoritative context document for any AI agent working in this repository. Read it before making changes.

---

## What Is Hark

Hark is an open-source voice assistant for Android built on the [OACP protocol](https://github.com/OpenAppCapabilityProtocol/oacp). It discovers installed OACP-enabled apps via ContentProvider, resolves voice commands to actions using on-device AI, dispatches Android intents, and speaks results back — all without leaving the assistant.

**Stack:** Flutter/Dart (UI + business logic), Kotlin (Android native bridge), on-device AI (EmbeddingGemma 308M + Qwen3 0.5B)

**Package:** `com.oacp.hark`

---

## Repository Structure

```
hark/
├── lib/
│   ├── main.dart                          # Entry point
│   ├── models/
│   │   ├── agent_manifest.dart            # oacp.json parsing (AgentManifest, Capability, Parameter)
│   │   ├── assistant_action.dart          # Runtime action model (AssistantAction, enums)
│   │   ├── command_resolution.dart        # Resolution result types
│   │   ├── discovered_app.dart            # Discovered app data model
│   │   ├── discovered_app_status.dart     # Discovery state enum
│   │   └── resolved_action.dart           # Intent resolution output
│   ├── screens/
│   │   ├── assistant_screen.dart          # Main chat UI, STT/TTS/resolve/dispatch orchestration
│   │   ├── available_actions_screen.dart  # Browse discovered capabilities
│   │   └── discovered_apps_screen.dart    # View installed OACP apps
│   └── services/
│       ├── app_discovery_service.dart      # MethodChannel bridge → native discoverOacpApps()
│       ├── capability_help_service.dart    # "What can you do?" handler
│       ├── capability_registry.dart        # Central registry: parses manifests → AssistantAction list
│       ├── command_resolver.dart           # Abstract interface for resolvers
│       ├── gemma_embedding_service.dart    # EmbeddingGemma 308M inference via flutter_embedder
│       ├── inference_logger.dart           # JSONL logging for model comparison
│       ├── intent_dispatcher.dart          # Android Intent dispatch (broadcast + activity)
│       ├── logging_command_resolver.dart   # Logging decorator for resolver
│       ├── nlu_command_resolver.dart       # Embedding-based intent ranking + confidence gating
│       ├── oacp_result_service.dart        # EventChannel listener for async results from apps
│       ├── slot_filling_service.dart       # Qwen3 0.5B parameter extraction
│       ├── stt_service.dart               # Speech-to-text wrapper
│       └── tts_service.dart               # Text-to-speech wrapper
├── android/app/src/main/kotlin/com/oacp/hark/
│   ├── MainActivity.kt                    # Flutter activity + 3 MethodChannels
│   ├── OacpDiscoveryHandler.kt            # Scans ContentProviders with .oacp authority
│   ├── OacpResultReceiver.kt              # BroadcastReceiver for org.oacp.ACTION_RESULT
│   ├── LocalModelStorageHandler.kt        # Model backup/restore to Downloads/local-llm/
│   ├── HarkVoiceInteractionService.kt     # Android system assistant service
│   ├── HarkSessionService.kt              # Voice interaction session factory
│   ├── HarkSession.kt                     # Session lifecycle (launches MainActivity)
│   └── HarkRecognitionService.kt          # Stub RecognitionService (required by Android)
├── test/                                   # Flutter tests
├── docs/                                   # Architecture and design docs
├── .github/workflows/ci.yml               # Flutter analyze + test + APK build
├── pubspec.yaml                            # Flutter dependencies
└── android/app/build.gradle.kts           # Android build config (com.oacp.hark)
```

---

## AI Pipeline

The NLU pipeline is pure embedding-based — no heuristics, no BM25, no keyword matching:

```
Transcript (from STT)
    │
    ▼
EmbeddingGemma 308M (gemma_embedding_service.dart)
    Embeds transcript, compares cosine similarity against
    pre-embedded action descriptions (built from description,
    aliases, examples, keywords, parameter metadata)
    │
    ├─ semanticScore < 0.30 → reject (floor)
    ├─ semanticScore < 0.35 → reject (confidence gate)
    │
    ▼
Qwen3 0.5B (slot_filling_service.dart)
    Extracts parameters from transcript for the selected action
    │
    ▼
IntentDispatcher → Android broadcast or activity intent
```

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_embedder` ^0.1.7 | EmbeddingGemma inference (Rust bridge) |
| `flutter_gemma` ^0.13.0 | Qwen3 model management and inference |
| `speech_to_text` ^7.3.0 | Android SpeechRecognizer |
| `flutter_tts` ^4.2.5 | Text-to-speech |
| `android_intent_plus` ^6.0.0 | Intent dispatch |
| `permission_handler` ^12.0.1 | Runtime permissions |

**Dependency override:** `flutter_rust_bridge: 2.11.1` — pinned to match flutter_embedder codegen version.

---

## Local Development

```bash
flutter pub get
flutter analyze    # must pass with zero issues
flutter test
flutter run        # physical Android device strongly recommended
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
