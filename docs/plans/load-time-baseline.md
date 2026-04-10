# Load time baseline — Phase 1 of the near-term plan

**Status**: **stub — awaiting current-stack measurements on Moto G56.** The llamadart column is populated from Slice 0 findings. The current-stack column gets populated when the phone is reconnected and Phase 1A measurements are run.

**Owner**: Phase 1 of `~/.claude/plans/async-twirling-galaxy.md`.

**Purpose**: produce the data that Phase 2 uses to decide whether to migrate the embedder + slot filler from `flutter_embedder` + `flutter_gemma` to `llamadart`. The decision is pre-committed to the data via the migration rules (§Migration rules below).

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

Three scenarios per runtime. Each is measured with the existing Stopwatch instrumentation (`hark-release/lib/services/inference_logger.dart`, `logModelLoad()` API, logs to `model_load_logs/load_*.jsonl`).

1. **First-run cold start**: fresh install, cold disk, models not downloaded. Includes model download from HuggingFace + init + action embedding cache build. This is the first-ever launch a user sees.
2. **Subsequent cold start**: models already on disk, app process not in memory (killed or force-stopped). Includes disk load + init + action cache build. This is a typical daily launch.
3. **Warm start**: models in memory, app backgrounded and resumed. Should be near-instant. This is the fastest case.

For each scenario, we also capture:
- **Single inference** on the embedder: one `embedQuery()` call timed, after warmup. Ballpark: 100-200 ms.
- **Single generation warmup** on the slot filler: 16-token generation with deterministic params (temp 0, topK 1, seed 42). Ballpark: 5-30 seconds on phone CPU.

Plus a quality spot-check on the embedder (top1 / top3 / disambiguation on the 20-case gold set) to confirm quality parity. The slot-filler quality is not re-measured — it's already known from Slice 0.

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

**STATUS: NOT YET MEASURED.** These rows get filled in during Phase 1A of the near-term plan, once the phone is reconnected and the hark-release debug build can be installed.

| Metric | Current stack on Moto G56 | Notes |
|---|---|---|
| EmbeddingGemma ONNX via `flutter_embedder` — first-run cold start (with download) | _TBD_ | Fresh install, cold disk. Captures download + init. |
| EmbeddingGemma ONNX — subsequent cold start (models cached) | _TBD_ | App killed, models cached. Captures init + action cache rebuild. |
| EmbeddingGemma ONNX — warm restart | _TBD_ | App backgrounded, resumed. Should be near-instant. |
| EmbeddingGemma ONNX — single embed (warm) | _TBD_ | One `embedQuery()` call. |
| EmbeddingGemma ONNX — quality (top1 / top3 / disamb / exact) on 20-case gold set | _TBD_ | Spot check against Slice 0 llamadart numbers. |
| Qwen3 0.5B LiteRT via `flutter_gemma` — first-run cold start (with download) | _TBD_ | |
| Qwen3 0.5B LiteRT — subsequent cold start | _TBD_ | |
| Qwen3 0.5B LiteRT — warm restart | _TBD_ | |
| Qwen3 0.5B LiteRT — single gen warmup (16 tokens) | _TBD_ | |
| Qwen3 0.5B LiteRT — **per-case slot-fill wall time** | _TBD_ — THE KEY NUMBER | If there's a working GPU/NPU delegate on Dimensity 7025, this could be dramatically better than llamadart's 27-30s. That's the one scenario that reverses the slot-filling verdict. |
| Qwen3 0.5B LiteRT — delegate status | _TBD_ | Does flutter_gemma expose GPU / NNAPI / Hexagon delegate on Dimensity 7025? |
| Native bundle size (APK) | _TBD_ — ~10-15 MB estimated | |
| APK manifest requirement | None beyond current | |

### Part A — cold start measurement procedure

