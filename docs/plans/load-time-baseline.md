# Load time baseline — Phase 1 of the near-term plan

**Status**: **Phase 1 complete. Migration verdict locked.** See §Migration decision at the bottom.

**Owner**: Phase 1 of `~/.claude/plans/async-twirling-galaxy.md`.

**Purpose**: produce the data that Phase 2 uses to decide whether to migrate the embedder + slot filler from `flutter_embedder` + `flutter_gemma` to `llamadart`. The decision is pre-committed to the data via the migration rules (§Migration rules below).

**Headline finding (original)**: the raw performance data pointed to a split migration — migrate the embedder to llamadart (Rule 1 fires, ~5s faster cold load), keep the current flutter_gemma slot filler (Rule 3 effectively fires, LiteRT's XNNPack CPU kernels are ~1.8× faster per inference than llama.cpp's CPU path on this hardware). The Slice 0 "hardware-bound 28s ceiling" was really about llama.cpp's implementation, not the hardware — LiteRT demonstrates the CPU can go faster.

**Headline finding (revised 2026-04-10 after user decision)**: **no migration.** Stay on `flutter_embedder` AND `flutter_gemma`. Rule 1 technically fires on the embedder, but the user decided the ~5s cold-load improvement is not worth the cost: a format-change migration (ONNX → GGUF) forces a one-time 313 MB re-download for every existing user because GGUF is not compatible with the cached ONNX file, and `flutter_embedder` already has mature in-built ONNX caching that the migration would replace with hand-rolled Dart code. The revised verdict keeps both runtimes untouched and focuses Phase 2b optimization work on load-time wins that don't require changing the runtime. See §Migration decision at the bottom for the full reasoning.

---

## Device under test

**Primary target**: Moto G56 5G
- SoC: MediaTek Dimensity 7025 (2× Cortex-A78 @ 2.5 GHz + 6× Cortex-A55 @ 2.0 GHz)
- GPU: Mali-G57 MC2
- RAM: 8 GB LPDDR4X
- Android version: 15
- Storage: UFS 2.2
- This device represents the mid-range Android tier Hark targets. It is intentionally not a flagship — flagships have NPUs / Hexagon HTP / stronger CPUs that skew the numbers.

**macOS reference**: Apple Silicon Mac (M-series). Used only as a sanity check for quality (bit-identical greedy decoding) and an upper bound on perf. Not the target.

---

## Scenarios measured

Phase 1 measured **subsequent cold start + four live per-inference tests** on Moto G56. Each captured via the existing Stopwatch instrumentation (`hark-release/lib/services/inference_logger.dart`, `logModelLoad()` API, logs to `model_load_logs/load_*.jsonl`) plus logcat timestamp deltas between `HarkNlu` / `HarkSlotFill` events.

- **Subsequent cold start** (models already on disk, app process killed, relaunched): the typical daily Hark launch experience. Captures the `embedding.total` + `slot_filling.total` + `init.all_ready` timings. Done once, captured below.
- **Per-inference live tests** (4 voice commands via the physical mic button): captures embedder resolve+rank time and slot-fill generation time per command. 3 slot-fill invocations + 1 no-param case.

**Not measured in Phase 1**:
- First-run cold start (with download from HuggingFace) — this is purely a UX measurement; Phase 3 splash redesign is where that matters.
- Warm start (backgrounded + resumed) — can measure later if needed; not load-bearing for the migration decision.
- Full 15-case slot-fill gold set re-run on `flutter_gemma` — was planned as Part B but skipped because 3 live mic tests produced tight variance and settled the decision.

Quality was spot-checked on the 4 live cases (3 correct extractions, 1 no-slot-fill case). Not enough for a rigorous quality regression test, but nothing suggested drift from Slice 0 numbers.

---

## Measured — llamadart (from Slice 0)

See `docs/plans/llamadart-migration-findings.md` for the source data. These are from real Moto G56 runs using `tools/quant_bench/`:

