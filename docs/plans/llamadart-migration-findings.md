# llamadart migration — Slice 0 findings & architectural decision

**Status**: Slice 0 (quantization benchmark gate) complete. Slices 1–7 blocked pending architectural decision on slot-filling approach.

**Worktree**: `worktree-llamadart-migration` on branch `feat/llamadart-migration`

**Date drafted**: 2026-04-09

**Context**: This doc extends [`llamadart-migration.md`](llamadart-migration.md). Read that first for the original 7-slice plan and the trust-tier analysis. This doc captures what Slice 0 actually measured, the surprises we hit on real hardware, and the decisions we need to make before any of Slices 2–7 can start.

## TL;DR

- **Quality on both platforms is fine.** EmbeddingGemma 300M Q8_0 is bit-reliable across Apple Silicon and ARM. Qwen3 0.6B Q8_0 hits 80–87% exact-match slot-fill across the 15 gold cases, failing the 90% quality gate by a small margin but well above unusable.
- **Moto G56 5G is hardware-bound below interactive latency for Qwen3 0.6B Q8_0.** Steady-state slot-fill wall time is **27–30 seconds per case**, which is ~14× slower than Apple Silicon Metal and ~10× slower than interactive-acceptable. This is not a llamadart bug or a tuning problem — llama.cpp's CPU backend is already selecting the A78-optimal variant, and the hardware's memory bandwidth caps throughput at ~1–2 tok/s for a 600 MB Q8_0 model. No software tweak closes this gap.
- **Vulkan GPU offload is not viable on Mali-G57 with llama.cpp b8638.** The backend loads, enumerates the device, and then crashes with a null `ggml_backend_device*` in `llama_model_loader::create_tensor` for Qwen3. EmbeddingGemma fails the same path but returns a clean error instead of segfaulting. This is an upstream llama.cpp bug for specific model architectures on Mali. Chasing it is not a good investment; Arm's OpenCL backend isn't bundled by default in llamadart's prebuilt Android archive and Mali's OpenCL compute maturity is historically worse.
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

## Three tracks to execute (deferred to next session)

### Track 1 — Quant & smaller-model exploration

**Goal**: Hard data on whether any local generative model can hit interactive latency on Moto-G56-class hardware.

**Work**:
1. Update `tools/quant_bench/assets/configs/quant_matrix.json` to add:
   - `Qwen3-0.6B-Q4_K_M.gguf` — source: `Qwen/Qwen3-0.6B-GGUF` (first-party, same tier as current Q8_0)
   - `Qwen2.5-0.5B-Instruct-Q8_0.gguf` — source: `Qwen/Qwen2.5-0.5B-Instruct-GGUF` (first-party)
   - `Qwen2.5-0.5B-Instruct-Q4_K_M.gguf` — same source
2. Download the three new GGUF files to `temp/hark-bench-models/`.
3. Push to phone via the existing `adb shell run-as` stream pipe workflow.
4. Rerun `quant_bench` on macOS + Moto G56. Quality gate stays at its current thresholds.
5. Expected outcome: Q4_K_M should be ~2× faster on memory-bandwidth-bound CPU (400MB model vs 600MB). Qwen2.5-0.5B is smaller still (~400MB Q8_0 / ~250MB Q4_K_M). One of these may get below 15s/case on the phone.

**Gate**: If any combination gets below 5s per slot-fill case on the phone *and* maintains the 90% exact-match gate, generative slot-filling becomes viable with escalation to cloud for complex cases. If nothing clears 10s/case, generative slot-filling is off the table for this hardware class and Track 2 becomes the main path.

**Estimated effort**: 1 session. Download + benchmark + analyze.

**Files touched**: `tools/quant_bench/assets/configs/quant_matrix.json`, `temp/hark-bench-models/*.gguf` (untracked).

### Track 2 — Non-LLM specialized slot-filler research

**Goal**: Establish whether a transformer encoder (not autoregressive) can do joint intent + slot filling at <100ms on Moto G56, removing the need for a generative model on the hot path entirely.

**Category**: This is the pre-LLM NLU literature. It was the state of the art from ~2017–2021 and the models are 10–50× smaller and 100–500× faster than any generative LLM. The canonical architectures:

