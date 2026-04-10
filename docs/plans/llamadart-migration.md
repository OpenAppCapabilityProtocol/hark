# llamadart migration + model benchmarking

**Branch**: `feat/llamadart-migration`
**Worktree**: `worktree-llamadart-migration/`
**Depends on**: nothing (starts from `main @ 06334b3`)
**Blocks**: Assistant overlay (#5 on roadmap), any plugin-specific debugging

## Why this plan exists

### The problem in one sentence

`flutter_embedder` does not use mmap, has no session cache, and blocks the main Dart isolate for the full duration of a ~250 MB ONNX load. `flutter_gemma` has MediaPipe lifecycle issues on Activity detach. Both are weak links compared to what the llama.cpp ecosystem has already solved. Our cold-start pain is almost entirely plugin-level, not model-level.

### Why fork-and-patch loses to migrate

Earlier iteration of this plan proposed forking `flutter_embedder` to add `memmap2` + a static session cache. That would work but costs us a plugin we maintain forever. Research on the two mature Dart-side llama.cpp bindings (`llamadart` and `llama_cpp_dart`) established that **`llamadart` already ships every architectural property we'd be trying to add by forking**:

- mmap by default (llama.cpp default)
- Isolate-based backend by default — native inference runs in a dedicated spawned isolate, the main UI isolate is never blocked
- Explicitly fixed hot-restart resource lifecycle in v0.3.0
- Prebuilt native binaries via Dart's `hook/build.dart` mechanism — no CMake, no NDK juggling, no `libllama.dylib` path management
- First-class embedding API (`LlamaEngine.embed` + `embedBatch`), tested with `embeddinggemma-300M-Q8_0.gguf` as the default example in the package's own bin
- 20+ chat templates auto-detected for Qwen, Gemma, ChatML, etc.
- 244 commits in the last 3 months — daily active maintenance
- MIT license

The honest choice is to delete `flutter_embedder` and `flutter_gemma` and use `llamadart` for both models. Smaller diff than forking, fewer plugins to maintain, and every architectural issue goes away as a side effect of dependency choice.

### What "measure" becomes in this version

The original "measure first, then optimize" framing was right about measurement. It was wrong about the target. In this version, measurement becomes a **quantization benchmark** across multiple GGUF builds of each model, producing a decision table that picks the file size vs accuracy sweet spot *empirically* instead of guessing. See Slice 0 below.

## The three axes we're optimizing

Every decision below trades off three things, in priority order:

1. **Correctness**. Slot-filling produces valid JSON and correct parameter values. Intent ranking returns the same top-1 as the current baseline for non-ambiguous utterances. This is the hard floor. A 5× faster model that gets 1 in 10 integers wrong is useless.
2. **Cold start perceived latency**. From process launch to "ready to accept commands" under 1 second on a Moto G56 5G, or at least hidden by the splash animation.
3. **File size on disk + download footprint**. Currently ~0.75–1 GB for both models. We want to stay at or below that; ideally lower.

## Slice 0 — Quantization benchmark (GATES everything)

**Deliverable**: `docs/plans/llamadart-quant-benchmark.md` — a decision table across 3 quantization levels for each model, with quality and performance numbers, and an explicit "ship this config" verdict.

**Nothing downstream starts until Slice 0 lands and the verdict is "proceed" or "proceed with embedder-only".**

### 0.1 — Model matrix

| Target | Candidate quants | Source | Rationale |
|---|---|---|---|
| EmbeddingGemma 300M | Q4_K_M (~236 MB), Q5_K_M (~260 MB), Q8_0 (329 MB) | `unsloth/embeddinggemma-300m-GGUF` primary, fall back to `admiralakber/embeddinggemma-300m-Q4_K_M-GGUF` and `ggml-org/embeddinggemma-300M-GGUF` for Q8_0 | Ranking task tolerates some drift because of confidence gating. Start small, escalate if quality regresses. |
| Qwen3 0.6B | Q4_K_M (~397 MB), Q5_K_M (~440 MB), Q8_0 (639 MB) | `unsloth/Qwen3-0.6B-GGUF` primary, fall back to `bartowski/Qwen_Qwen3-0.6B-GGUF` | Slot-filling is fragile on small models. Default bias toward higher quant. |

We test 3 quants per model × 2 models = **6 GGUF files** total on the bench. File sizes above are approximate; real sizes go in the results table.

Skipping Q3_K_S and lower — those regress too much on small models. Skipping F16 — too large to ship.

### 0.2 — Test harness

New Dart CLI tool at `tools/quant_bench/bin/quant_bench.dart` with:

- Dependencies: `llamadart`, `path`, `args` (CLI parsing), `collection`
- Input: a JSON config pointing to a model file + test cases + expected outputs
- Output: a JSON result document with per-case pass/fail, timing breakdown, summary stats
- Config discovery: one `embedding_test.json` and one `slot_fill_test.json` shared across all model runs

The harness is a standalone Dart tool, runs on **both macOS (for fast iteration)** and **Android via `adb` + a lightweight wrapper APK** (for the device numbers that actually matter). The macOS runs give us quality numbers fast; the device runs give us load and inference timing.

### 0.3 — Embedding quality test

**Gold set** — expand the 10-utterance suite from `project_embeddinggemma_test_results.md` to 20 pairs. Balance across:

- 5 exact-match cases (utterance contains the action alias verbatim): "turn on the flashlight", "pause the music", "scan this qr code", etc.
- 5 paraphrase cases (utterance is a semantic variant): "kill the lights", "stop playback", "take a photo of this barcode", etc.
- 5 disambiguation cases (utterance is ambiguous between 2+ actions): "next", "play", "cancel", "open", "settings" — the cases that currently hit the confidence gate
- 5 cross-app cases (same verb applies to multiple apps): "start recording" (voice recorder vs camera), "pause" (music vs video), etc.

Each case has `{ utterance, expected_actions: [<top-1>, <top-2 candidate if disambiguation>], must_not_rank_above: [<action that should be ranked lower>] }`.

**Metrics** per quant level:
- **Top-1 accuracy**: how many of 20 correctly ranked the expected action first
- **Top-3 recall**: how many of 20 had the expected action in top 3
- **Disambiguation coverage**: of the 5 disambiguation cases, how many had both acceptable candidates in top 3 with score gap < 0.05
- **Confidence gate trigger rate**: how many returned the top-1 above the 0.35 gate
- **Cosine score distribution**: mean + stddev of top-1 scores, to detect systematic confidence drift
- **Baseline parity**: for each case, is the top-1 the same as what `flutter_embedder`+ONNX q4 returns? This is the strictest comparison — we want to minimize rank flips.

**Pass criterion**: a quant passes if:
- Top-1 accuracy ≥ current baseline (currently 7/10 per memory, expanded to 14/20 on the new set)
- Disambiguation coverage ≥ current baseline
- Confidence gate trigger rate matches baseline ±10%
- No top-1 rank flips on the 5 exact-match cases

### 0.4 — Slot-filling quality test

**Gold set** — 15 (utterance, action_schema, expected_params) cases covering:

- 5 integer extraction: "set an alarm for 6am", "play track 3", "set volume to 70%", "scan the next 5 barcodes", "wait 30 seconds"
- 4 string extraction: "search wikipedia for ada lovelace", "set a reminder to buy milk", "call mom", "start a timer called morning run"
- 3 enum extraction: "switch to the front camera", "play music by shuffle order", "set language to spanish"
- 2 boolean extraction: "enable shuffle", "turn off repeat"
- 1 multi-parameter: "set a timer for 5 minutes called morning run"

Each case has `{ utterance, action_definition, expected: { param_name: value, ... } }`.

**Metrics**:
- **JSON validity**: how many of 15 produced parseable JSON
- **Exact-match accuracy**: how many extracted all expected parameters with exact values
- **Type-correct accuracy**: how many had all parameters in the correct type (even if value is wrong)
- **Required-field recall**: for cases with required params, how many had the required fields populated
- **Hallucination rate**: how many extracted values that were not present in the utterance

**Pass criterion**: a quant passes if:
- JSON validity ≥ 14/15
- Exact-match accuracy ≥ 12/15
- No hallucinations on the 5 integer cases (hallucinating a number is a severe failure mode)

### 0.5 — Performance test

For each quant, on the Moto G56 5G in release mode:

- **Cold load time (ms)**: `LlamaEngine.loadModel(path)` from fresh process start, measured with `Stopwatch`
- **Hot restart load time (ms)**: same call on second invocation within the same Android process (tests whether the llamadart isolate keeps the native model alive; should be near-zero if mmap is working)
- **Single query inference (ms)**: one `embed(text)` or `create(messages)` call, measured end-to-end
- **Peak resident memory (MB)**: read via `adb shell dumpsys meminfo com.oacp.hark` after load
- **File size on disk (MB)**: `ls -la` on the downloaded GGUF

On macOS in release mode for fast iteration:
- Same metrics, but for reality-checking before we touch device time

### 0.6 — Decision rubric

After the bench runs, produce this table in `docs/plans/llamadart-quant-benchmark.md`:

| Model | Quant | Size (MB) | Quality pass? | Cold load (ms) | Inference (ms) | RAM (MB) | Verdict |
|---|---|---|---|---|---|---|---|
| EmbeddingGemma | Q4_K_M | ? | ? | ? | ? | ? | ? |
| EmbeddingGemma | Q5_K_M | ? | ? | ? | ? | ? | ? |
| EmbeddingGemma | Q8_0 | ? | ? | ? | ? | ? | ? |
| Qwen3 0.6B | Q4_K_M | ? | ? | ? | ? | ? | ? |
| Qwen3 0.6B | Q5_K_M | ? | ? | ? | ? | ? | ? |
| Qwen3 0.6B | Q8_0 | ? | ? | ? | ? | ? | ? |

**Ship rule**: for each model, pick the **smallest quant that passes the quality gate**. If Q4_K_M passes, ship it. If Q4_K_M fails but Q5_K_M passes, ship Q5_K_M. If Q5_K_M fails, ship Q8_0. If Q8_0 fails on slot-filling, **stop and fall back to embedder-only migration** — keep `flutter_gemma` with its current `.litertlm` Qwen3 and migrate only the embedder.

**Expected outcome** (my prior, to be verified by data): EmbeddingGemma Q4_K_M passes cleanly, Qwen3 0.6B Q4_K_M passes on JSON validity but borderline on exact-match accuracy, Qwen3 0.6B Q5_K_M is the safer choice. Total expected footprint: ~236 MB + 440 MB = ~676 MB, smaller than current.

### 0.7 — Effort

- Harness setup: 2 hours
- Gold set authoring: 1 hour (pulling examples from existing OACP manifests)
- Downloading 6 GGUFs + running on macOS: 1 hour (of which ~40 min is download)
- Running on Moto G56 for the top candidates: 1 hour (device time)
- Writing the results doc: 30 minutes

**Total: ~5–6 hours of work before any migration code lands.**

## Slice 1 — Baseline instrumentation (no llamadart)

Runs **in parallel** with Slice 0. Independent of the benchmark harness. Can land first.

**Deliverable**: Stopwatch-wrapped `debugPrint('HarkLoadPerf: ...')` lines around every phase of the *current* load path in `lib/state/embedding_notifier.dart` and `lib/state/slot_filling_notifier.dart`. Plus a new `InferenceLogger.logModelLoad(phase, elapsedMs)` writing to `model_load_logs/`.

**Why still do this**: we need the current-state numbers to quote in the final writeup ("we went from X seconds to Y seconds"). Without baseline numbers, the win is unmeasurable.

**Phases instrumented** (same as in the previous plan iteration):
- `embedding.runtime_init`, `embedding.manager_init`, `embedding.cache_lookup`, `embedding.model_create`, `embedding.total`
- `slot_filling.runtime_init`, `slot_filling.has_active_check`, `slot_filling.model_open`, `slot_filling.total`
- `init.all_ready` aggregate

**Files touched**: 3. **Diff estimate**: ~80 lines of Stopwatch boilerplate.

**Success criterion**: on-device logs show every phase with a ms number, captured on cold start and hot restart. Numbers go into `docs/plans/llamadart-migration-baseline.md` as the "before" column.

## Slice 5 — Keyword / alias fast-path (no llamadart)

Runs **in parallel** with Slices 0 and 1. Independent of everything. Can land first.

Not a fix for the load-time problem directly; it's a bypass that makes the most common simple commands work *during* cold start before models are ready.

**File touched**: `lib/services/command_resolver.dart` (or wherever the two-stage resolver entrypoint lives — need to check the current structure).

**Logic**: before calling the embedding model, check if the normalized transcript matches any action's keyword list or alias list exactly. If it does, and the action has **no required parameters**, dispatch immediately without touching either model. Covers zero-parameter commands like "turn on flashlight", "pause music", "next track", "start recording", "scan qr code".

**Success criterion**: "turn on the flashlight" fires during the splash screen with `init.isReady == false`. Verified on device.

## Slice 2 — Migrate embedder from flutter_embedder → llamadart

**Prerequisite**: Slice 0 verdict says "proceed" or "proceed with embedder-only" on the embedder.

Rewrite `EmbeddingNotifier` in `lib/state/embedding_notifier.dart` to use `llamadart`'s `LlamaEngine` instead of `flutter_embedder`'s `GemmaEmbedder`. Keep the public API of the notifier identical so downstream callers (the `CommandResolver` and the registry's capability embedding path) don't change.

**Changes**:

1. `hark-release/pubspec.yaml`: add `llamadart: ^0.6.10`, remove `flutter_embedder`.
2. `EmbeddingNotifier._initialize()`:
   - Replace `initFlutterEmbedder()` + `ModelManager.withDefaultCacheDir()` + `GemmaEmbedder.create(modelPath, tokenizerPath)` with `LlamaEngine.create()` + `engine.loadModel(gguf_path, ModelParams(embeddings: true, ...))`.
   - Download the GGUF on first use via the notifier's existing download-progress path, pointing at the URL picked by Slice 0.
   - Update the `downloading` / `loading` / `ready` state transitions to match the new load lifecycle.
3. `EmbeddingNotifier.embedQuery()` / `embedDocument()`:
   - Implement our own `formatQuery` / `formatDocument` prompt templating for EmbeddingGemma (was done by `GemmaEmbedder.formatQuery` / `formatDocument` inside flutter_embedder). The templating is documented in the EmbeddingGemma model card.
   - Call `engine.embed(formatted_text, normalize: true)` instead of `embedder.embed([formatted])`.
4. Delete `flutter_embedder` references from `lib/state/embedding_notifier.dart`, `pubspec.yaml`, and any test files.
5. Update tests that mock `GemmaEmbedder` to mock `LlamaEngine` instead.

**Files touched**: `pubspec.yaml`, `embedding_notifier.dart`, 1–2 test files, possibly `services_providers.dart` if it references types from the old plugin.

**Diff estimate**: ~150 lines net (add llamadart calls, delete flutter_embedder calls).

**Success criterion**:
- App builds and launches.
- `EmbeddingNotifier` reaches the `ready` state.
- Existing embedding tests pass against llamadart.
- Slice 0's gold-set evaluation continues to pass when run against the *in-app* embedder instead of the bench harness.

## Slice 3 — Migrate slot-filler from flutter_gemma → llamadart

**Prerequisite**: Slice 0 verdict says "proceed" (not "embedder-only"). If Slice 0 said "embedder-only", this slice is skipped and `flutter_gemma` stays.

Rewrite `SlotFillingNotifier` in `lib/state/slot_filling_notifier.dart` similarly. A second `LlamaEngine` instance owns the Qwen3 0.6B model. Generation uses `engine.create(messages)` streaming back `LlamaCompletionChunk`s until we get a full JSON blob.

**Changes**:

1. `pubspec.yaml`: remove `flutter_gemma`.
2. `SlotFillingNotifier._initialize()`:
   - Replace `FlutterGemma.initialize()` + `FlutterGemma.installModel(...).fromNetwork(modelUrl)` + `FlutterGemma.getActiveModel(maxTokens: 512)` with `LlamaEngine.create()` + `engine.loadModel(qwen3_gguf_path, ModelParams(contextSize: 1024, ...))`.
3. `SlotFillingNotifier.extractParameters()`:
   - Replace `model.createSession(...)` + `session.addQueryChunk(...)` + `session.getResponse()` with `engine.create(messages: [LlamaChatMessage.user(prompt)])`, collect the token stream, assemble the full response, parse.
   - Port the existing `_buildPrompt()` and `_parseOutput()` logic untouched — those are schema-driven and don't care which runtime produced the text.
   - The `/no_think` directive at the start of the prompt should still work with Qwen3 base; llamadart's chat template auto-detection handles Qwen3's native prompt format.
4. Delete `flutter_gemma` imports, tests that mock it, etc.

**Files touched**: `pubspec.yaml`, `slot_filling_notifier.dart`, 1 test file.

**Diff estimate**: ~200 lines net.

**Success criterion**:
- App builds and launches.
- `SlotFillingNotifier` reaches the `ready` state.
- Slice 0's slot-filling gold set continues to pass when run through the in-app notifier.
- At least one real command-dispatch cycle works end-to-end on the device.

## Slice 4 — Warm engine via HarkApplication.onCreate

**Prerequisite**: Slices 2 and 3 landed (or Slice 2 alone if we took the embedder-only fallback).

Run both `LlamaEngine` instances in a dedicated Flutter engine hosted inside `HarkApplication.onCreate()` so model loads kick off before the splash renders.

**Changes**:

1. New `android/app/src/main/kotlin/com/oacp/hark/HarkApplication.kt`:
   ```kotlin
   class HarkApplication : Application() {
       override fun onCreate() {
           super.onCreate()
           val engine = FlutterEngine(this)
           engine.dartExecutor.executeDartEntrypoint(
               DartExecutor.DartEntrypoint(
                   FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                   "keepAliveMain",
               ),
           )
           FlutterEngineCache.getInstance().put("hark_warm", engine)
       }
   }
   ```
2. `android/app/src/main/AndroidManifest.xml`: add `android:name=".HarkApplication"` on `<application>`.
3. New `lib/main_keep_alive.dart`:
   ```dart
   @pragma('vm:entry-point')
   void keepAliveMain() {
       final container = ProviderContainer();
       container.read(embeddingProvider);
       container.read(slotFillingProvider);
       // Don't runApp — just keep the container alive.
   }
   ```
4. `MainActivity.kt`: override `getCachedEngineId()` to return `"hark_warm"`.
5. Verify with `adb logcat` that both providers' `_initialize()` methods run before `MainActivity.onCreate` is called.

**Gotcha risk**: if the warm engine's Dart isolate doesn't tick its event loop without `runApp`, the `Future.microtask` in the notifiers' `build()` methods may not fire. Mitigation: pump one tick explicitly via `await Future.delayed(Duration.zero)` before returning from `keepAliveMain`, or wrap the provider reads in an explicit `scheduleMicrotask` and hold a reference to the completion futures.

**Files touched**: 3 new, 2 modified.

**Diff estimate**: ~120 lines.

**Success criterion**: cold start measurement in Slice 6 shows model load overlapping with splash animation, i.e. `init.all_ready` fires within 1 frame of the first splash paint.

## Slice 6 — Re-measure and write up

Re-run the Slice 1 protocol with Slices 2+3+4 landed. Update `docs/plans/llamadart-migration-baseline.md` with a "post-migration" column alongside the "current baseline" column.

**Deliverable**: the baseline doc now has side-by-side numbers showing the win. Also a short "what we learned" paragraph covering anything surprising (e.g. "Qwen3 Q5_K_M was needed, Q4_K_M failed on enum extraction in 2/15 cases" or "warm engine slice saved a further 800ms on top of llamadart's natural win").

**Files touched**: 1. **Effort**: 30 min of device time + 30 min writing.

## Slice 7 — Roadmap flip + PR

- `ROADMAP.md`: flip `#4 Model Loading Performance` from `[-]` to `[x]`. Change `#5 Assistant Overlay` from blocked to `[-]`.
- `git push -u origin feat/llamadart-migration`, `gh pr create` with the migration summary.

**Files touched**: 1. **Effort**: 15 minutes.

## Parallelism, realistically

| Slice | Blocks on | Can run concurrently with |
|---|---|---|
| 0 (benchmark) | nothing | 1, 5 |
| 1 (baseline instrumentation) | nothing | 0, 5 |
| 5 (keyword fast-path) | nothing | 0, 1 |
| 2 (migrate embedder) | 0 verdict | — (serial from here) |
| 3 (migrate slot-filler) | 2 | — |
| 4 (warm engine) | 3 | — |
| 6 (re-measure) | 2+3+4+5 | — |
| 7 (roadmap + PR) | 6 | — |

**Concrete lanes**:
- **Lane A (me)**: Slices 0 + 1 + 5 as three independent commits, then 2 → 3 → 4 → 6 → 7 in sequence.
- **Lane B (you)**: device time for Slice 1 baseline numbers, device time for Slice 0 performance numbers, device time for Slice 6 post-migration numbers. Each device-time window is maybe 10–20 minutes.

**Wall-clock estimate if we interleave well**: 3 calendar days, ~5 dev-days of my work + ~1 hour of your device time, split across 3 device-time windows.

**Things that guarantee pain if we try to parallelize further**:
- Splitting Slice 2 and Slice 3 across branches (both touch pubspec.yaml, both touch adjacent state files, near-certain conflict)
- Starting Slice 4 before Slice 3 (warm engine would load the wrong plugin's models)
- Starting Slice 6 before Slices 2/3/4 are all merged (nothing to re-measure)

## Out of scope

- **Precompute capability embeddings at registry-refresh time**. Worth doing but larger scope. Push to Phase 4.
- **Forking llamadart**. We don't need to. If we hit something missing, file an upstream issue first.
- **Switching model families** (e.g. EmbeddingGemma → all-MiniLM-L6-v2). Correctness decision, not a performance one. Only revisit if Slice 0 shows quality regression even at Q8_0.
- **NPU / Hexagon DSP offload**. Still deferred in roadmap Future/Not Now.
- **Per-command inference latency**. Already instrumented; this plan covers load time only.

## Critical files

Read-only context:
- `hark-release/lib/state/embedding_notifier.dart` — the embedding side we replace
- `hark-release/lib/state/slot_filling_notifier.dart` — the slot-filling side we replace
- `hark-release/lib/state/init_notifier.dart` — aggregate ready watcher
- `hark-release/lib/services/inference_logger.dart` — gets a new `logModelLoad(phase, ms)` method
- `hark-release/lib/services/command_resolver.dart` — where Slice 5 lands
- `hark-release/pubspec.yaml` — dependency swap
- `hark-release/android/app/src/main/AndroidManifest.xml` — `<application android:name>`
- `hark-release/android/app/src/main/kotlin/com/oacp/hark/MainActivity.kt` — `getCachedEngineId()` override
- `temp/llamadart/` — source of truth for the llamadart API
- `temp/llamadart/example/basic_app/bin/llamadart_embedding_example.dart` — reference for embedding usage
- `temp/llamadart/example/chat_app/` — reference for generation + streaming usage

New / modified by this plan:
- New: `tools/quant_bench/bin/quant_bench.dart` (Slice 0 harness)
- New: `tools/quant_bench/gold/embedding_test.json` + `slot_fill_test.json`
- New: `docs/plans/llamadart-quant-benchmark.md` (Slice 0 results)
- New: `docs/plans/llamadart-migration-baseline.md` (Slice 1 + Slice 6 numbers)
- New: `hark-release/android/app/src/main/kotlin/.../HarkApplication.kt`
- New: `hark-release/lib/main_keep_alive.dart`
- Modified: everything listed in the "read-only context" block, except the research files in `temp/`.

## Verification gates

- **After Slice 0**: `docs/plans/llamadart-quant-benchmark.md` has a completed decision table with real numbers and an explicit verdict. If verdict is not "proceed" or "proceed with embedder-only", stop and rescope.
- **After Slice 1**: baseline numbers committed to `docs/plans/llamadart-migration-baseline.md`.
- **After Slice 2**: `flutter run` succeeds, an embedding query through the new notifier returns a plausible vector (dimension matches, nonzero, normalized).
- **After Slice 3**: a real voice command dispatched on-device. Slot-filling returns valid JSON matching the gold-set rubric.
- **After Slice 4**: `adb logcat` shows `HarkLoadPerf init.all_ready` firing inside the first frame post-splash.
- **After Slice 6**: the baseline doc has before/after columns, the delta is shown, and meets or beats the "under 1 second cold start" goal.
- **After Slice 7**: PR is open with the full writeup, roadmap flipped.

## Open questions for confirmation before I start Slice 0

1. **Quantization priority order.** Start Q4_K_M → escalate to Q5_K_M → escalate to Q8_0, stopping at the first pass? Or test all 3 to get the full trade-off curve? (Prefer the first approach — it's faster and the full curve isn't actionable.)
2. **Embedder-only fallback.** If Qwen3 Q8_0 fails the slot-filling gate, we keep `flutter_gemma` and only migrate the embedder. Approved as the fallback path?
3. **Gold-set authoring.** I can draft the 20 embedding utterances + 15 slot-fill cases from the existing OACP manifests in `real-examples/`, or you can supply them if you have a specific set you want to cover. Drafting them myself is faster; supplying them yourself catches your domain intuition.
