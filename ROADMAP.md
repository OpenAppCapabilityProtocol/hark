# Hark Roadmap

Status legend:
- `[x]` done
- `[-]` in progress
- `[ ]` not started

For the OACP protocol roadmap, see [OpenAppCapabilityProtocol/oacp](https://github.com/OpenAppCapabilityProtocol/oacp).

---

## What's Working

- Dynamic OACP app discovery via ContentProvider scanning
- Two-stage on-device AI: EmbeddingGemma 308M (intent) + Qwen3 0.5B (slots)
- Deterministic fast path with BM25 keyword/alias/example matching
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

### 4. Assistant Overlay

Status: `[ ]`

- [ ] Dedicated lightweight overlay Activity (currently opens full MainActivity)
- [ ] Extract shared Flutter engine for both main and overlay Activities
- [ ] Assistant-like experience on top of current app (like Claude/ChatGPT)

### 5. Action Chips and Buttons

Status: `[ ]`

- [ ] Tappable action chips in chat bubbles for capability-help replies
- [ ] Disambiguation buttons ("Did you mean front camera or rear camera?")
- [ ] Follow-up suggestion chips (Google Assistant-style)
- [ ] Protocol-driven: buttons come from discovered OACP actions, not hardcoded

### 6. Wake Word

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
- Two-tier context optimization (~500 tokens selection, ~400 tokens extraction)
- BM25 heuristic handles clear winners instantly
- Model only consulted for ambiguous cases

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