#### Option A — Pre-trained BERT-NER token classifier (BIO tagging)

Load a pre-trained multilingual BERT-NER model, run token classification, reconstruct spans, map entity types to action parameters by schema.

Candidate models (all Apache-2.0 / MIT):
- `Davlan/distilbert-base-multilingual-cased-ner-hrl` — DistilBERT 66M, ~260MB FP32 / ~65MB INT8 ONNX, ~30–80ms on Android CPU
- `dslim/bert-base-NER` — BERT-base, English only, ~420MB FP32 / ~100MB INT8
- `dbmdz/bert-base-multilingual-cased-finetuned-conll03-english` — similar
- `Jean-Baptiste/roberta-large-ner-english` — larger, higher accuracy, probably too heavy for mobile

**Pros**: Zero training required for generic entities (PER, LOC, DATE, TIME, NUM, ORG, MISC). ~10 of 15 gold cases are covered by generic NER out of the box. Runs on existing flutter_embedder (ONNX) or could move to llamadart's encoder mode if llama.cpp exposes token-level hidden states.

**Cons**: Action-specific parameters (`format=QR_CODE`, `days=1`) aren't covered by generic NER — need either per-action post-processing (which edges toward rules — user rejected) or a custom fine-tuned model.

#### Option B — Fine-tuned joint intent + slot transformer (DIET-style)

Single model, two heads: one classifies intent, the other does BIO slot tagging. Rasa's DIETClassifier is the canonical reference implementation (Apache-2.0). ~25–50M params.

**Pros**: Best accuracy, single forward pass handles both tasks, well-suited for per-user personalization later.

**Cons**: **Requires training data**. Our 15 gold cases aren't enough. Would need to bootstrap on a public dataset first:
- **SNIPS** (13k training examples, 7 intents, English) — small but well-annotated
- **ATIS** (4k, 21 intents, airline domain) — too narrow
- **MASSIVE** (1M multilingual, 60 intents, 51 languages) — Amazon's release, most relevant for a voice assistant
- **MultiATIS++** — multilingual extension of ATIS

Training pipeline (Python + HF Transformers) + eval harness + ONNX export + mobile runtime. **Weeks of work**. Defer to later unless Option A doesn't cover enough cases.

#### Option C — Retrieval-augmented exemplar matching

Build a corpus of `(utterance, intent, slots_filled)` exemplars. Embed utterances with EmbeddingGemma (already loaded). At inference, find k-nearest exemplars and copy their slot template with substitution via entity alignment.

**Pros**: No new model, no training, reuses existing EmbeddingGemma pipeline. Quality scales linearly with corpus size.

**Cons**: Cold-start problem — needs a seed corpus. Hark's existing NLU resolver does a version of this for the keyword fast-path; extending it to parameter slots means building an aligned exemplar corpus by hand (or bootstrapping from the LLM's outputs during a "training" phase). User's "no regex" rejection might extend to this approach — needs clarification.

#### Track 2 concrete plan

1. **Survey phase** (30 min): Confirm which pre-trained BERT-NER models are ONNX-deployable, find the smallest one with acceptable multilingual coverage, verify license.
2. **Spike phase** (1 session): Build a Flutter test harness similar to `quant_bench` but using `flutter_embedder` (or the existing onnxruntime-based path) to load the encoder, run token classification on the 15 slot-fill gold cases, and measure both latency and accuracy.
3. **Analysis phase** (part of spike session): How many of 15 cases does a zero-shot NER handle correctly? Is the remaining gap small enough for cloud escalation? Is per-action parameter mapping feasible without becoming "rules"?
4. **Decision**: If ≥70% of cases pass at <100ms/case, this is the new default slot-filling path and Qwen3 becomes a cloud-only fallback. If <70%, Track 2 becomes Option B (fine-tuning) and we're months away from a result — we'd have to fall back to Track 1 + cloud for the interim.

**Gate**: ≥70% zero-shot accuracy at <100ms/case on Moto G56. Otherwise Option A is insufficient and we escalate to Option B or abandon the track.

**Estimated effort**: 1–2 sessions for the spike. Training (Option B) is much more.

