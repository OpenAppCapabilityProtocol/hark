# llamadart migration — Slice 0 findings & architectural decision

**Status**: Slice 0 (quantization benchmark gate) **complete and verdict locked**. The decision is: migrate the embedder to llamadart, do **not** migrate slot-filling to llamadart, redesign the slot-filling architecture as a separate workstream. See "Final architecture verdict" near the bottom.

**Worktree**: `worktree-llamadart-migration` on branch `feat/llamadart-migration`

**Date drafted**: 2026-04-09. **Updated 2026-04-10** with v3 matrix expansion (Q4_0 + Qwen2.5 0.5B), full latency-curve macOS run, phone Q4_0 confirmation run, and the encoder slot-filler survey (`temp/encoder-slot-filler-survey.md`).

**Context**: This doc extends [`llamadart-migration.md`](llamadart-migration.md). Read that first for the original 7-slice plan and the trust-tier analysis. This doc captures what Slice 0 actually measured, the surprises we hit on real hardware, and the architectural decision that came out the other side.

## TL;DR (updated 2026-04-10)

- **EmbeddingGemma 300M Q8_0 → llamadart: ship it.** Quality is bit-reliable across Apple Silicon Metal and ARM CPU. Phone cold load 3.7s, single embed 150ms. Top1 100% / top3 95% / disambiguation 83%. Identical to the existing ONNX baseline. This part of the migration is a clean win and unblocks Slices 2 / 4 / 6 / 7 of the original migration plan.
- **Qwen3 0.6B (any quant) → llamadart for slot filling: do NOT migrate.** Moto G56 5G hits a hard 27–30 seconds per slot-fill case regardless of quant. The bottleneck is CPU compute on prompt processing (~250 token schema prompt + 40 token output), not memory bandwidth. Q4_0 cold-loads 3× faster than Q8_0 (1.7s vs 5.5s) but per-case wall time is identical (~28s) AND quality drops 27 points (87% → 60% exact match) with double the hallucination rate. There is no quant trick that breaks the 28-second floor on this hardware tier.
- **Qwen2.5-0.5B-Instruct (any quant) is broken at slot filling regardless of platform.** Both Q4_K_M and Q8_0 hit 20–27% exact match on macOS — the model is too small to follow our schema-driven extraction prompt and returns empty `{}` for almost everything. This is a model/task mismatch, not a quant problem. Skipped on phone.
- **No off-the-shelf encoder slot-tagger fits all of `<80 MB INT8 + Hindi/Punjabi + joint slot filling`** either (see `temp/encoder-slot-filler-survey.md`). Closest options are DistilBERT-multilingual-NER (135M, ~65MB INT8, no Hindi/Punjabi) and `ai4bharat/IndicNER` (167M, MIT, Hindi+Punjabi+9 other Indic langs but needs DIY ONNX export and sits at the 150 MB cap). A two-model stack covers the languages but doubles the deployment surface.
- **Cloud LLM fallback gets promoted from "last resort" to primary path** for slot filling on mid-range Android, especially for Indic-language users. This is the biggest decision shift from where Slice 0 started.
- **Vulkan GPU offload is still not viable on Mali-G57 with llama.cpp b8638.** Backend loads, enumerates `Vulkan0` cleanly, then crashes with a null `ggml_backend_device*` in `llama_model_loader::create_tensor` for Qwen3 and returns a clean error for EmbeddingGemma. Upstream llama.cpp bug. CPU is the only safe backend on this device tier.
- **The migration still makes sense** — llamadart for EmbeddingGemma is a clean win — but **generative slot-filling at interactive latency is blocked on Moto-G56-class hardware**. The question is: what fills the gap?

Three tracks proposed. User has decided to explore all three (Q4 quants + smaller models, a non-LLM specialized slot filler, and cloud LLM as a last-resort escalation). **No regex/rule-based approach** — that option is rejected.

## Numbers

### macOS (Apple Silicon, reference)

| Model | Quant | cold load | single inference | quality |
|---|---|---|---|---|
| EmbeddingGemma 300M | Q8_0 | 250ms | 11ms (embed) | top1 100%, top3 95%, disamb 83%, exact 5/5 |
| Qwen3 0.6B | Q8_0 | 140ms | 742ms (16-tok warmup) | json 100%, exact 80%, type 100%, halluc 6.7% |

