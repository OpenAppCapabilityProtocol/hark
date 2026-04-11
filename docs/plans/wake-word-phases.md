# Wake Word: Phased Implementation Plan

## Phase 1: In-App Detection (current)

Status: working, on branch `feat/wake-word`

Wake word detection while app is open. Says "Hello World" (placeholder)
or "Hey Hark" (trained model) and mic auto-starts.

Stack: openWakeWord (Apache 2.0) + ONNX Runtime on Android.

### What works
- WakeWordDetector.kt wrapping openWakeWord's WakeWordEngine
- Full Pigeon integration: startWakeWordService/stopWakeWordService/isWakeWordRunning/setWakeWordPaused
- Dart side: OacpResultService.wakeWordDetections stream -> ChatNotifier auto-starts mic
- Mutual exclusion with STT via engine stop/restart (AudioRecord conflict on Moto G56)

### Known issues
- ~25 second buffer rebuild after each engine restart (openWakeWord needs 10s of audio embeddings)
- AudioRecord and SpeechRecognizer conflict on Moto G56 (cannot run simultaneously)
- Using hello_world.onnx placeholder model until hey_hark.onnx is trained

### Still needed
- Train hey_hark.onnx via openWakeWord Colab notebook
- Wake word settings screen with toggle
- Investigate reducing buffer rebuild time (fork openWakeWord to use fewer embeddings?)

## Phase 2: Background Service

Status: not started

Run wake word detection as a Kotlin foreground service so it works
when the app is backgrounded or screen is off.

### Key pieces
- WakeWordService.kt (foreground service, START_STICKY)
- Persistent notification: "Hark is listening for 'Hey Hark'"
- On detection: launch OverlayActivity (same path as assist gesture)
- Permissions: FOREGROUND_SERVICE, FOREGROUND_SERVICE_MICROPHONE, POST_NOTIFICATIONS
- Manifest: `<service android:foregroundServiceType="microphone" />`
- Green mic indicator is unavoidable (Android privacy feature)

### Battery optimization
- Silero VAD as pre-filter gate (only run wake word model during speech)
- Sensor gating: accelerometer face-down / proximity in pocket -> reduce polling
- Time-of-day: user-configurable active hours
- Target: ~1.4%/hour with VAD gating (vs ~6.8% naive)

## Phase 3: Continuous Listening Session

Status: not started, needs research

After wake word triggers, keep the mic open for a continuous
conversation session. No need to say wake word again until session ends.

### Research topics

#### Acoustic Echo Cancellation (AEC)
- Problem: when Hark speaks via TTS, the mic picks up TTS audio and
  feeds it back into the pipeline, causing false triggers or garbled input
- Android has `AcousticEchoCanceler` (AudioEffect subclass) built into AudioRecord
- It uses the speaker output as a reference signal and subtracts it from mic input
- This is how Zoom/Teams/Meet prevent feedback loops on the same device
- Questions:
  - Does AcousticEchoCanceler work with AudioRecord + MediaPlayer/TTS simultaneously?
  - What latency does it add?
  - Is it reliable on mid-range devices (Moto G56)?
  - Do we need WebRTC's AEC implementation instead?

#### Barge-in (interrupt while speaking)
- User should be able to interrupt Hark mid-response
- Detect user speech while TTS is playing
- Immediately stop TTS and start processing new input
- Silero VAD + AEC together enable this:
  1. AEC removes TTS from mic input
  2. VAD detects remaining speech (must be the user)
  3. If VAD triggers during TTS playback -> barge-in

#### Continuous session lifecycle
- Wake word triggers session start
- AudioRecord stays open for the entire session
- VAD runs continuously, detects speech segments
- Each speech segment is sent to STT for transcription
- Between segments, mic stays open but idle (low power)
- Session ends on: explicit dismiss, timeout (e.g. 30s silence), or app backgrounded
- No wake word needed within a session

#### How ChatGPT voice mode works (observations)
- Mic is always on during voice session
- User can interrupt mid-response (barge-in with 1-2s overlap)
- No echo of its own voice in the mic
- Uses server-side speech model (not on-device STT)
- Likely uses WebRTC or platform AEC for echo cancellation

#### How video calling apps handle echo
- Zoom/Teams/Meet use AEC to prevent callers from hearing their own voice
- On same device: speaker output is used as reference signal for echo cancellation
- On loudspeaker: more aggressive AEC needed due to acoustic coupling
- Sometimes fails with external speakers or unusual room acoustics
- Android's built-in AEC is tuned for the device's specific mic/speaker arrangement

### Implementation sketch (preliminary)
```
Wake word detected
    |
    v
Session starts
    |
    v
AudioRecord opens (with AcousticEchoCanceler enabled)
    |
    +---> Silero VAD running continuously
    |         |
    |         v (speech detected)
    |     STT processes speech segment
    |         |
    |         v
    |     NLU resolves command
    |         |
    |         v
    |     TTS speaks response (AEC filters this from mic)
    |         |
    |         +---> If VAD detects speech during TTS -> barge-in
    |         |         Stop TTS, process new speech
    |         |
    |         v
    |     Return to VAD monitoring
    |
    +---> 30s silence timeout -> session ends
    +---> User dismisses -> session ends
```

### Android APIs to investigate
- `android.media.audiofx.AcousticEchoCanceler`
  - `AcousticEchoCanceler.isAvailable()` - check device support
  - `AcousticEchoCanceler.create(audioSessionId)` - attach to AudioRecord
- `android.media.AudioRecord` with `MediaRecorder.AudioSource.VOICE_COMMUNICATION`
  - This audio source enables built-in AEC, AGC, and noise suppression
  - May be better than manual AcousticEchoCanceler attachment
- WebRTC's AEC module (available as native library)
  - More portable, works across devices regardless of platform AEC quality

### References to study
- Android AudioEffect docs: https://developer.android.com/reference/android/media/audiofx/AcousticEchoCanceler
- WebRTC native code: https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/
- ChatGPT voice mode teardown (if available)
- Existing open-source implementations of barge-in on Android