**Files touched**: `tools/slot_filler_bench/` (new, or extend quant_bench with a new evaluator type), a pre-downloaded ONNX model in `temp/`, findings added to this doc.

### Track 3 — Cloud LLM fallback architecture (design only)

**Goal**: A written design doc for when and how to escalate from local inference to a cloud LLM, without committing to an implementation until after Tracks 1 and 2 report.

**Work**:
1. **Host choice**. Options surveyed:
   - **Vercel Functions** (Node.js runtime with Fluid Compute) — pro: already in the stack, Fluid Compute's active-CPU pricing is cheap for bursty traffic, streaming is first-class, 300s default timeout covers any LLM round trip. Con: cold start 800ms–2.5s on Node.js runtime; Edge runtime has <1ms cold start but limited API surface. For AI workloads Vercel recommends Node.js + streaming via AI SDK's `toUIMessageStreamResponse()`.
   - **Cloudflare Workers AI** — pro: even lower latency, Workers AI has built-in model inference. Con: different model selection, binding to CF ecosystem.
   - **Direct API calls** to Anthropic / OpenAI / Google from the client — pro: simplest, no server. Con: can't hide API keys, can't rate-limit, can't audit, can't do user billing.
   - **Self-hosted on tiny VPS** (e.g., Hetzner + vllm or ollama) — pro: full control, cheapest at scale. Con: ops burden.

   Leading candidate: **Vercel Functions with Fluid Compute + AI SDK streaming + Node.js 24 runtime**. Rationale: already in the stack, streaming protocol well-defined, Fluid's active-CPU pricing suits bursty mobile traffic, `waitUntil`/`after` lets us log and audit without blocking the response.

2. **Protocol design**. Hark sends `{intent_id, utterance, action_schema_json, user_id_hash}`. Function returns `{slot_values: {...}, confidence, model_used}` as streaming JSON (SSE). Target round-trip: <2s cold, <500ms warm.

3. **Escalation policy**. When does Hark escalate?
   - EmbeddingGemma confidence gate (if top1 score < threshold → maybe route to cloud)
   - Encoder slot-filler confidence gate (from Track 2) — if Option A handles the intent but flags a parameter as uncertain, escalate
   - Explicit user opt-in ("complicated command" toggle in settings, or user says "use the big model")
   - Never on sensitive intents (contacts, messages, banking) — those stay local regardless

4. **Privacy story**. What's sent, what's logged, data retention, opt-in UX, which cloud providers respect "zero retention" contracts (Anthropic via enterprise has it, OpenAI has data opt-out, Google needs specific Vertex config).

5. **Cost modeling**. Per-request cost estimate for each candidate, break-even analysis vs on-device battery cost.

**Write it up** as `docs/plans/cloud-nlu-fallback.md` (sibling of this doc). No code. Explicit "implementation deferred" note.

**Estimated effort**: 1 session (pure writing, no benchmarking).

**Files touched**: `docs/plans/cloud-nlu-fallback.md` (new).

## What's committed vs uncommitted

### Committed (on `feat/llamadart-migration`)
- `b099de0` — docs: plan llamadart migration with quantization benchmark
- `f213e36` — feat(perf): instrument model load phases with Stopwatch timing
- `2efe65d` — feat(resolver): keyword / alias fast-path for zero-parameter commands
- `420234f` — feat(bench): Slice 0 quant benchmark harness in tools/quant_bench
- `de2069d` — bench(quant): switch to first-party Q8_0 sources only
- `f204a59` — bench(quant): fix metrics, enable Android device runs, disable macOS sandbox

### Uncommitted changes staged for "continue" session
- `tools/quant_bench/android/app/src/main/AndroidManifest.xml` — added `extractNativeLibs=true` with documentation comment explaining why (ggml backend plugin discovery needs extracted `.so` siblings on disk).
- `tools/quant_bench/lib/bench/bench_runner.dart` —
  - Wired `LlamaEngine.configureLogging` + `engine.setNativeLogLevel` so llama.cpp native log messages flow into the bench progress stream (critical for diagnosing the Vulkan failure and verifying which CPU variant loaded).
  - Added `_resolveAndroidBackend()` helper that defaults to `GpuBackend.cpu` on Android (Vulkan crashes on Qwen3) but respects `HARK_BENCH_BACKEND=cpu|vulkan|opencl` env override for future retests.
  - Commented explanation of why `GpuBackend.auto` is wrong on Android and why Vulkan is opt-in.

