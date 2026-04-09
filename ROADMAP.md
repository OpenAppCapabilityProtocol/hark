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
- System voice assistant registration (VoiceInteractionService)
- Continuous listening mode from assistant gesture
- Multi-model support with persistent model backup
- Inference logging for debugging and model comparison
- Real-world integrations tested: Breezy Weather, Binary Eye, Voice Recorder, Libre Camera, Wikipedia, ArchiveTune

---

## Current Priorities

Build these next, in order:

### 1. Self-Hosted Inference

Status: `[ ]`

Connect Hark to Ollama, LM Studio, or any OpenAI-compatible endpoint on the user's local network.

- [ ] Settings screen for inference mode selection (local / self-hosted / cloud)
- [ ] Provider interface that all backends implement
- [ ] Self-hosted mode: URL input, connection test, OpenAI-compatible API client
- [ ] Feed `OACP.md` content to self-hosted providers (larger context budget)
- [ ] Graceful fallback: self-hosted unavailable -> local

**Why this is #1**: Unlimited context, reliable parameter extraction, OACP.md consumption, zero cost. A $200 old laptop with 16GB RAM can serve the household.

### 2. BYOK Cloud API Keys

Status: `[ ]`

- [ ] API key input for OpenAI, Gemini, Anthropic
- [ ] Secure storage for keys
- [ ] Cloud quota fallback -> local

### 3. Better STT

Status: `[ ]`

- [ ] Evaluate whisper.cpp / sherpa-onnx for on-device speech recognition
- [ ] Eliminate Android system beep on listen start
- [ ] Enable true continuous listening without system STT limitations

### 4. Model Loading Performance — llamadart migration

Status: `[-]`

Replace `flutter_embedder` (ORT, no mmap, synchronous main-isolate load) and `flutter_gemma` (MediaPipe, plugin teardown on Activity detach) with a single `llamadart` dependency. llamadart ships mmap-by-default, isolate-based inference, explicit hot-restart handling, and a first-class embedding API tested with EmbeddingGemma as its default example. Migration deletes two plugins instead of forking one and gets every architectural property we'd otherwise build ourselves for free.

Gated on a quantization benchmark (Slice 0) that picks the Q4_K_M / Q5_K_M / Q8_0 sweet spot per model empirically instead of guessing.

- [ ] Slice 0 — Quantization benchmark harness: `tools/quant_bench/` CLI, 20-case embedding gold set + 15-case slot-filling gold set, matrix over 3 quants × 2 models, decision table in `docs/plans/llamadart-quant-benchmark.md`
- [ ] Slice 1 — Baseline instrumentation (before): Stopwatch-wrapped `HarkLoadPerf` logs around current load path, device numbers in `docs/plans/llamadart-migration-baseline.md`
- [ ] Slice 5 — Keyword / alias fast-path: zero-parameter commands (flashlight, pause, scan) dispatch during splash before models load
- [ ] Slice 2 — Migrate `EmbeddingNotifier` from `flutter_embedder` → `llamadart`
- [ ] Slice 3 — Migrate `SlotFillingNotifier` from `flutter_gemma` → `llamadart` (skipped if Slice 0 falls back to embedder-only)
- [ ] Slice 4 — Warm engine via `HarkApplication.onCreate()` + `keepAliveMain` Dart entrypoint
- [ ] Slice 6 — Re-measure on-device, update baseline doc with before/after columns
- [ ] Slice 7 — Flip this item to done, unblock Assistant Overlay (#5), open PR

Full plan: [`docs/plans/llamadart-migration.md`](docs/plans/llamadart-migration.md).

**Why this is #4**: Before we ship the overlay, cold start needs to feel instant. Earlier iteration of this plan proposed forking `flutter_embedder` to add mmap + a static session cache. Deep research found `llamadart` already has all of that, plus 20+ chat templates, hot-restart safety, isolate-based backend, and prebuilt native binaries via Dart's `hook/build.dart`. Migration is smaller and safer than forking.

**Deferred as Phase-4 follow-ups**:
- Precompute capability embeddings at registry-refresh time
- Switch embedding model family (all-MiniLM-L6-v2 / e5-small-v2) — only if Q8_0 fails the quality gate
- Fork `llamadart` (not needed unless we hit an upstream gap)

### 5. Assistant Overlay

Status: `[ ]`

Blocked by Model Loading Performance (#4).

- [ ] Dedicated lightweight overlay Activity (currently opens full MainActivity)
- [ ] Extract shared Flutter engine for both main and overlay Activities
- [ ] Assistant-like experience on top of current app (like Claude/ChatGPT)

### 6. Action Chips and Buttons

Status: `[ ]`

- [ ] Tappable action chips in chat bubbles for capability-help replies
- [ ] Disambiguation buttons ("Did you mean front camera or rear camera?")
- [ ] Follow-up suggestion chips (Google Assistant-style)
- [ ] Protocol-driven: buttons come from discovered OACP actions, not hardcoded

### 7. Wake Word

Status: `[ ]`

- [ ] Software wake-word detection ("Hey Hark")
- [ ] Privacy controls (when is the mic active)
- [ ] Battery impact controls
- [ ] Optional hardware-aware path for supported devices

---

## Completed Milestones

### Two-Stage Pipeline `[x]`

Replaced single FunctionGemma 270M model with:
- EmbeddingGemma 308M for semantic intent matching (MTEB 61.15)
- Qwen3 0.5B for parameter extraction
- 9-point improvement over previous e5-small-v2 embedding model

### Async Result Handling `[x]`

Apps can return data to Hark without the user leaving:
- Native BroadcastReceiver listens for `org.oacp.ACTION_RESULT`
- Results displayed in chat + spoken via TTS
- Request ID correlation for tracking

### Dynamic Tool-Calling Runtime `[x]`

Discovered OACP capabilities become runtime tools for the on-device model:
- EmbeddingGemma ranks all candidates by semantic similarity
- Confidence gate filters weak matches before slot filling
- Qwen3 extracts parameters only for the selected action

### System Assistant Integration `[x]`

Hark qualifies as an Android default assistant:
- VoiceInteractionService, SessionService, RecognitionService
- RoleManager for ROLE_ASSISTANT on Android 10+
- Auto-listen on assistant gesture launch
- Continuous listening mode

---

## Future / Not Now

These are intentionally deferred:

- Play Store submission and policy compliance
- iOS support
- Multi-intent utterances ("set an alarm and turn off the lights")
- NPU/backend optimization before the inference provider layer is stable
- Wake word before assistant overlay is done