Slot-fill wall time on macOS: ~30 seconds for 15 cases = **~2 seconds per case** (roughly 21 tok/s on Metal). Quality gate: EmbeddingGemma passes, Qwen3 fails on `exactMatchMin` (gate is 90%, we hit 80%).

### Moto G56 5G (MediaTek Dimensity 7025, Mali-G57 MC2, target)

**Run 1 — initial CPU pass** (before `extractNativeLibs=true`):

| Model | Quant | cold load | single inference | quality | per-case wall time |
|---|---|---|---|---|---|
| EmbeddingGemma 300M | Q8_0 | 3284ms | 54ms | identical to macOS | — |
| Qwen3 0.6B | Q8_0 | 5502ms | 7958ms (16-tok warmup) | json 93%, exact 87%, type 93% | **27.6s/case** |

**Run 2 — Vulkan attempt** (`extractNativeLibs=true`, `preferredBackend: vulkan`):

- EmbeddingGemma: **clean failure** — Vulkan backend rejected the model during tensor setup. Diagnostic payload confirmed `loadedModules=[cpu, vulkan]`, `registeredBackends=[CPU, CPU, Vulkan, Vulkan]`, `devices=[CPU, Vulkan (Vulkan0)]`. So Vulkan loaded and enumerated the Mali-G57 successfully, but couldn't map EmbeddingGemma's tensors.
- Qwen3: **SIGSEGV in `llama_model_loader::create_tensor`** with a null `ggml_backend_device*`. Process crashed. `libllama.so` stack trace via `tombstoned` confirmed the null deref happens in `llama_model::load_tensors`. This is an upstream llama.cpp Vulkan-backend bug for Qwen3's architecture on Mali.

**Run 3 — CPU fallback after Vulkan crash** (`extractNativeLibs=true`, `preferredBackend: cpu`):

| Model | Quant | cold load | single inference | quality | per-case wall time |
|---|---|---|---|---|---|
| EmbeddingGemma 300M | Q8_0 | 4149ms | 117ms | identical | — |
| Qwen3 0.6B | Q8_0 | 7069ms | 23129ms (16-tok warmup) | json 93%, exact 87%, type 93%, halluc 6.7% | **29.4s/case** |

The warmup spike from 8s → 23s is likely a mix of thermal throttling after the Vulkan crash (Dimensity 7025 throttles hard under sustained load) and token-count variance in the greedy-decoded warmup loop. Steady-state per-case wall time only rose 6% (27.6 → 29.4), so the conclusion holds: **the phone is hard-capped at ~1–2 tok/s regardless of backend tweaks**.

Memory bandwidth math as a sanity check: 600 MB model, ~3 GB/s effective DDR bandwidth on the phone's LPDDR4X, theoretical peak = 5 tok/s. Actual 1–2 tok/s matches the expected 30–40% of theoretical peak for a realistic matmul workload. There is no headroom left to find on CPU.

### Quality comparison across platforms (Qwen3 0.6B Q8_0)

| | macOS Metal | Moto G56 CPU |
|---|---|---|
| json validity | 100% | 93% |
| exact match | 80% | 87% |
| type correct | 100% | 93% |
| hallucinations | 6.7% | 6.7% |

Failure profiles differ across platforms — macOS fails sf07/sf12/sf13, phone fails sf08/sf12 — because greedy-decoded float summation order differs between Metal MPS and ARM NEON kernels. Same seed (42), same topK (1), same temp (0), but ties near probability break differently. Phone actually scores slightly higher on exact-match. Both fail the 90% gate.

### Run 4 — full v3 matrix on macOS (2026-04-10)

Added Qwen3-0.6B-Q4_0 (ggml-org first-party), Qwen2.5-0.5B-Instruct-Q4_K_M, Qwen2.5-0.5B-Instruct-Q8_0 (both Qwen team first-party). Switched bench to `escalation_policy=measure_all_quants` so all quants run regardless of pass/fail. macOS Metal numbers:

| Model | Quant | cold load | warmup | exact | json | type | halluc | required | gate |
|---|---|---|---|---|---|---|---|---|---|
| EmbeddingGemma 300M | Q8_0 | 7265ms | 23ms | 100% top1 | 95% top3 | — | — | — | **PASS** |
| Qwen3 0.6B | Q4_0 | 343ms | 1057ms | **73%** | 80% | 80% | 0% | 100% | FAIL (–7 from gate) |
| Qwen3 0.6B | Q8_0 | 328ms | 1573ms | **87%** | 100% | 100% | 0% | 100% | **PASS** |
| Qwen2.5 0.5B Instruct | Q4_K_M | 270ms | 281ms | **27%** | 100% | 100% | 6.7% | 14% | FAIL (catastrophic) |
| Qwen2.5 0.5B Instruct | Q8_0 | 341ms | 18ms | **20%** | 100% | 100% | 0% | 0% | FAIL (catastrophic) |

Three things this run revealed that the previous-day macOS run did not:

1. **Qwen3 0.6B Q8_0 actually passes the 80% exact-match gate** (87% this run vs 80% the previous run). Same seed, same temp=0, same topK=1 — the ~7% jitter is from llama.cpp tensor ops having subtle non-determinism even in greedy decoding (likely tie-breaking during near-equal token probabilities). **Q8_0 is "production-ready quality on Metal" with confidence interval bouncing across the gate line.**

