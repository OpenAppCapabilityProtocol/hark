# Hark Roadmap

Status legend:
- `[x]` done
- `[-]` in progress
- `[ ]` not started

For the OACP protocol roadmap, see [OpenAppCapabilityProtocol/oacp](https://github.com/OpenAppCapabilityProtocol/oacp).

---

## What's Working

- Dynamic OACP app discovery via ContentProvider scanning
- Two-stage on-device AI: EmbeddingGemma 308M (intent selection via semantic similarity) + Qwen3 0.5B (slot filling)
- Confidence-gated matching (semantic score >= 0.35)
- Intent dispatch via broadcast (background) and activity (foreground)
- Async result handling: apps return data, Hark shows + speaks it
- System voice assistant registration (VoiceInteractionService + RoleManager)
- Continuous listening mode from assistant gesture
- Multi-model support with persistent model backup
- Inference logging for debugging and model comparison
- Real-world integrations tested: Breezy Weather, Binary Eye, Voice Recorder, Libre Camera, Wikipedia, ArchiveTune
- Assist overlay via FlutterEngineGroup: thin UI shell with zero model loading, instant launch on assist gesture
- Type-safe Dart/Kotlin bindings via hark_platform plugin (Pigeon), replacing all raw MethodChannel/EventChannel code
- Two-engine architecture: main engine (full processing) + overlay engine (UI shell), state relayed through native Pigeon bridge
- **Wake word "Hey Hark"** via openWakeWord with custom-trained `hey_harkh.onnx` (201KB)
- **Wake word foreground service** with persistent notification, Stop action, and `START_STICKY` restart
- **Wake word → overlay launch** via `VoiceInteractionService.showSession()` (system-sanctioned background activity path)
- **Lifecycle capability refresh**: OACP registry re-scans on app resume, so uninstalled apps drop out without a restart

---

## Current Priorities

The near-term foundation (overlay, wake word, two-stage NLU) is shipped. Current focus is polish, user-facing controls, and a few targeted UX gaps before scope expands.

### 1. Settings Screen

Status: `[ ]`

Users currently have no in-app way to inspect permissions, toggle wake word, or see model status. This is the next thing to build.

- [ ] `/settings` route with forui tiles
- [ ] Permissions section (live status + tap to grant): mic, notifications, default assistant
- [ ] Wake word toggle (start/stop service) with persistent preference
- [ ] Model info (embedding, slot filling, wake word versions)
- [ ] About section (version, OACP spec link, GitHub link)

### 2. Action Chips and Disambiguation

Status: `[ ]`

- [ ] Tappable action chips in chat bubbles for capability-help replies
- [ ] Disambiguation buttons when top-N semantic scores are close ("Did you mean front camera or rear camera?")
- [ ] Follow-up suggestion chips after successful actions
- [ ] Protocol-driven: chip content comes from discovered OACP actions, not hardcoded

### 3. Wake Word — polish + barge-in

Status: `[-]`

Core detection, foreground service, and overlay launch all shipped (PR #18 and PR #19). Remaining work is UX polish and a harder research problem around barge-in.

- [ ] Sensitivity slider (threshold control) exposed via Settings
- [ ] Privacy indicator (visible state when mic is hot)
- [ ] Battery impact measurement on Moto G56 + one other mid-range device
- [ ] Buffer-rebuild delay after STT (~25s) — investigate shortening
- [ ] Barge-in: interrupt Hark's TTS mid-sentence (requires acoustic echo cancellation research)

### 4. Better STT

Status: `[ ]`

System `SpeechRecognizer` works but has ceilings:
- [ ] Evaluate whisper.cpp / sherpa-onnx for fully on-device recognition
- [ ] Eliminate the Android system beep on listen start
- [ ] Enable true continuous listening without the ~30s timeout

### 5. Release Packaging

Status: `[ ]`

- [ ] Proper release signing config (currently uses debug key — GitHub issue #2)
- [ ] GitHub Releases APK publishing
- [ ] F-Droid submission once release signing is stable

---

## Completed Milestones

### Wake Word Detection `[x]` — PR #18

- On-device "Hey Hark" detection via openWakeWord + Silero VAD + ONNX Runtime
- Custom-trained `hey_harkh.onnx` (201KB) with shared melspectrogram + embedding preprocessors
- Pigeon APIs: `startWakeWordService`, `stopWakeWordService`, `isWakeWordRunning`, `setWakeWordPaused`
- Mutual exclusion with STT: wake word engine pauses while speech recognition is active, resumes after

### Wake Word Robustness `[x]` — PR #19

- **Foreground service** (`WakeWordService`) with `FOREGROUND_SERVICE_TYPE_MICROPHONE`, persistent notification, "Stop" action, `START_STICKY` restart
- **Overlay launch on detection** via `VoiceInteractionService.showSession()` — system-sanctioned background activity path
- **Recents cleanup**: `OverlayActivity` now `excludeFromRecents` + `noHistory`, no more duplicate task entries
- **Lifecycle capability refresh**: `AppLifecycleListener` in `ChatNotifier` invalidates the registry and re-warms embeddings on app resume
- `POST_NOTIFICATIONS` runtime request for Android 13+
- Monochrome `ic_notification` vector drawable (Hark robot silhouette)

### Assistant Overlay `[x]` — PR #17

- Dedicated translucent `OverlayActivity` (separate from `MainActivity`)
- `FlutterEngineGroup` with two engines: main (full app, all models) + overlay (thin UI shell, zero models)
- Chat bubbles with app icons, keyboard/mic toggle, auto-start mic on open
- State relay between engines via native Pigeon bridge through `OverlayActivity`
- `hark_platform` plugin (Pigeon) replacing all raw MethodChannel/EventChannel code
- Native handlers migrated into the plugin: `OacpDiscoveryHandler`, `LocalModelStorageHandler`, `OacpResultReceiver` removed

### Two-Stage NLU Pipeline `[x]`

- Replaced single FunctionGemma 270M model with EmbeddingGemma 308M + Qwen3 0.5B
- EmbeddingGemma ranks all discovered capabilities by semantic similarity (MTEB 61.15)
- Qwen3 extracts parameters only for the selected action
- 9-point improvement over the previous e5-small-v2 embedding model
- Keyword / alias fast-path: zero-parameter commands (flashlight, pause, scan) skip the slot filler entirely

### Async Result Handling `[x]`

- Native `BroadcastReceiver` listens for `org.oacp.ACTION_RESULT`
- Results displayed in chat + spoken via TTS
- Request ID correlation for tracking

### Dynamic Tool-Calling Runtime `[x]`

- Discovered OACP capabilities become runtime tools for the on-device model
- EmbeddingGemma ranks all candidates by semantic similarity
- Confidence gate filters weak matches before slot filling
- Qwen3 extracts parameters only for the selected action

### System Assistant Integration `[x]`

- `VoiceInteractionService`, `VoiceInteractionSessionService`, `RecognitionService`
- `RoleManager` for `ROLE_ASSISTANT` on Android 10+
- Auto-listen on assistant gesture launch
- Continuous listening mode

---

## Deferred / Not Now

These are intentionally deferred. Decisions are revisited once the near-term list ships.

- **Self-hosted inference (Ollama, LM Studio)** — deprioritized. The two-stage local pipeline is good enough for current capabilities. Revisit once users hit a real quality ceiling.
- **BYOK cloud (OpenAI, Gemini, Anthropic)** — same rationale. Defer until self-hosted lands or users demand cloud.
- **Gemma 4 single-model pipeline** — waiting on `flutter_gemma` support and a clear win over the two-stage stack.
- **Model loading perf migration (llamadart)** — the overlay architecture removed the cold-start UX pressure. Benchmark harness (`tools/quant_bench/`) and findings preserved in [`docs/plans/llamadart-migration-findings.md`](docs/plans/llamadart-migration-findings.md). Slot-filling migration is killed (hardware-bound at ~28s/case on Moto G56). Embedder migration re-opens only if the splash screen becomes a priority again.
- **Play Store submission** and policy compliance
- **iOS support**
- **Multi-intent utterances** ("set an alarm and turn off the lights")
- **NPU/backend optimization** until the provider layer is stable

**Research preserved**:
- [`docs/vision/hark-v2-agent-architecture.md`](docs/vision/hark-v2-agent-architecture.md): full v2 agent vision
- [`docs/vision/encoder-slot-filler-survey.md`](docs/vision/encoder-slot-filler-survey.md): encoder-based slot tagging as a non-LLM alternative
- [`docs/plans/llamadart-migration-findings.md`](docs/plans/llamadart-migration-findings.md): hardware benchmark findings
- [`docs/plans/llamadart-migration.md`](docs/plans/llamadart-migration.md): original 7-slice migration plan

---

## Long-term vision

Hark's long-term direction is an **agent architecture** with memory, routines, ambient sensing, multi-turn conversation, and interruption handling — capable of running multi-step automations like "start the work drive" and gracefully handling interruptions like an incoming call pausing music and resuming after.

That architecture is the right long-term direction but intentionally deferred until the near-term foundation is polished and the product has real users. The v2 vision is a hypothesis, not a commitment. It will be reconsidered once there is real shipping data from Hark v1 about what users actually do.
