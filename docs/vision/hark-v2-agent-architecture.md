# Hark v2 — agent architecture vision

**Status**: vision doc, not a plan. Intentionally deferred until the near-term foundation (load time, splash UX, overlay) is solid. Nothing here is scheduled; this document preserves the architectural research so the next person to reconsider v2 has the full picture.

**Audience**: Hark contributors, curious community members, anyone evaluating whether to build on or fork Hark. No proprietary content — public-shareable.

**Last updated**: 2026-04-10

---

## Why this doc exists

Hark today is a stateless intent router. A voice command comes in, the embedder finds the best matching OACP capability, the slot filler extracts any parameters, the dispatcher fires an Android intent, and the transaction ends. Every command is an independent event. There is no memory, no conversation thread, no ambient awareness, no multi-step orchestration.

That architecture is sufficient for the first chunk of what a voice assistant should do — quickly dispatching capabilities that apps have exposed via OACP. But it doesn't match what a user actually expects from an assistant.

Concretely, the user vision that motivated this doc described:

- Conversational queries inline in the chat thread: "what's the weather" → rendered response from the weather app, not just a TTS line.
- Multi-step routine automations: "start the work drive" → open navigation, track the drive, propose parking when we arrive, ask about the usual duration, chain into the parking app.
- Multi-turn continuity: "let's go home" → "anything else?" → "play music" → music plays → "play something else" picks up from context.
- Interruption and resume: an incoming call pauses the music, asks to pick up, on yes answers + pauses media, on call end resumes media.
- Memory: places (home, work), preferences (usual parking duration), preferred app per capability type (the user's default map app, music app, etc.).
- Ambient triggers: geofence enter, call state change, media state change, time of day.

None of those things fit in a stateless request-response loop. They all need state that survives across turns, context that crosses between apps, and orchestration that can wait for events. That's a fundamentally different architecture — what this doc calls **Hark v2**.

The v2 architecture is the right long-term direction, but **it is premature today**. Before it can ship on a solid foundation, Hark needs:

1. Fast and clear model load / init time, with polished splash UX.
2. A floating overlay so the assistant can be invoked without switching out of the current app.
3. Hands-free wake-word activation.

Without those three, the agent architecture is just unnecessary complexity stacked on a slow cold start and a full-activity UX. The near-term plan (`~/.claude/plans/async-twirling-galaxy.md` at the time of writing) delivers them. This doc is what we come back to once they ship.

---

## First-principles toolbox

A good agent architecture doesn't treat every utterance as the same problem. It assigns each interaction category to the cheapest tool that can actually handle it, and escalates only when necessary. The tools in Hark's toolbox, and what each one is actually good for:

### Keyword / alias fast path

Exact matches for zero-parameter, zero-ambiguity commands. Hark already has this — `CapabilityHelpService` (for "what can you do") and the keyword/alias fast-path in `NluCommandResolver` (for "flashlight", "pause", "scan qr"). Runs in under 5 ms, needs no model, no memory, no cloud. The hot path for ~35% of traffic.

### Embedding model (EmbeddingGemma)

A nearest-neighbor router over a stable corpus. Given an utterance, find the best match in a precomputed index. Runs in ~150 ms on mid-range Android CPU. Not a reasoning tool — it can't answer "should I book parking now?" but it can answer "does this utterance refer to the navigation capability or the parking capability?". Hark v2 uses it for three jobs:

1. **Intent classification**: same as today, finds the best OACP capability for a command.
2. **Semantic memory search**: given "go to that place I like", search the user's stored `places` table by semantic similarity.
3. **Routine name matching**: given "start work drive", find the stored routine that best matches.

The embedder is the cheap, deterministic, fast tool Hark v2 leans on hardest.

### Encoder NER (DistilBERT / BERT family token classifier)

A rigid BIO tagger that extracts structured slots from a known intent. Runs in 30-100 ms on Android CPU. Does exactly one job: once we know the intent, pull out the named entities (person, location, date, time, number, URL, action-specific parameter). Not a generative model — it can't hallucinate, but it also can't handle novel entity types without retraining.

For Hark v2 this is the local fast path for slot filling on the 20% of commands that have simple structured slots — "take a picture in 3 seconds" (extract the integer 3), "set a timer for 5 minutes" (integer + unit), "remind me at 6pm" (time). Much cheaper than a generative LLM.

The catch: no single off-the-shelf encoder covers every language + entity type combination Hark cares about. The encoder slot-filler survey (`docs/vision/encoder-slot-filler-survey.md`) lays out the candidates and the trade-offs — DistilBERT-multilingual-NER covers English and 9 European languages but not Hindi/Punjabi; IndicNER covers 11 Indic languages but needs DIY ONNX export and sits at the size cap. There is no one-model solution.

### Generative LLM (cloud, primarily — local is hardware-bound on mid-range)

The reasoning brain. Understands ambiguous language, holds multi-turn context, generates free-form responses, plans multi-step actions, handles coreference ("play it again" → resolves "it" to the last song). Runs in 500-2500 ms cloud round-trip depending on model + network, or 20-30 seconds on mid-range Android CPU (not interactive — see Slice 0 findings at `docs/plans/llamadart-migration-findings.md`).

Hark v2 uses the LLM sparingly — for the ~5-10% of utterances that genuinely need reasoning or free-form understanding. The architectural claim is that the LLM is the rare-but-load-bearing tool, not the default path. Most traffic never touches it.

The deferral of v2 is partly a cloud-readiness question. Hark today is local-first and proud of it. Going to cloud for the ambiguous cases is a real architectural shift that deserves explicit opt-in UX, privacy disclosures, and cost controls. See the decision list below.

### State machine / routine engine

Deterministic orchestration of multi-step workflows. "Start work drive" → S1 say "starting", S2 dispatch nav capability, S3 wait for geofence-enter event, S4 ask about parking, S5 dispatch parking capability. Each step is a known, typed action; each transition is either unconditional ("then do the next step") or event-driven ("when the geofence fires, advance to the next step").

Runs in zero time — it's just code. The value is in modeling the flow explicitly so it's debuggable, testable, and resumable after interruptions. Hark v2 needs this for routines and for interruption handling.

### Memory layer

Long-term continuity across sessions. Places (home, work, parking lots), preferences (usual parking duration, preferred music app), learned weights (per-capability disambiguation history), episodic history (what did we do last Monday around this time). Stored in a local SQLite database, optionally with a vector index for semantic search over stored items.

Memory is what turns Hark from "a voice shortcut to OACP" into "an assistant that knows you". None of it leaves the device in this architecture — that's a hard rule.

### Sensing layer

Android system event subscriptions. Location (fused + geofences), phone state (ringing, off-hook), media playback state (currently playing, paused), foreground app, time of day, Bluetooth connections (headphones, car), motion/activity recognition (driving, walking, stationary).

Sensing is what enables ambient triggers. Without it, Hark is purely reactive — it only does things when the user invokes it. With it, Hark can propose actions when context changes: approaching a saved parking lot, phone ringing while music is playing, connecting to the car Bluetooth in the morning.

Sensing needs a foreground service to stay alive when the Hark activity isn't visible. That's the single biggest platform bet in the v2 architecture — foreground services have real battery costs and the permission dialogue is off-putting to users. Getting this right is non-trivial.

### OACP (already shipping)

The app integration protocol. Discovered via ContentProvider scanning at startup, each app exposes its capabilities as typed actions with metadata. Hark dispatches OACP intents (Activity for foreground, BroadcastReceiver for background), receives async results via a broadcast channel, and presents them in the chat.

OACP is the foundation Hark v1 is built on, and v2 inherits it unchanged. The only architectural refinement is **referencing capability types rather than app packages** in routines — a routine that wants to start navigation should ask "who can fulfill `nav.start_navigation`?" rather than hardcoding the map app. The preferred fulfiller per capability type lives in the memory layer.

### Presentation

TTS, chat UI, notifications, overlay, action chips. This layer is mostly familiar from Hark v1 but gets new surfaces in v2: routine-progress cards, follow-up suggestion chips, ambient-prompt notifications that the routine engine emits when a geofence fires.

---

## Realistic traffic distribution

The load-bearing architectural claim: **the cloud LLM is the rare-but-load-bearing tool, not the hot path.** Roughly:

| Bucket | % of utterances | Primary tool | Escalation |
|---|---|---|---|
| Zero-param trivial ("flashlight", "pause", "scan") | 35% | keyword fast-path | — |
| Direct command + simple slots ("weather in Mumbai") | 25% | embedding → encoder NER | cloud LLM if confidence low |
| Conversational query with structured result ("what's the weather") | 15% | embedding → OACP async result | — |
| Memory-referring ("go home", "my usual parking") | 10% | embedding → memory lookup → OACP | cloud LLM for disambiguation |
| Multi-step routine ("start work drive") | 5% | routine engine | cloud LLM only for novel routine planning |
| Complex / free-form / planning | 5% | cloud LLM | — |
| Ambient / proactive (geofence, call) | 5% | sensing → routine engine | cloud LLM for prompt phrasing |

**~85% of utterances never touch the cloud LLM.** Cloud is the tool for the last 5-10%, not the default. This is the only way Hark v2 stays local-first in spirit while unlocking the agent vision.

These percentages are opinionated estimates, not measurements. Real usage data from shipping v1 might shift them significantly.

---

## Layered architecture

```
+--------------------------------------------------------------+
|  L5  Presentation                                              |
|  ChatScreen, TTS, notifications, overlay, action chips,        |
|  routine-progress card, follow-up suggestion surface           |
+--------------------------------------------------------------+
|  L4  Execution                                                 |
|  IntentDispatcher (reuse), OacpResultService (reuse),          |
|  RoutineRunner (new), InterruptionController (new)             |
+--------------------------------------------------------------+
|  L3  Routing / Planning                                        |
|  TurnPlanner (new): decides fast-path | embedding | LLM        |
|  NluCommandResolver (reuse), CapabilityHelpService (reuse)     |
|  RoutinePlanner (new, thin initially, LLM-powered later)       |
|  LlmClient (new)                                               |
+--------------------------------------------------------------+
|  L2  Memory                                                    |
|  ShortTerm: in-process turn buffer                             |
|  Session: today's messages, active routine state               |
|  LongTerm: places, preferences, learned weights (SQLite)       |
|  Episodic: date-indexed utterance log                          |
|  VectorIndex: embedding cache over memory items                |
+--------------------------------------------------------------+
|  L1  Sensing                                                   |
|  LocationService (geofences), PhoneStateService,               |
|  MediaStateService, ForegroundAppService, BluetoothService,    |
|  TimeScheduler. All behind a single SenseBus stream.           |
+--------------------------------------------------------------+
|  Cross-cutting                                                 |
|  ConversationManager (owns multi-turn turn state + follow-ups) |
|  HarkForegroundService (Android, carries L1 + ConvMgr alive)   |
+--------------------------------------------------------------+
```

Each layer has well-defined responsibilities and talks to adjacent layers via narrow interfaces. The `ConversationManager` cross-cutting concern is what replaces Hark v1's current `ChatNotifier` god-object — the orchestrator that owns conversation state, hands work to the planner, handles routine progression, and funnels results back to the presentation layer.

### Reuse vs build

| Layer | What Hark v1 already has (reuse) | What v2 would need to build |
|---|---|---|
| L5 Presentation | `ChatScreen`, `ChatNotifier` (slim it down), `TtsService` | Routine-progress card, follow-up suggestion surface, action-chips widget |
| L4 Execution | `IntentDispatcher`, `OacpResultService`, `OacpResultReceiver.kt` | `RoutineRunner`, `RoutineStep`, `InterruptionController` |
| L3 Routing / Planning | `NluCommandResolver`, `CapabilityHelpService`, `EmbeddingNotifier` | `TurnPlanner`, `RoutinePlanner`, `LlmClient`, `LlmProvider` interface |
| L2 Memory | — | `MemoryStore` (SQLite), `Places`, `Preferences`, `LearnedWeights`, `VectorIndex` |
| L1 Sensing | — | `SenseBus`, `LocationService`, `PhoneStateService`, `MediaStateService`, `HarkForegroundService.kt` |
| Cross-cutting | — | `ConversationManager`, `Turn` models |

The takeaway: L3, L4, and L5 are substantially reusable. L1, L2, and the cross-cutting conversation manager are green-field. The scope of v2 is mostly new code, not refactors.

---

## Scenario walkthroughs

Four scenarios, mapped through the architecture. Each proves the architecture is sufficient for the user's stated vision.

### Scenario A — "turn on the flashlight"

Already works in v1. Keyword fast-path → OACP dispatch. v2 changes nothing. This is the 35% of traffic.

### Scenario B — "take a picture in 3 seconds"

- L3: `TurnPlanner` recognizes the utterance needs slot extraction; the embedding match identifies `camera.take_photo`.
- L3: encoder NER extracts `{delay_seconds: 3}` in ~50 ms. This is the v2 fix for the slot-fill problem v1 punts to a slow LLM.
- L4: `IntentDispatcher` fires the OACP camera capability with the extracted delay.

v1 today sends this case through a local generative LLM that takes ~28 seconds on mid-range Android. v2's encoder NER handles it in ~50 ms.

### Scenario C — "what's the weather"

Already works in v1. Embedding → OACP dispatch → async result → chat bubble. v2's change is presentation polish: render the structured `OacpResult` payload as a rich card rather than a TTS line.

### Scenario D — "start the work drive" (the architectural acceptance test)

This is the smallest scenario that exercises every layer. Walking through it step by step proves the architecture is complete.

1. **L3 TurnPlanner** matches the utterance against the user's stored routines via embedding search over the `routines` table. Finds `work_drive`.
2. **L2 Memory** reads `places.work` — the user's saved work coordinates.
3. **L4 RoutineRunner** starts the `work_drive` routine:
   - **Step 1**: L5 TTS says "starting work drive".
   - **Step 2**: L4 dispatches `nav.start_navigation` OACP capability (a *capability type*, not a package name) with `places.work` coordinates. The fulfiller is resolved from L2 `learned_weights` — the user's preferred map app.
   - **Step 3**: L4 arms a `LocationService.geofence(parking_lot_polygon, on_enter)` via L1. The polygon is read from L2 `places.parking_near_work`, or a "within 500m of destination" heuristic if the user hasn't explicitly saved one.
4. User drives to work. `HarkForegroundService` keeps L1 sensing alive.
5. Geofence fires → L1 emits `GeofenceEnterEvent` → L4 `RoutineRunner` advances to the next state → L5 TTS asks "Should I open the parking app?"
6. User: "yes". **L3 TurnPlanner** sees the `ConversationManager.activeTurn.kind == pending_routine_step_answer` state and routes the yes/no directly to the active routine rather than the general NLU path.
7. L4 dispatches the parking-app OACP capability. Parking app returns its capability help showing `parking.book_slot` requires `{duration}`.
8. L2 Memory provides `preferences.parking.usual_duration_hours = 8`. L5 asks "Do you want your usual 8 hours?"
9. User: "yes". L4 dispatches `parking.book_slot` with `{duration_hours: 8}`. Routine complete.

Every layer participated. Every cross-cutting concern fired. This is why the near-term plan names the `work_drive` routine as the architectural acceptance test if/when v2 implementation begins.

### Scenario E — "let's go home" + music + call interruption

Same shape as Scenario D, plus the interruption controller. The critical architectural implications:

- **Capability types, not app names.** "Pause music" dispatches `media.pause`, which any OACP media app can fulfill. The user's preferred music app is resolved from `learned_weights` at dispatch time.
- **InterruptionController** subscribes to `PhoneStateService` events. When `state == ringing`, it snapshots `(active_routine, active_media, active_nav)`, asks the user via L5, and on call-end restores the snapshot (music resumes).
- **ConversationManager turn state** must support `pending_interruption_answer` as a top-priority turn kind that pre-empts routine follow-ups — when a call is ringing, the routine's "Should I open the parking app?" prompt gets preempted by "You're getting a call, pick up?"

This scenario is where the routine engine, memory layer, sensing layer, and conversation manager all have to compose correctly. It's the full-stack test.

---

## Pre-mortem — what most likely goes wrong

The v2 architecture is ambitious. Known risks:

**Memory layer scope creep.** "While we're at it, let's also do contacts, calendar sync, episodic embedding, graph relationships, cross-device sync." Each sounds reasonable in isolation; together they turn memory from a 2-week project into a 2-month project. The v2 starting scope is four tables: `places`, `preferences`, `learned_weights`, `vector_index`. Everything else is a future phase.

**Routine engine reinvents Apple Shortcuts or Bixby Routines.** The differentiator is OACP + voice + memory + ambient triggers, not the routine graph itself. Keep the engine dumb: linear steps, wait-for-event branches, capability-type references. No visual editor. Ship one routine before writing a second.

**Cloud LLM costs balloon.** Hard daily and per-session caps. Cache LLM responses by `(normalized_transcript, context_hash)`. Log cost per turn. Alert the user when cap is approaching. Never send raw chat history to the LLM — send trimmed context + structured memory extract + active routine state only.

**Foreground service destroys battery.** The single biggest platform bet in this architecture. The mitigation is aggressive sensor duty cycling, per-sensor user opt-out, beta cohort before broad rollout, and an explicit battery-drain exit criterion before shipping.

**Privacy story collapses under user scrutiny.** A voice assistant that has `SYSTEM_ALERT_WINDOW`, a foreground service, and talks to the cloud looks exactly like surveillance malware if you don't handle it right. Mitigations: default-off cloud toggle, visible per-turn "cloud" badge in chat bubbles, explicit consent screen at first use, plain-language explainer ("what leaves the device"), a "clear memory" button that actually works, and a visible foreground-service notification that honestly says what's running.

**ChatNotifier becomes an even bigger god-object.** The `ConversationManager` has to come in as the orchestrator. Hark v1's `ChatNotifier` owns mic, STT, resolver, dispatcher, and result handling — that's too much. New logic goes to `ConversationManager`, `RoutineRunner`, and `InterruptionController`, never back to `ChatNotifier`.

**Phases get conflated.** Routine steps, interruption/resume, and multi-turn coreference are three separate state-machine problems. Conflating them into one "agent mode" phase is how this project takes six months instead of three.

**Encoder slot tagger (Phase 5 of a future v2 plan) fails.** No off-the-shelf encoder fits all of `<80 MB INT8 + Hindi/Punjabi + joint slot filling` — see `docs/vision/encoder-slot-filler-survey.md`. If the spike fails, cloud LLM stays as the slot-filling path, and Hark doesn't have a free-to-run local option for the hard cases. The mitigation is phase ordering: cloud LLM ships before the encoder spike, so the spike is allowed to fail safely.

---

## Decisions that would need to be made before v2 implementation starts

If a future session reopens v2 work, these are the things that need explicit user confirmation before any code is written. None of them should be decided in advance — they depend on what Hark v1 looks like by the time v2 is considered.

1. **Cloud LLM provider.** Anthropic, OpenAI, Google Vertex, Vercel AI Gateway, or BYOK-only? Each has different cost, privacy posture, and streaming support. Recommended starting point: an abstract `LlmProvider` interface with one concrete implementation, so switching providers later is a small change.
2. **Memory storage backend.** Drift (SQLite + compile-time SQL), Isar, raw sqflite, or JSON files? Drift is the leading candidate — compile-time SQL, null-safe, Dart-native query API, mature migration story.
3. **Routine definition format.** Declarative Dart DSL, YAML/JSON, or a visual editor? Declarative Dart is the recommended starting point: type-checked, refactorable, no parser to write.
4. **Background execution model.** Foreground service with transparent notification, or WorkManager periodic tasks? Foreground service is the only model that supports geofences + call state + media state continuously. WorkManager can't service Scenario D/E.
5. **Privacy posture for cloud escalation.** What's sent, what's logged, data retention, opt-in UX, which providers are acceptable. This is a product decision, not a technical one.
6. **The "no cloud in core resolution" rule** (`AGENTS.md:182`). Hark v1's working rules forbid cloud dependencies in the core resolution path. v2's cloud LLM escalation bends this rule. The honest update: "core resolution for discovered OACP actions must have a working *local* path. Cloud is a user-enabled fallback for the cases local cannot handle."
7. **Capability types vs package names in routines.** Routines reference `media.pause`, not `com.example.music.pause`. The fulfiller is resolved via the OACP capability registry + the user's learned preference from the memory layer.
8. **Hindi/Punjabi support strategy.** Not in the near-term plan per user direction (Hark v1 is English-only for now). If v2 re-opens multilingual support, the encoder slot filler survey's finding applies: no off-the-shelf encoder hits all three of <80 MB INT8 + Indic languages + joint slot filling. Cloud LLM is the realistic Indic path.

---

## Research inputs

The architecture in this doc is informed by several research passes done over prior Hark planning sessions:

- **`docs/plans/llamadart-migration-findings.md`** — Slice 0 quant benchmark on Moto G56 5G. Key finding: Qwen3 0.6B Q8_0 slot filling is hardware-bound at ~28 seconds per case on mid-range Android CPU. The bottleneck is compute on prompt processing, not bandwidth on weight loading, so no quant trick breaks the wall. This is the reason v2 pushes slot filling to encoder NER or cloud LLM — local generative slot filling is not a path forward on this hardware tier.
- **`docs/vision/encoder-slot-filler-survey.md`** — Track 2 research on encoder-only token classifiers (DistilBERT-multilingual-NER, IndicNER, GLiNER family) as a non-LLM slot extraction alternative. Conclusion: multiple viable candidates for English + European languages in the ~65-100 MB INT8 range, but no single model covers Hindi/Punjabi without DIY ONNX export and 140+ MB size. A multi-model stack is possible but doubles the deployment surface.
- **`temp/hotword-oss-framework-research.md`** (untracked) — prior research on wake word options. Conclusion: hardware DSP offload is impossible for unprivileged apps on stock Android (`CAPTURE_AUDIO_HOTWORD` is `signature|privileged`, Sound Trigger HAL audio explicitly excluded from the concurrent capture framework). The only realistic path is software wake word on AAudio MMAP + Silero-VAD + sensor gating, with measured ~1.4%/hour battery cost. Wake word is out of scope for both the near-term plan and for v2 — it gets its own planning session.
- **`ROADMAP.md`** — the authoritative roadmap. v2 is explicitly not on the near-term list; the near-term focus is load time, splash UX, and the overlay.

---

## When to reconsider v2

This doc should be revisited when **all of the following** are true:

- The near-term plan has shipped. Model load times feel fast, splash UX is polished, the overlay is working on real devices, wake word has had its own planning session and either shipped or been explicitly deferred.
- There is shipping data from Hark v1 about real user traffic. The traffic distribution table above is opinionated — if reality shows 90% of users only ever say "flashlight" and "timer", the v2 architecture is massive overkill. If reality shows 40% of commands are routine-like multi-step or memory-referring, v2 is mandatory.
- There is a concrete user problem that can't be solved within the current architecture. "I want Hark to do X" where X requires memory, routines, ambient triggers, multi-turn, or interruption handling. Without a specific blocking problem, v2 is speculative.
- The OACP ecosystem has grown enough that routines referencing capability types actually have fulfillers to pick from. If only three apps implement OACP, routines that say "play media" have no one to dispatch to.

When all four are true, open `~/.claude/plans/async-twirling-galaxy.md` and the original v2 drafts in `docs/plans/llamadart-migration-findings.md`, and start a fresh planning session with real shipping data. The architecture in this doc is a starting point, not a commitment — the specifics should change to reflect what was learned between now and then.

---

## What this doc is not

- It is **not** a commitment to build anything. It is a preserved record of architectural thinking.
- It is **not** a fully-specified design. Each layer would need its own detailed design doc before implementation.
- It is **not** a rejection of Hark v1. v1 is the foundation v2 builds on — embeddings for intent, OACP for actions, the resolver and dispatcher, async result handling. v2 adds layers; it does not replace them.
- It is **not** a cloud-first architecture. The claim is explicitly that 85% of traffic stays local and cloud is the rare escalation for the hard cases. Anyone reading this and worrying Hark is becoming a cloud assistant should read the traffic distribution table and the privacy pre-mortem.

---

## Acknowledgments

The research in this doc was done across several Hark planning sessions with Claude as a thinking partner. The first-principles toolbox, layered architecture, scenario walkthroughs, and pre-mortem all came out of those sessions. The hardware findings that killed local generative slot filling came from the Slice 0 benchmark work on real Moto G56 hardware. The encoder survey came from a dedicated research agent pass. All research sources are cited in the "Research inputs" section above.