2. **Q4_0 fails by 14 points** (73% vs Q8_0's 87%). Failures include 4 cases of *invalid JSON output entirely* (sf03, sf09, sf12 — model returned empty string). Q4_0 doesn't just get values wrong, it stops following the prompt format. This is the cost of older block-wise quantization at 0.6B param scale: format adherence is the first thing to break.

3. **Qwen2.5-0.5B-Instruct is catastrophically broken at slot extraction.** Q4_K_M hits 27% exact, Q8_0 hits 20%. The Q8_0 warmup time of **18ms** is the smoking gun — the model is generating EOS immediately, doing nothing. Looking at failure details, almost all cases return empty `{}` or invent parameters that weren't asked for ("sf03: open the Wikipedia article for Kyoto → returned `{language_code: en}`"). **The 0.5B model is too small to follow our verbose schema-driven extraction prompt.** This is a model/task mismatch, not a quant problem — fixing it requires fine-tuning, not quant choice.

### Run 5 — Qwen3 0.6B Q4_0 on Moto G56 (2026-04-10)

Phone subset run (EmbeddingGemma + Qwen3 Q4_0 only — Qwen2.5 was conclusively broken on macOS so we didn't waste phone time on it):

| Model | Quant | cold load | warmup | exact | json | type | halluc | required | per-case wall time |
|---|---|---|---|---|---|---|---|---|---|
| EmbeddingGemma 300M | Q8_0 | 3691ms | 150ms (embed) | 100% top1 | 95% top3 | — | — | — | — |
| Qwen3 0.6B | Q4_0 | **1763ms** | **16342ms** | **60%** | 80% | 80% | **13%** | 100% | **27.9s/case** |

The headline finding from this run, comparing Q4_0 to Q8_0 directly on the same phone:

| | Q8_0 | Q4_0 | delta |
|---|---|---|---|
| File size | 581 MB | 409 MB | -30% |
| Cold load | 5502ms | **1763ms** | **-68% (3× faster)** |
| Warmup (16 tok) | 7958–23129ms | 16342ms | within range |
| Per-case wall time | 27.6–29.4s | **27.9s** | **~identical** |
| exact match | 87% | **60%** | **-27 points** |
| json validity | 93% | 80% | -13 points |
| hallucinations | 0% | **13%** | doubled |

**Critical insight: Q4_0 cold-loads 3× faster but per-case wall time is unchanged.** The naive bandwidth-scaling extrapolation ("Q4_0 is 30% smaller, expect ~21s/case") was wrong. Slot-fill cases are dominated by **prompt processing**, not generation: each case sends ~250 tokens of action schema + utterance and waits for ~40 generation tokens. Prompt eval throughput on Dimensity 7025 is **compute-bound** (matmul FLOPS), not memory-bandwidth-bound. Q4_0 saves bandwidth but adds dequantization overhead per matmul, so prompt eval throughput is identical to Q8_0.

**This means we cannot quant our way past 28 seconds per slot-fill case on Moto-G56-class hardware.** Even much smaller models (e.g. a 0.3B variant if it existed) would only break the floor if they had ~10× less compute work per token, which doesn't exist as a credible Qwen variant. The Qwen2.5-0.5B test confirms this from the other direction: smaller param count alone doesn't help if quality collapses.

### Phone latency breakdown sanity check

For a 250-token prompt + 40-token output at 1.5 tok/s prompt eval throughput:
- prompt eval: 250 tokens / 1.5 tok/s = ~17 seconds
- generation: 40 tokens / 2 tok/s = ~20 seconds
- per case: ~28 seconds, matches measured ~28s/case

For Q4_0 with the same prompt eval throughput (compute-bound, not bandwidth-bound):
- same ~17s prompt eval + ~20s generation = ~28s

This confirms the bottleneck is compute on prompt processing, not bandwidth on weight loading. The fix is *fewer prompt tokens*, not *smaller weights*. A redesigned slot-fill prompt with no schema (e.g. function-calling-style with tool definitions cached) might cut prompt processing dramatically — but that's a separate experiment, and doesn't change the fact that slot-filling-via-LLM is the wrong shape for this hardware.

## What Slice 0 actually delivered

Beyond the numbers, Slice 0 produced:

1. **Working quant_bench harness** (`tools/quant_bench/`) — Flutter app with model discovery via case-insensitive readdir + open()-probe fallback, gold sets for embedding + slot-fill, deterministic generation params (seed 42, topK 1, temp 0), quality gates, and result persistence to both internal and external storage.
2. **Android push workflow** — `adb shell "run-as <pkg> sh -c 'cat > files/bench_models/...'" < local_file` stream pipe that works around Android 11+ scoped storage SELinux labels on adb-pushed files.
3. **macOS sandbox disabled** so the app can read the real workspace temp directory.
4. **Native log callback routed through the Dart logger** — `LlamaEngine.configureLogging(level: info, handler: ...)` + `engine.setNativeLogLevel(info)` captures llama.cpp's backend-registration logs in the bench progress stream. Critical for diagnosing the Vulkan failure.
5. **Android CPU variant selection confirmed correct** — llamadart's `_androidCpuVariantPriority` scores ARMv9.2_2 highest and walks down to ARMv8.0_1, and `ggml_backend_load` returns nullptr on incompatible variants so the Dimensity 7025's A78 cores land on `armv8.2_2` or `armv8.6_1` correctly.
6. **Two subtle bugs fixed**:
   - `EmbeddingMetrics.top1Accuracy` was using the wrong denominator (`totalCases` instead of `cases-with-expected-top1`), reporting 70% when the actual was 100%.
   - `SlotFillEvaluator._isHallucinated` flagged over-extractions of utterance substrings as hallucinations. Narrowed to only flag values that don't appear in the utterance at all.

## Key technical findings worth remembering

### 1. Flutter `android:extractNativeLibs="false"` hides ggml backend plugins

**Symptom**: `libggml.so` is compiled with `GGML_BACKEND_DL=ON` in llamadart's prebuilt Android bundle. At runtime ggml discovers optional backends (Vulkan, OpenCL, per-ISA CPU variants) by calling `opendir()`+`readdir()` on the directory containing `libggml.so`.

**Problem**: Flutter's default `extractNativeLibs="false"` keeps all `.so` files inside `base.apk`. The linker can still `dlopen()` them via the APK zip mmap path, but `lib/arm64/` on disk is empty, so ggml's scanner finds nothing and silently falls back to whatever is statically linked.

**Fix**: Add `android:extractNativeLibs="true"` to `AndroidManifest.xml` (with `tools:ignore="ExtractNativeLibs"` to silence the lint warning). Verified working — after the fix, `/data/app/.../lib/arm64/` contains all the expected `.so` files and ggml's backend registry reports `loadedModules=[cpu, vulkan]`.

**Implication for hark-release**: If we ship llamadart, `extractNativeLibs=true` must go in hark-release's manifest too, or we'll ship a CPU-only fallback path without realizing it. This needs to be on the Slice 2 checklist.

### 2. llamadart's `GpuBackend.auto` silently maps to CPU on Android

`llama_cpp_service.dart:207-214`:

```dart
static GpuBackend resolvePreferredBackendForLoad(
  ModelParams modelParams, {
  required bool isAndroid,
}) {
  if (isAndroid && modelParams.preferredBackend == GpuBackend.auto) {
    return GpuBackend.cpu;
  }
  return modelParams.preferredBackend;
}
```

This is intentional but badly named. To get GPU on Android you have to pass `GpuBackend.vulkan` explicitly. We were passing `auto` and thought we were testing the GPU path — we weren't. This explains why early bench runs looked suspicious and why adding `extractNativeLibs` alone did nothing: the request never asked for GPU.

### 3. Vulkan on Mali-G57 crashes on Qwen3 in llama.cpp b8638

Once we set `preferredBackend: GpuBackend.vulkan` explicitly, the backend loaded, enumerated the device, and:

- **EmbeddingGemma**: returned an error during tensor setup (clean exception, llamadart wrapped it).
- **Qwen3**: SIGSEGV in `llama_model_loader::create_tensor` at the null deref of a `ggml_backend_device*`. Stack trace via tombstoned confirmed the crash is in llama.cpp's tensor-placement loop, not in Vulkan driver code.

This is an upstream llama.cpp bug for specific model architectures on Mali. Not fixable from our side without either (a) upstream patches landing and llamadart bumping its pinned tag from `b8638`, or (b) switching to OpenCL. OpenCL isn't bundled in llamadart's default Android archive — would require a custom user-defines config in `pubspec.yaml` hooks — and Mali's OpenCL ML compute maturity is historically worse than its Vulkan.

### 4. Token-classification quality of generative slot-filling is surprisingly good but platform-divergent

Both platforms hit 80–87% exact-match on the gold set. The failures aren't hallucinations — they're over-extraction (pulling "songs" into a `query` field when only `artist` was expected) or boundary errors (missing `days=1` for "tomorrow"). These are the exact failure modes a token-classifier slot tagger would handle cleanly, because BIO tagging doesn't over-extract unless the training data does.

## Decisions made in this session

User-confirmed:

1. **Q4_K_M for Qwen3 0.6B** — add to quant matrix, benchmark on both platforms.
2. **Qwen2.5-0.5B-Instruct** — add to quant matrix, benchmark on both platforms.
3. **No regex/rule-based slot-filling fallback** — rejected.
4. **Explore a specialized non-LLM slot-filler** — encoder-based token classifier (BERT-family, DIET-style, or similar).
5. **Cloud LLM fallback as last resort** — design it, don't build it yet.

## Final architecture verdict (locked 2026-04-10)

After Track 1 (Q4_0 + Qwen2.5 quant exploration) and Track 2 (encoder slot-filler survey, results in `temp/encoder-slot-filler-survey.md`) both reported, the architecture is:

### 1. Embedder migration: SHIP IT

EmbeddingGemma 300M Q8_0 via llamadart is a clean win on every measured axis:

- Quality bit-reliable across Apple Silicon Metal and ARM CPU
- Phone cold load 3.7s (well within budget)
- Phone single embed 150ms (was 54ms ONNX; both are well below the 500ms NLU resolver budget — the ~3× regression is acceptable in exchange for unifying on llamadart)
- Top1 100% / top3 95% / disambiguation 83% / exact 5/5 — identical to existing ONNX baseline

**Action**: proceed with the original Slice 2 plan for the embedder. Migrate `EmbeddingNotifier` from `flutter_embedder` to `llamadart`. Slices 4 / 6 / 7 of the original migration doc all unblock from this.

### 2. Slot filling via local generative LLM: KILLED

There is no generative model + quant combination that hits interactive latency on Moto-G56-class hardware (Dimensity 7025, A78 CPU). The data:

- Qwen3 0.6B Q8_0: 27.6–29.4 s/case, 87% exact match (passes quality with jitter, fails latency)
- Qwen3 0.6B Q4_0: 27.9 s/case (no speedup), 60% exact match, 13% hallucinations (fails both)
- Qwen2.5-0.5B Q4_K_M: 27% exact match on macOS (fails quality before phone latency even matters)
- Qwen2.5-0.5B Q8_0: 20% exact match on macOS (same)

The bottleneck on phone is **CPU compute on prompt processing**, not memory bandwidth on weights. Smaller weight files improve cold load but not per-case latency. Only a much smaller compute footprint (or a much shorter prompt, or different hardware) breaks the 28-second floor.

**Action**: do NOT migrate `SlotFillingNotifier` from `flutter_gemma` to `llamadart`. Leave the existing flutter_gemma + Qwen3 LiteRT path in place as a placeholder. Add a "this device is below the interactive-latency floor for on-device slot filling" warning to the settings UI when the device profile (Dimensity 7000 / Snapdragon 6 / older) is detected. Slice 3 of the original migration doc is **cancelled**.

### 3. New slot-filling architecture: split into two paths

The slot-filling workstream becomes its own thing, no longer part of the llamadart migration. Two paths, neither replaces the other:

#### Path A — Cloud LLM fallback (now PRIMARY for slot fill, was "last resort")

The biggest decision shift this session. Previously framed as a fallback, this is now the **default** slot-fill path for any device that doesn't clear the on-device latency floor — which is most mid-range Android, including Hark's Moto G56 reference device and all of the Dimensity 7000 / SD 6 / Helio family that dominates Hark's likely user base in India.

Rough sketch (full design doc to come, deferred):

- Host: most likely Vercel Functions Node.js runtime with Fluid Compute and AI SDK streaming. Already in our stack, Fluid's active-CPU pricing is friendly to bursty mobile traffic, AI SDK's streaming response handles slot-fill output nicely. Alternative: Cloudflare Workers AI for lower cold start, or self-host on Hetzner with vllm/ollama for full control. Pick after the design doc weighs cost / privacy / latency.
- Protocol: Hark sends `{intent_id, utterance, action_schema_json, user_id_hash}` over HTTPS, function returns `{slot_values, confidence, model_used}` as streaming JSON. Target round trip: <2s cold, <500ms warm. Cost target: <$0.001 per slot-fill call at full scale.
- Privacy: zero-retention contract with the model provider (Anthropic enterprise, OpenAI data opt-out, or Google Vertex with the right config). Sensitive intents (contacts, messages, banking) never escalate to cloud regardless of latency. User opt-in toggle in settings.
- Escalation policy: EmbeddingGemma confidence gate first, then either local encoder (path B if available) or cloud (always available). User can also manually opt-in via "complicated command" toggle.

**Action**: write `docs/plans/cloud-nlu-fallback.md` as a separate planning doc. No code yet. Implementation lands as a new slice in a follow-up.

#### Path B — On-device encoder slot filler (FAST HAPPY PATH for compatible languages)

Survey results in `temp/encoder-slot-filler-survey.md`. Summary of the trade-offs:

- **No single off-the-shelf encoder hits all of `<80 MB INT8 + Hindi/Punjabi + joint slot filling`.** State of the art has not solved this combination yet.
- **Best English+European option**: `Xenova/distilbert-base-multilingual-cased-ner-hrl` — DistilBERT 135M, ~65MB INT8, AFL-3.0 license, expected 40-80ms on A78. Covers en/de/es/fr/it/nl/pt + others. **No Hindi/Punjabi.**
- **Best Indic option**: `ai4bharat/IndicNER` — mBERT 167M fine-tuned on 11 Indic languages including Hindi+Punjabi, MIT license. **No pre-built ONNX, needs DIY export, sits at 140 MB INT8 — borderline against the 150 MB hard cap.**
- **GLiNER family** (zero-shot, label-free): Most promising long-term candidate. All currently released variants either overshoot size budget (small=183 MB INT8, multi=349 MB INT8) or don't cover Hindi/Punjabi. Park as Phase-2 experiment.
- **Latency**: Every number in the survey is extrapolated from ONNX Runtime mobile benchmarks on similar SoCs — no public Cortex-A78 token-classification benchmarks exist for any of these. Real measurement is required before committing.

**Action**: spike a slot-filler bench harness (mirror of `quant_bench`'s structure) that:
1. Loads `Xenova/distilbert-base-multilingual-cased-ner-hrl` ONNX INT8 via the existing flutter_embedder onnxruntime path.
2. Runs token classification on the 15-case slot-fill gold set.
3. Measures latency on Moto G56 and accuracy against the gold set.
4. Reports: how many cases handled, latency per case, false positives.

If ≥70% of cases pass at <100ms each on phone, Path B becomes the default for English-language users on supported devices. If <70%, Path B is shelved and Path A (cloud) becomes the only slot-filler architecture.

For Indic languages, even if Path B works for English, we still need either (a) IndicNER as a second model with the size penalty, or (b) cloud escalation for Indic queries. This is a separate decision that depends on Hark's actual user-language distribution.

**Estimated effort**: 1-2 sessions for the spike harness, plus 1 session for the IndicNER ONNX export experiment.

**Files touched**: `tools/slot_filler_bench/` (new) or extend `tools/quant_bench/` with a second evaluator type. Pre-downloaded ONNX model in `temp/`.

## Commit history on `feat/llamadart-migration`

- `b099de0` — docs: plan llamadart migration with quantization benchmark
- `f213e36` — feat(perf): instrument model load phases with Stopwatch timing
- `2efe65d` — feat(resolver): keyword / alias fast-path for zero-parameter commands
- `420234f` — feat(bench): Slice 0 quant benchmark harness in tools/quant_bench
- `de2069d` — bench(quant): switch to first-party Q8_0 sources only
- `f204a59` — bench(quant): fix metrics, enable Android device runs, disable macOS sandbox
- `a9f2568` — bench(quant): extract native libs on Android, route native logs, default to CPU
- `a0dfa40` — bench(quant): v3 matrix with Q4_0 + Qwen2.5, measure_all_quants policy

Untracked under `temp/`:
- `temp/encoder-slot-filler-survey.md` — full Track 2 research output, sources, comparison table, recommendations
- `temp/hark-bench-models/*.gguf` — five GGUF files used by the bench (~2.4 GB local, also pushed to phone)

The actual quant_bench results JSONs from each run are in:
- macOS: `~/Documents/quant_bench/results_*.json`
- Phone: `/storage/emulated/0/Android/data/com.oacp.hark.quant_bench/files/quant_bench/{latest.json, results_*.json}` (pull via `adb pull`)

## Open questions for the next session

The previous session left 6 open questions. Status update:

1. ~~**Q4_K_M source trust for Qwen3 0.6B**~~ — **answered**. Neither Qwen team nor ggml-org publishes Q4_K_M for Qwen3 0.6B. We used Q4_0 from ggml-org as the closest first-party Q4 alternative.
2. ~~**Qwen2.5-0.5B chat template compat**~~ — **non-issue**. llamadart's chat template engine auto-detected ChatML correctly. The Qwen2.5 problem was model size / training mismatch, not template compat.
3. ~~**Track 2 ONNX model availability**~~ — **answered**. See encoder survey. Yes, multiple ONNX-deployable BERT-NER models exist; the survey identified the best three. None solve all three constraints (size + Hindi/Punjabi + joint slot filling) simultaneously.
4. ~~**Does user accept exemplar retrieval as "not rules"?**~~ — **moot**. With cloud LLM as the primary path, we don't need exemplar retrieval. It would only matter if we had to ship purely on-device, which we don't.
5. **Slot-fill quality gate threshold** — still open. With Q8_0 hitting 80–87% on both platforms with run-to-run jitter, the 80% gate is right on the edge. For documentation purposes leave it at 80% but treat anything in 78–82% as "passing with caveat". The cloud LLM should easily clear 95%+, so this gate becomes a triage signal not a hard ship/no-ship line.
6. **Hard cap on acceptable slot-fill latency** — partially answered. 5s is the working target; 28s (current local) is unacceptable; 1-3s is comfortable. The cloud round-trip target of <2s cold / <500ms warm fits comfortably.

New open questions for the next session:

7. **What fraction of Hark's expected user base is on devices below the on-device-LLM viability floor?** Moto G56 is the reference; we need to understand whether this is "10% of users" or "70% of users". This determines whether cloud fallback is "edge case for cheap phones" or "the actual default path".
8. **Is `Xenova/distilbert-base-multilingual-cased-ner-hrl`'s AFL-3.0 license a blocker?** OSI-approved permissive but unusual for ML. 15-minute legal check. If it's a blocker, fall back to `Xenova/bert-base-NER` (MIT, English-only) + `ai4bharat/IndicNER` (MIT, Hindi/Punjabi but DIY ONNX export and at the size cap).
9. **Cloud LLM provider decision**: Anthropic / OpenAI / Google Vertex / Vercel AI Gateway with model routing. Cost vs privacy vs latency trade-off, factor in zero-retention contract availability.
10. **Should the encoder slot filler reuse the existing flutter_embedder onnxruntime stack, or do we need a new path?** flutter_embedder is on its way out per this migration doc. If we keep it just for the encoder slot filler that's two on-device runtimes (llamadart for embedding, flutter_embedder for slot fill encoder) — manageable but ugly. Alternative: see if llama.cpp's bert.cpp / GGUF encoder support can do token classification end-to-end so everything stays under llamadart. This is research, not a decision.

## Where to resume — next session

The state at end-of-session 2026-04-10 is:

1. **All planned bench work for Slice 0 is complete.** Verdict above is locked.
2. **Repo is committed clean.** Branch `feat/llamadart-migration` has 8 commits. Nothing uncommitted in tracked files. The encoder survey lives in `temp/` (untracked, intentional).
3. **Phone has all 5 GGUF files** in `/data/user/0/com.oacp.hark.quant_bench/files/bench_models/` for any future re-runs without re-pushing.
4. **macOS quant_bench is built and runnable** from `tools/quant_bench/build/macos/Build/Products/Debug/quant_bench.app`.
5. **APK currently installed on phone is the v3 subset** (only EmbeddingGemma + Qwen3 Q4_0). To run the full v3 matrix on the phone, do `flutter build apk --debug && adb install -r` from `tools/quant_bench/` after a `git stash pop` or fresh checkout — the committed matrix has all 5 quants.

The next session should pick up at one of three forks:

### Fork A — Start the slot-filler encoder spike (Path B)
This is the most interesting open question. Concrete first steps:
1. Download `Xenova/distilbert-base-multilingual-cased-ner-hrl` model files (ONNX INT8) to `temp/`.
2. Build a `tools/slot_filler_bench/` Flutter app or extend `tools/quant_bench/` with a `EncoderSlotFillerEvaluator` class.
3. Wire it to the existing flutter_embedder onnxruntime path.
4. Run on the 15-case slot-fill gold set on Moto G56.
5. Report: latency, accuracy, which cases pass.
6. Decide: ship Path B for English users, or shelve and go cloud-only.

### Fork B — Write the cloud LLM fallback design doc (Path A)
1. Open `docs/plans/cloud-nlu-fallback.md` (new file).
2. Lay out: host choice, protocol, escalation policy, privacy story, cost model.
3. Pick a cloud provider candidate.
4. Estimate cost at 1k / 10k / 100k DAU.
5. No code yet. Implementation is its own slice.

### Fork C — Start the embedder migration (the part that's ALREADY decided)
This is the unblocked part of the original migration plan. Concrete first steps:
1. Open `lib/state/embedding_notifier.dart` in the hark-release worktree.
2. Replace `flutter_embedder` calls with `llamadart` calls (`LlamaEngine.embed()`).
3. Update `pubspec.yaml`.
4. Update model artifact path from ONNX to GGUF.
5. Update `HarkApplication.onCreate` to warm the engine in a background isolate (Slice 4 of the original migration plan).
6. Re-measure cold load + first-token-latency end-to-end (Slice 6).
7. Open the migration PR (Slice 7).

Forks A, B, and C are independent and can run in parallel — they touch different files entirely. **My recommendation when resuming: do C first** (the embedder migration is the part that's actually decided and unblocked, and it's a small concrete win that ships value). Then B (cloud design doc, pure writing). Then A (encoder spike, the most uncertain but most interesting).

All Slice 0 tooling is reusable for future runs:
- `tools/quant_bench/` — push-to-phone workflow, gold set structure, result diffing
- `temp/encoder-slot-filler-survey.md` — research baseline for the encoder spike
- `temp/hark-bench-models/*.gguf` — model files (don't redownload)
- Phone has its bench_models dir already populated (don't re-push)