1. Uninstall any existing `com.oacp.hark` on the test phone: `adb shell pm uninstall com.oacp.hark`.
2. Build a debug APK from the worktree root: `flutter build apk --debug`.
3. Install: `adb install -r build/app/outputs/flutter-apk/app-debug.apk`.
4. Launch from adb: `adb shell am start -n com.oacp.hark/.MainActivity`. Note the clock time.
5. Wait for the splash to complete (mic visible) — this is the first-run cold start including model download.
6. Speak or type a simple command ("what can you do") to confirm the pipeline works end-to-end.
7. Kill the process: `adb shell am force-stop com.oacp.hark`.
8. Wait 5 seconds for the process to fully die.
9. Relaunch: `adb shell am start -n com.oacp.hark/.MainActivity`. Note the clock time.
10. Wait for the splash to complete — this is the subsequent cold start.
11. Background the app (home button), resume, measure — this is the warm restart.
12. Pull the log file:
    ```
    adb shell "run-as com.oacp.hark sh -c 'cat files/app_flutter/model_load_logs/load_*.jsonl'" > /tmp/current_stack_load_logs.jsonl
    ```
    (The exact path may vary — see `inference_logger.dart:_getLoadLogDir()` which uses `getApplicationDocumentsDirectory()`. On Android that's typically `/data/data/com.oacp.hark/app_flutter/model_load_logs/`.)
13. Grep for the phase tags to parse per-phase timing:
    ```
    grep -E "embedding.runtime_init|embedding.manager_init|embedding.cache_lookup|embedding.model_create|slot_filling.runtime_init|slot_filling.model_open|init.all_ready" /tmp/current_stack_load_logs.jsonl
    ```
14. Populate the "Current stack" column above with the actual numbers.

### Part B — per-case slot-fill measurement procedure (optional, only if Part A is ambiguous)

The Slice 0 `tools/quant_bench/` measures llamadart's per-case slot-fill wall time. There is no equivalent bench for `flutter_gemma`. Two options if we need the number:

1. **Fork the bench**. Create `tools/quant_bench_legacy/` or `tools/slot_fill_bench_flutter_gemma/` — a parallel Flutter app that uses the same gold set (`assets/gold/slot_filling_gold.json`), the same evaluator (`lib/bench/slot_fill_eval.dart`), but loads Qwen3 via `flutter_gemma` instead of `llamadart`. Substantial work — an entire Flutter app.
2. **Use hark-release itself as the bench**. Trigger each of the 15 slot-fill gold cases through the real chat UI (by typing into a debug text input or by voice), read per-case timings from `model_load_logs` + `inference_logger.dart`. Less controlled but faster to set up.

Recommendation: **skip Part B unless Part A is ambiguous**. The Slice 0 finding that local generative slot filling is hardware-bound at ~28 s/case was on llamadart; it's plausible that flutter_gemma on the same hardware hits the same ceiling for the same reason (compute on prompt processing is the bottleneck, not the runtime). If the load-time numbers from Part A settle the migration decision, Part B is redundant.

**Exception**: if Part A shows that `flutter_gemma` exposes a GPU or NPU delegate on Dimensity 7025 that's actually engaged, Part B becomes mandatory — a working delegate could break the 28s wall and that's a huge finding.

### Part C — delegate investigation procedure

`flutter_gemma`'s `InferenceModel` API exposes a backend preference (CPU vs GPU). Check whether GPU delegate actually engages on Dimensity 7025:

1. Read `flutter_gemma` package docs at `https://pub.dev/packages/flutter_gemma` for delegate options.
2. Check `hark-release/lib/state/slot_filling_notifier.dart` for how the model is currently initialized — specifically which backend is requested.
3. If GPU backend is not already requested, try a quick toggle: switch to GPU backend, retry, see if init succeeds or falls back.
4. If init succeeds with GPU, measure: run a single slot-fill case and compare to the CPU number. If it's materially faster, dig deeper.
5. If init fails or falls back silently to CPU, document the fallback reason and move on.

The Dimensity 7025's Mali-G57 was already shown to crash on Vulkan with llama.cpp for Qwen3 (Slice 0). LiteRT might use a different Vulkan path, or might use OpenCL, or might use NNAPI. The answer is empirical.

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

## What happens next

Once this doc is populated:

1. Phase 2 of the near-term plan uses these numbers to apply the migration rules above. Decision gets written into this doc as a new "Migration decision" section at the end.
2. If migration fires, Phase 2a executes on the `feat/llamadart-migration` branch. Post-migration numbers get added to this doc as a "Post-migration" row for comparison.
3. Phase 2b load-time optimizations (parallel init, embedding cache persistence, warm engine retention) each add a before/after row. By the end of Phase 2, this doc has the full story of where every millisecond went and where every optimization moved the needle.

---

## Related docs

- `~/.claude/plans/async-twirling-galaxy.md` — the parent plan; this doc is Phase 1 of it.
- `docs/plans/llamadart-migration-findings.md` — Slice 0 findings; the llamadart numbers in this doc come from there.
- `docs/plans/llamadart-migration.md` — original 7-slice plan; preserved for historical context.
- `docs/vision/hark-v2-agent-architecture.md` — long-term v2 vision that the near-term plan derisks the foundation for.
- `docs/vision/encoder-slot-filler-survey.md` — Track 2 research on encoder-based slot tagging as a non-LLM alternative (parked for v2).
