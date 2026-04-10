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

### 4. Model Loading Performance — measurement + decision in progress

Status: `[-]`

Before the overlay ships, cold start needs to feel instant. The original plan here was a hard llamadart migration. Slice 0 (the quantization benchmark harness) ran and produced a concrete verdict (see [`docs/plans/llamadart-migration-findings.md`](docs/plans/llamadart-migration-findings.md)):
- **EmbeddingGemma 300M Q8_0 via llamadart**: clean win. 3.7s cold load + 150ms embed on Moto G56, quality identical to ONNX baseline.
- **Qwen3 0.6B Q8_0 via llamadart for slot filling**: hardware-bound on mid-range Android. 27-30s per case on the Moto G56 CPU. The bottleneck is compute on prompt processing, not memory bandwidth, so no quant trick breaks the wall. Slot-filling migration is killed.

The remaining question is whether the **current `flutter_embedder` + `flutter_gemma` stack** is faster, slower, or about the same as the measured llamadart numbers. We don't have clean comparison numbers yet. Until we do, the migration decision is on pause.

**Near-term plan** (replaces the old 7-slice breakdown):

- [x] Slice 0 — Quantization benchmark harness (`tools/quant_bench/`), 20-case embedding gold set, 15-case slot-filling gold set, v3 quant matrix, decision findings in [`docs/plans/llamadart-migration-findings.md`](docs/plans/llamadart-migration-findings.md). Shipped.
- [x] Instrumentation — Stopwatch-wrapped timing around the current load path, logs to `model_load_logs/load_*.jsonl`. Shipped as the `f213e36` commit (reusable for both runtimes).
- [x] Keyword / alias fast-path — zero-parameter commands (flashlight, pause, scan) dispatch without touching the slot-filling LLM. Shipped as the `2efe65d` commit.
- [-] **Phase 1 — Comparative measurement**: run the same bench harness (or a flutter_gemma fork of it) against the current stack on Moto G56. Produce a comparison table with concrete numbers for every cell. Write up `docs/plans/load-time-baseline.md`.
- [ ] **Phase 2 — Migration decision + load-time optimization**: based on Phase 1 data, migrate the embedder to llamadart (if clearly faster), keep the current slot filler (per Slice 0 findings), and land load-time optimizations (parallel init, persistent action embedding cache, warm engine retention). See `.claude/plans/async-twirling-galaxy.md` for the full phased plan.

**Deferred**: slot-filling migration to llamadart is killed per Slice 0 findings. Smaller quants (Q4_0, Qwen2.5-0.5B Q4_K_M) were tested and don't break the hardware wall. The slot-filling workstream re-opens only if a future runtime introduces a working GPU/NPU delegate for mid-range Android.

**Research preserved**:
- [`docs/vision/encoder-slot-filler-survey.md`](docs/vision/encoder-slot-filler-survey.md) — Track 2 research on encoder-based slot tagging as a non-LLM alternative. Parked for v2 vision.
- [`docs/plans/llamadart-migration.md`](docs/plans/llamadart-migration.md) — original 7-slice plan, preserved for historical context.

**Why this is #4**: Before the overlay ships, cold start needs to feel instant. Measurement first, optimization second, migration only if the data supports it.

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

---

## Long-term vision

Hark's long-term direction is an **agent architecture** with memory, routines, ambient sensing, multi-turn conversation, and interruption handling — capable of running multi-step automations like "start the work drive" and handling interruptions like an incoming call pausing music and resuming after.

That architecture is the right long-term direction but intentionally deferred until the near-term foundation (fast load times, polished splash UX, floating overlay, wake word) is solid. Full research, first-principles toolbox, layered architecture, scenario walkthroughs, and pre-mortem are preserved in:

- [`docs/vision/hark-v2-agent-architecture.md`](docs/vision/hark-v2-agent-architecture.md) — the complete vision doc.
- [`docs/vision/encoder-slot-filler-survey.md`](docs/vision/encoder-slot-filler-survey.md) — research on encoder-based slot tagging as a non-LLM alternative for on-device parameter extraction.
- [`docs/plans/llamadart-migration-findings.md`](docs/plans/llamadart-migration-findings.md) — the hardware benchmark findings that shaped the vision (local generative slot filling is hardware-bound at ~28 s/case on mid-range Android; cloud or encoder NER are the viable paths).

The v2 architecture is a hypothesis, not a commitment. It will be reconsidered once the near-term plan ships and there is real shipping data from Hark v1 about what users actually do.