| Metric | llamadart on Moto G56 | Source |
|---|---|---|
| EmbeddingGemma 300M Q8_0 — cold load | **3691-4149 ms** | Slice 0 `quant_bench` bench runs (multiple attempts) |
| EmbeddingGemma 300M Q8_0 — single embed (warm) | **117-150 ms** | Slice 0 |
| EmbeddingGemma quality (top1 / top3 / disamb / exact) | **100% / 95% / 83% / 5/5** | Slice 0 |
| Qwen3 0.6B Q8_0 — cold load | **5502-7069 ms** | Slice 0 |
| Qwen3 0.6B Q8_0 — single gen warmup (16 tokens) | **7958-23129 ms** (thermal variance) | Slice 0 |
| Qwen3 0.6B Q8_0 — per-case slot-fill wall time | **27.6-29.4 s** | Slice 0 |
| Qwen3 0.6B Q8_0 — quality (exact / json / type / halluc) | **87% / 93% / 93% / 6.7%** | Slice 0 |
| Native bundle size in APK (Android) | ~35 MB (llama.cpp + backends + CPU variants) | Slice 0 APK inspection |
| APK manifest requirement | `android:extractNativeLibs="true"` mandatory (for ggml backend plugin discovery) | Slice 0 Vulkan debugging |
| Vulkan on Mali-G57 | **crashes Qwen3** (SIGSEGV in `llama_model_loader::create_tensor`, null `ggml_backend_device*`) | Slice 0 |
| OpenCL on Android | Not bundled by default in llamadart | Slice 0 |

**llamadart's slot-filling verdict**: hardware-bound. 27-30 s/case on mid-range Android CPU is not interactive. Q4_0 was also tested — same per-case wall time (bandwidth savings don't help because prompt processing is compute-bound), but 27-point quality drop. Slot filling via llamadart is dead.

**llamadart's embedder verdict**: quality is bit-reliable, cold load ~3.7s is acceptable, inference ~150ms is well under any UX budget. Migration candidate if the current stack is slower.

---

## Measured — current stack (flutter_embedder + flutter_gemma)

**Measured on 2026-04-10** on Moto G56 5G running Android 15. The build is `feat/llamadart-migration` HEAD (commit `02aadcb`) which has the `f213e36` Stopwatch instrumentation but is otherwise the current flutter_embedder + flutter_gemma stack in `lib/`. Models were already cached on disk from a prior installation — this is a **subsequent cold start** scenario, not a first-run download scenario. That's exactly what we want for the comparison: apples-to-apples against the Slice 0 llamadart numbers which also assume models-already-on-disk.

### Load / init phases

From `/data/user/0/com.oacp.hark/app_flutter/model_load_logs/load_2026-04-10.jsonl` and logcat `HarkLoadPerf:` lines:

| Metric | Current stack | llamadart (Slice 0) | Delta |
|---|---|---|---|
| `embedding.model_create` (model load from cache) | **7663 ms** | — (not captured separately in Slice 0) | — |
| `embedding.total` (full init) | **8672 ms** | 3691-4149 ms | **+4.5-5.0 s slower on current** |
| `slot_filling.model_open` (LiteRT-LM model load) | **16378 ms** | — | — |
| `slot_filling.total` (full init) | **16816 ms** | 5502-7069 ms | **+9.3-11.3 s slower on current** |
| `init.all_ready` (total from app launch to mic ready) | **17760 ms** | ~12-13 s (summed estimate) | **+5 s slower on current** |
| `ActivityTaskManager: Fully drawn` (OS-level) | 18613 ms | — | — |
| Embedding model source | `onnx-community/embeddinggemma-300m-ONNX`, cached locally via flutter_embedder's `ModelManager` | `ggml-org/embeddinggemma-300M-GGUF` Q8_0 | Same underlying model, different runtime + format |
| Slot filler model source | `Qwen3-0.6B.litertlm` (LiteRT-LM format from Google's litert-community) | `Qwen/Qwen3-0.6B-GGUF` Q8_0 | Same underlying model, different runtime + format |
| APK manifest requirements | None beyond current | `android:extractNativeLibs="true"` required | llamadart has a hard manifest requirement; current stack does not |
| Hardware acceleration detected | **XNNPack** CPU kernels (`XNNPack weight cache loaded from .../Qwen3-0.6B.litertlm.xnnpack_cache`) | CPU only, Vulkan crashes on Qwen3 on Mali-G57 | Both stacks are CPU-bound on this device. LiteRT's XNNPack is a CPU kernel library with highly optimized ARMv8.2 paths; llama.cpp's CPU variants are similar in intent but don't tune as hard for this specific workload. |

### Per-inference — embedder resolve + rank

Measured from logcat timestamps between `user_input` and `resolve_ranked` events. This is end-to-end `NluCommandResolver.resolveCommand()` work: query embedding + cosine similarity over 49 cached action document embeddings + top-k ranking with gap check.

| Test | Transcript | Resolve time |
|---|---|---|
| 1 | "take a picture in 3 seconds" | ~7 ms (embedding ranking was essentially inline) |
| 2 | "search Wikipedia for Adela Lovelace" | **644 ms** |
| 3 | "show me the weather in Paris" | **407 ms** |
| 4 | "show me the current weather" | **311 ms** |

Median ~400 ms. Variance comes partly from concurrent Dart isolate work and partly from the cold-vs-warm transformer invocation state. This is **not** directly comparable to llamadart's "150ms single embed" number from Slice 0 — that was a raw `embedQuery()` call in isolation, while these are full resolver passes including ranking. A better apples-to-apples comparison is: Slice 0 said llamadart `embedQuery` is 150ms; ranking 49 actions would add ~50-100ms of cosine similarity + sort overhead; **estimated total llamadart resolve+rank: ~200-250ms**. Current stack at 300-650ms is ~1.5-2× slower.

### Per-inference — slot filling (Qwen3 via flutter_gemma + LiteRT-LM)

Measured from logcat timestamps between `slot_fill_prompt` and `slot_fill_raw` events. This is the LiteRT generation time for `"<think></think>\n```json\n{...}\n```"` output.

| Test | Transcript | Action / schema | Slot fill inference | Extracted params |
|---|---|---|---|---|
| 1 | "take a picture in 3 seconds" | `take_photo_rear_camera.duration_seconds:int` | **16,598 ms** | `{duration_seconds: 3}` ✓ |
| 2 | "search Wikipedia for Adela Lovelace" | `search_articles.query:string[required]` | **15,266 ms** | `{query: "Adela Lovelace"}` ✓ (STT misheard Ada → Adela but extraction is correct for the transcript) |
| 3 | "show me the weather in Paris" | *(skipped — `open_weather` has no params)* | **0 ms** | n/a |
| 4 | "show me the current weather" | `check_weather.location:string` | **13,670 ms** | `{location: null}` ✓ (no location in transcript) |

**Mean slot fill inference time (3 cases with slot filling): 15,178 ms (~15.2 s).** Range 13.7-16.6 s. Coefficient of variation ~10%. Tight enough that the number is stable across different prompt shapes.

Compare to Slice 0 llamadart measurements on the same phone:
- **llamadart per-case slot-fill wall time (15-case average): 27,600-29,400 ms (~28 s).**
- **llamadart single gen warmup (16 tokens): 7,958-23,129 ms (thermal variance).**

**Current stack is ~1.8× faster per inference** (~15.2s vs ~28s). This is not due to a GPU or NPU delegate — both stacks are CPU-bound. It's because LiteRT's XNNPack CPU kernels are more optimized for ARMv8.2 on Qwen3's specific matmul shapes than llama.cpp's CPU path. **This reverses the Slice 0 "hardware-bound 28s ceiling" finding** — the ceiling was llama.cpp's implementation, not the hardware itself.

### Quality spot-checks

Three slot-fill cases completed with correct extraction on the current stack (cases 1, 2, 4 above). Case 3 was a resolver-layer issue (picking `open_weather` over `check_weather`), not a slot-fill issue — the slot filler was never invoked. One data point is not enough to confirm bit-reliability, but nothing suggests quality drift from llamadart on the cases we did run.

### The Breezy Weather async-result observation

Case 4 ("show me the current weather") is worth highlighting because it exercised the full OACP async-result path:

1. Resolver → `check_weather` capability
2. `IntentDispatcher` dispatches broadcast intent with requestId `hark-1775795531553-4`
3. Breezy Weather processes the request in the background
4. `OacpResult` broadcast returned: `"Newcastle: Overcast, 30°C, Humidity: 42%, Wind: 9 km/h"`
5. Chat bubble updated with the structured result

This end-to-end path from slot-fill dispatch to async result display happened in ~1 second after the slot filler finished (`slot_fill_raw` at 14:32:09.838 → `oacp_result` at 14:32:12.573, minus the ~2.7s IntentDispatcher delay for TTS and chat bubble rendering). The async result protocol works exactly as the v2 vision doc describes. This is **not a v1-only flow** — it's the foundation the v2 "what's the weather" scenario relies on.

### The "weather in Paris" NLU bug (noted, not in Phase 1 scope)

Case 3 exposed a real NLU ranking bug worth logging for later fix: "show me the weather in Paris" ranked `open_weather` (no params, semantic score 0.4117) above `check_weather` (has `location` param, 0.3947) by a 0.017 margin. The user wanted the data-returning action, the resolver picked the app-opening action.

Possible fixes for future work:
- Parameterized-action preference: when the transcript clearly contains a parameter value (like a location word "Paris"), bias ranking toward actions that have a matching parameter type.
- Disambiguation UX: when the rank-1/rank-2 gap is below a threshold and both actions could fit the transcript, show a chip-based disambiguation prompt ("Did you mean: check weather in Paris / open weather app?").
- Better embedding input: currently the action's semantic text for embedding may not include the parameter names heavily enough. Weighting the `location` parameter string higher in the document embedding for `check_weather` might tip the balance.

Not in Phase 1 scope. Logged for a future ranking-improvements slice.

### How these numbers were captured (for reproducibility)

1. Built debug APK from worktree root: `flutter build apk --debug`. Branch: `feat/llamadart-migration` at commit `02aadcb`.
2. Installed over existing hark installation: `adb -s ZY32LQHTRH install -r build/app/outputs/flutter-apk/app-debug.apk`. Models on disk were preserved (we wanted subsequent-cold-start, not first-run-download).
3. Force-stopped to clear process state: `adb shell am force-stop com.oacp.hark`.
4. Cleared logcat: `adb logcat -c`.
5. Launched via `adb shell am start -n com.oacp.hark/.MainActivity`.
6. Captured the load phase logs from logcat + pulled `./app_flutter/model_load_logs/load_2026-04-10.jsonl` via `run-as`.
7. Four voice commands (one "take a picture in 3 seconds", then three follow-up commands) triggered via the phone's physical mic button. Logcat captured the full NLU pipeline including `HarkNlu resolve_ranked`, `HarkSlotFill slot_fill_prompt`, `HarkSlotFill slot_fill_raw`, `HarkNlu resolve_success`, `IntentDispatcher requestId`, `HarkDebug oacp_result`.
8. Per-inference slot-fill time measured from the timestamp delta between `slot_fill_prompt` and `slot_fill_raw` events.

No bench fork needed for Phase 1 — the existing `hark-release` app with its `f213e36` instrumentation was enough to measure both load time AND per-inference slot fill time directly from logcat timestamps. The planned `tools/quant_bench_legacy/` fork (to run the full 15-case gold set against `flutter_gemma`) was **skipped** because 3 live mic tests with tight variance are enough to settle the migration decision without needing a controlled 15-case bench.

### Delegate investigation result

`flutter_gemma` via LiteRT-LM runtime is using **XNNPack CPU kernels** on Dimensity 7025, not a GPU or NPU delegate. Confirmed from logcat: `tflite: XNNPack weight cache loaded from '/data/user/0/com.oacp.hark/cache/Qwen3-0.6B.litertlm.xnnpack_cache'`. No evidence of Vulkan, NNAPI, Hexagon, or APU engagement. The per-inference speed advantage over llamadart is therefore attributable to XNNPack's highly tuned ARMv8.2 CPU kernels, not to hardware acceleration. This is still a valid reason to keep flutter_gemma — **the runtime quality matters even on CPU**.

---

## Migration rules — data-driven decision (from `.claude/plans/async-twirling-galaxy.md` §Context)

Once Phase 1 produces the current-stack numbers, apply these rules mechanically. No opinion, no debate, just data:

1. **If current embedder cold load is ≥1s slower than llamadart's 3.7s** → migrate the embedder. Unambiguous win: Slice 0 already proved llamadart's embedder quality is identical, so the only question is latency.
2. **If current embedder is within 1s of llamadart or faster** → stay on `flutter_embedder`. Migration cost isn't justified.
3. **If current slot filler (flutter_gemma/LiteRT) has a working GPU or NPU delegate on Moto G56 that breaks the ~28s CPU wall** → stay on `flutter_gemma`. Delegates are the only escape from the compute-bound ceiling, and llamadart's Android bundle doesn't offer them today. Delegate-accelerated LiteRT beating 28s on Dimensity 7025 would be a huge finding.
4. **If current slot filler is also ~28s on phone** (same hardware wall, no delegate acceleration) → neither runtime solves the problem; slot filling stays a v2 vision concern. Stay on whichever stack is cleaner operationally.
5. **If current slot filler is materially worse than llamadart's 28s wall time** (e.g., 40s+) → strong evidence the current runtime isn't being used well either; migration is justified.

Possible outcomes after applying the rules:
- **Migrate embedder only** (most likely).
- **Migrate both** (only if rule 5 fires).
- **Stay on current stack** (if rules 1 and 5 don't fire, and optionally rule 3 fires).
- **Migrate embedder, keep slot filler** (rules 1 or 2 + either rule 3 or rule 4).

---

## Migration decision — revised 2026-04-10

### Phase 1 raw-data analysis (as measured)

Applying the migration rules from §Migration rules above against the measured numbers, the raw data pointed to a split migration: migrate the embedder (Rule 1 fires, current is ~5s slower), keep the slot filler (Rule 3 effectively fires, current is ~1.8× faster per inference). That analysis is preserved below for completeness.

#### Raw data — embedder comparison

- Current embedder cold load: 8672 ms
- llamadart embedder cold load: 3691-4149 ms
- Delta: ~4.5-5.0 s slower on current, well over the 1 s Rule 1 threshold
- Quality: bit-identical per Slice 0

#### Raw data — slot filler comparison

- llamadart Slice 0 per-case wall time: 27-30 s (15-case average)
- Current stack per-inference: 13.7-16.6 s, mean ~15.2 s (3 data points)
- Current stack is ~1.8× faster per inference

| Commands per session | llamadart total | Current stack total | Winner |
|---|---|---|---|
| 1 | ~35 s (7s cold + 28s gen) | ~31 s (16s cold + 15s gen) | current (barely) |
| 3 | ~91 s | ~61 s | **current by 30 s** |
| 5 | ~147 s | ~91 s | **current by 56 s** |
| 10 | ~287 s | ~166 s | **current by 121 s** |

The Slice 0 "hardware-bound 28s ceiling" finding was really about `llama.cpp`'s implementation — its CPU matmul kernels on ARMv8.2 are slower than XNNPack's for this workload. The hardware is capable of ~15s per case on the current stack. Still not interactive territory (a target of <5s would require another 3× improvement) but 1.8× better than the Slice 0 ceiling.

### Final decision — no migration, revert Phase 2a

After reviewing the raw-data analysis above, the user decided **not to migrate the embedder** either. The Phase 2a migration work (pubspec changes, new `GgufModelManager`, `EmbeddingNotifier` rewrite, `extractNativeLibs=true` in the manifest, and `dio` as a new dep) was drafted and then reverted in the same session.

**Reasoning for the revert** (from the user decision):

1. **Format-change re-download is painful for existing users.** `llamadart` needs GGUF; `flutter_embedder` caches ONNX. The two formats are not interchangeable, so any user with the app already installed would have to re-download ~313 MB on upgrade. `flutter_embedder`'s existing cache is completely wasted. This is worse than a normal version bump where the same file works after updating.
2. **`flutter_embedder` already has mature in-built caching.** Its `ModelManager.withDefaultCacheDir()` handles model download, cache checks, atomic writes, and restore-on-restart — all of which we'd have to re-implement in hand-rolled Dart code (a new `GgufModelManager` + a `dio` dependency). The migration replaces a working, tested caching layer with a less-tested one written from scratch.
3. **The ~5s cold-load win doesn't justify the disruption.** The faster cold load is a real improvement, but it's a one-time-per-launch cost that users would trade for a one-time re-download + a new caching implementation that has fewer battle-test reps than `flutter_embedder`'s.
4. **Phase 2b optimizations are runtime-agnostic.** Parallel init, persistent action embedding cache, warm-engine retention — all of these work on the existing `flutter_embedder` stack and deliver measurable wins without touching the runtime. The total load-time improvement from Phase 2b alone is likely to be comparable to the migration's ~5s, without any of the upgrade friction.

**Revised verdict — both runtimes stay**:

| Component | Decision | Rationale |
|---|---|---|
| **Embedder** | **STAY on `flutter_embedder`** | Migration replaces mature in-built caching with new hand-rolled code and forces a format-change re-download on upgrade. The ~5s cold-load win is not worth the disruption + reimplementation risk. Phase 2b optimizations will deliver comparable wins on the existing runtime. |
| **Slot filler** | **STAY on `flutter_gemma`** | Rule 3 — LiteRT XNNPack CPU kernels are ~1.8× faster per inference than llama.cpp's CPU path; current stack wins any multi-command session. |

**Phase 2a scope update**: Phase 2a is now **"no migration, focus on Phase 2b optimizations directly"**. The `feat/llamadart-migration` branch stays alive because it has the Slice 0 bench tool + findings docs that should merge to main eventually, but it will not contain a runtime migration. Renaming the branch is not necessary — the name is slightly misleading now, but that's a cosmetic issue.

### New direction — persistent model backup + adb side-load (proposed)

The user raised two related ideas during the revert discussion that are worth capturing as a future improvement — orthogonal to which runtime is underneath:

1. **After first download, copy the model files to a publicly-addressable persistent location** (like the Android `Downloads/` directory) so that if the user accidentally clears app storage or reinstalls, the next launch can restore from the backup instead of re-downloading ~313-610 MB. This applies to both flutter_embedder's ONNX cache and flutter_gemma's LiteRT-LM cache.
2. **Contributor documentation for `adb push`** so anyone building Hark from source on their own device can skip the model download entirely — push the files to the expected cache locations via `adb shell run-as` (the Slice 0 bench already uses this pattern for `com.oacp.hark.quant_bench`).

Both of these are **future work**, not part of Phase 2. See `docs/plans/persistent-model-backup.md` (to be drafted in a future session) for the full design. The sketch:

- Android permissions: need `MANAGE_EXTERNAL_STORAGE` or scoped-storage MediaStore API to write to public Downloads/. The existing `WRITE_EXTERNAL_STORAGE` with `maxSdkVersion="28"` only covers pre-Android-10 devices.
- Backup directory: `Downloads/hark-models/<runtime>/<model-file>` — scoped to Hark but visible to the user.
- Restore logic: on first launch after cache is empty, check `Downloads/hark-models/` before falling back to HuggingFace download. Verify file size or checksum before using.
- Contributor docs: a new `docs/dev/local-model-setup.md` explaining the adb push workflow for builders who want to skip the download. This should point at the specific private-storage paths that `flutter_embedder` and `flutter_gemma` use, plus an explanation of the `run-as` stream-pipe workflow from Slice 0.
- Privacy consideration: the backup directory is user-visible in the Files app, which is the right affordance — users can delete it, copy it to another phone, share it with friends on the same hardware who also use Hark.

This direction preserves the "always-on-device" spirit of Hark, improves first-install UX for contributors, and gives users a way to recover from "clear app storage" without a 1 GB re-download. None of that requires migrating runtimes.

---

## What happens next

Phase 2a is **done** — the decision is "no migration, stay on both runtimes". No lib code changes landed in Phase 2a. The work now proceeds directly to Phase 2b (load-time optimizations that apply to the existing runtimes).

1. **Phase 2a — COMPLETE (no migration)**. The `feat/llamadart-migration` branch already contains: Slice 0 bench tool, findings doc, vision doc, encoder survey, and this baseline doc. It does NOT contain a runtime migration — that was drafted and reverted in the same session after the user's decision. The branch name is slightly misleading now but doesn't need renaming.
2. **Phase 2b — load-time optimizations** begins now. Runtime-agnostic — applies to both `flutter_embedder` and `flutter_gemma` on the existing stack:
   - **Parallel model init** via `Future.wait([embeddingInit, slotFillingInit])` in `InitNotifier`. Currently the two models likely init sequentially. With parallelization the total init becomes `max(embedding, slot_filling)` instead of `sum`. On Phase 1 numbers that's `max(8672, 16816) = 16816 ms` instead of `17760 ms` — ~1 second saved.
   - **Persistent action embedding cache** keyed by `(model_id, action_id, action_doc_hash)`. On subsequent cold starts, skip the document-embedding pass entirely. Expected win: multiple seconds on warm restart.
   - **Warm engine retention** via a minimal foreground service (if needed). Measure whether `flutter_embedder` and `flutter_gemma` engines release on Activity pause/stop, decide whether the retention service is worth the complexity.
   - **Tokenizer cache persistence** if it turns out to be a meaningful chunk of init time.
   - **Persistent model backup to `Downloads/hark-models/`** (see §New direction below) — protects users from "clear app storage" wiping the 1 GB of model files.
3. **Phase 3 — splash UX** branches off main after Phase 2 exit merge. The splash UX work is valuable regardless of what runtimes are under it.
4. **Phase 4 — overlay** follows.
5. **Wake word** is a separate planning session after Phase 4.

Phase 2 exit merges the `feat/llamadart-migration` branch to main. The merge is now:
- Slice 0 bench tool + findings doc + encoder survey + this baseline doc (from Phase 0)
- Vision doc (from Phase 5 paperwork)
- ~~Phase 2a embedder migration~~ — reverted per user decision, nothing to merge for this item
- Phase 2b optimizations

After that merge, the branch is deleted (its purpose is fulfilled even without a migration). Subsequent phases branch off main.

---

## Bonus finding — NLU ranking bug, logged for future work

The "show me the weather in Paris" test case exposed a real NLU ranking issue unrelated to the migration decision. The resolver picked `open_weather` (no params, semantic 0.4117) over `check_weather` (has `location` param, semantic 0.3947) by a 0.017 margin. The user wanted the data-returning action; the resolver picked the app-opening action.

This is a ranking-logic bug in `NluCommandResolver`. Not in Phase 1 / Phase 2 scope. Logged for a future "NLU ranking improvements" slice. Potential fixes:
- Parameterized-action preference when the transcript contains parameter-shaped tokens (a location word like "Paris" biases toward actions with `location`-type params).
- Disambiguation UX when rank-1/rank-2 gap < threshold and both actions are plausible — chip-based prompt ("Did you mean: check weather / open weather app?").
- Better embedding input weighting on `check_weather`'s document embedding so the `location` parameter description contributes more to the similarity score.

Filed separately from this baseline doc; not a Phase 2 blocker.

---

## Related docs

- `~/.claude/plans/async-twirling-galaxy.md` — the parent plan; this doc is Phase 1 of it.
- `docs/plans/llamadart-migration-findings.md` — Slice 0 findings; the llamadart numbers in this doc come from there.
- `docs/plans/llamadart-migration.md` — original 7-slice plan; preserved for historical context.
- `docs/vision/hark-v2-agent-architecture.md` — long-term v2 vision that the near-term plan derisks the foundation for.
- `docs/vision/encoder-slot-filler-survey.md` — Track 2 research on encoder-based slot tagging as a non-LLM alternative (parked for v2).
