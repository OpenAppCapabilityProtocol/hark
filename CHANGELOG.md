# Changelog

All notable changes to Hark will be documented in this file.

---

## [1.0.0] - 2026-04-06

Initial public release.

### Voice Assistant

- On-device speech-to-text via Android SpeechRecognizer
- Text-to-speech for confirmations and result readback
- Tap-to-cancel listening with 10-second silence timeout
- Continuous listening mode when launched as system assistant

### OACP Integration

- Dynamic discovery of OACP-enabled apps via ContentProvider scanning
- Capability registry aggregating actions from all discovered apps
- Intent dispatch via broadcast (background) and activity (foreground)
- Async result handling: apps return data without user leaving Hark
- Request ID correlation for result tracking

### On-Device AI Pipeline

- **Two-stage resolution**: EmbeddingGemma 308M for intent selection (semantic similarity) + Qwen3 0.5B for slot filling
- **Confidence gating**: Semantic score floor (0.30) and confidence threshold (0.35) filter weak/ambiguous matches
- Multi-model support: switchable between models from Local Models screen
- Persistent model backup to `Downloads/local-llm/` with auto-restore on reinstall
- Inference logging (JSONL) for debugging and model comparison

### Android Assistant Integration

- Registers as system voice assistant via VoiceInteractionService
- Long-press Home or assistant gesture launches Hark with auto-listen
- RoleManager integration for requesting ROLE_ASSISTANT on Android 10+
- UI banner when not set as default assistant

### Real-World Integrations Tested

- Breezy Weather (async weather queries spoken back)
- Binary Eye (QR scanner launch)
- Voice Recorder (start/stop recording)
- Libre Camera (selfie with timer)
- Wikipedia (search)
- ArchiveTune (music playback by voice)