These should be committed at the start of the next session so the findings and the reproducibility both land together. Commit message draft:

```
bench(quant): extract native libs on Android, route native logs, default to CPU

Three related fixes discovered while diagnosing why Qwen3 0.6B Q8_0 was
running ~30s/case on Moto G56 5G:

1. android:extractNativeLibs=true in AndroidManifest — Flutter's
   default leaves libggml.so and its backend plugins inside the APK
   zip, so ggml's readdir-based backend discovery finds nothing and
   every optional backend silently falls back to whatever is
   statically linked. Setting this to true forces extraction to
   /data/app/.../lib/arm64/ where ggml can find the Vulkan and
   per-ISA CPU variant plugins.

2. Native log routing via LlamaEngine.configureLogging +
   engine.setNativeLogLevel. Without this, llama.cpp's backend
   registry and tensor-placement errors go to native stderr, which
   is /dev/null on Android. This is how we discovered Vulkan on
   Mali-G57 crashes Qwen3 during tensor setup — the log handler
   captured "loadedModules=[cpu, vulkan], devices=[CPU, Vulkan
   (Vulkan0)]" right before the SIGSEGV.

3. _resolveAndroidBackend defaults to GpuBackend.cpu on Android but
   respects HARK_BENCH_BACKEND env override. Vulkan crashes Qwen3 on
   Mali-G57 with llama.cpp b8638 (upstream bug in
   llama_model_loader::create_tensor), so GPU is opt-in until
   upstream fixes it.

Full findings in docs/plans/llamadart-migration-findings.md.
```

## Open questions for the next session

1. **Q4_K_M source trust**. The Qwen team publishes `Qwen/Qwen3-0.6B-GGUF` on HuggingFace with Q4_K_M included — same first-party trust tier as the current Q8_0. Confirm this repo actually has Q4_K_M for the 0.6B variant before planning the download. If it doesn't, fall back to `ggml-org/Qwen3-0.6B-GGUF` if they publish it, or accept a trust-tier compromise for the bench (but not for production).

2. **Qwen2.5-0.5B tokenizer compatibility with llamadart chat template engine**. Qwen2.5 and Qwen3 use different chat templates (Qwen2.5 uses ChatML, Qwen3 adds the `<think>` thinking-mode tags). Verify llamadart auto-detects both before burning a download.

3. **Track 2 ONNX model availability**. Is there a small (<80MB) ONNX-exported multilingual BERT-NER model that covers PER/LOC/DATE/TIME/NUM as entity types? The HuggingFace optimum library exports most models to ONNX but some need manual export. Confirm before committing to Track 2.

4. **Does user accept Option C (exemplar retrieval) as "not rules"?** The distinction between "retrieval-based matching with an index of exemplars" and "rules" is fuzzy. Need user clarification. If Option C is accepted, it becomes the fastest path to ship because it needs zero new models.

5. **Slot-fill quality gate threshold**. Current gate is 90% exact-match. Qwen3 hits 80–87% on both platforms, which fails the gate but is above "useless." Should we lower the gate to 85%? If yes, Q8_0 passes the *quality* half of the bench on phone — still fails the *perf* half. Lowering the gate would let us ship Q8_0 as the fallback if cloud is unreachable.

6. **Hard cap on acceptable slot-fill latency**. What's the UX ceiling for a voice command → parameter extraction response? 3s is comfortable. 5s is slow but tolerable. 10s feels broken. Calibrate the Track 1 gate accordingly.

## Where to resume

Next session should start by:

1. Reading this doc end-to-end.
2. Committing the uncommitted changes with the message above.
3. Deciding on Track 1 vs Track 2 execution order (or running them in parallel — they don't conflict).
4. Answering the open questions at the bottom of this doc as a warm-up.

All the tooling from Slice 0 is reusable as-is — `quant_bench` already handles the push-to-phone workflow, the gold set structure is model-agnostic, and the result-diffing infrastructure works for new runs. Track 1 is mostly config + download + push + rerun. Track 2 is a new harness but can crib structure from `quant_bench`.
