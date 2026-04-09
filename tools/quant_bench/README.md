# quant_bench — Hark llamadart quantization benchmark

Local Flutter app used only to validate slice 0 of the llamadart migration
plan ([`docs/plans/llamadart-migration.md`](../../docs/plans/llamadart-migration.md)).
It runs a matrix of `(model × quantization)` combinations against a
20-case embedding gold set and a 15-case slot-filling gold set, then
writes a JSON results file and flashes pass/fail per quant in the UI.

Not a shipping app. Do not release this.

## What it tests

Two models at up to three quantization levels each, with a "smallest
first, escalate on fail" policy:

| Model | Quants tested | Gold set |
|---|---|---|
| EmbeddingGemma 300M | Q4_K_M → Q5_K_M → Q8_0 | `assets/gold/embedding_gold.json` |
| Qwen3 0.6B | Q4_K_M → Q5_K_M → Q8_0 | `assets/gold/slot_filling_gold.json` |

The escalation stops at the first quant that passes the model's quality
gate defined in `assets/configs/quant_matrix.json`. If even Q8_0 fails
for slot-filling, the migration plan falls back to "embedder-only
migration" — see plan slice 0.6.

## Quality gates

**EmbeddingGemma** passes when all of:

- `top1_accuracy >= 0.70`
- `top3_recall >= 0.85`
- `disambiguation_coverage >= 0.80`
- All 5 exact-match cases rank correctly in top-1

**Qwen3 0.6B** passes when all of:

- `json_validity >= 0.93`
- `exact_match >= 0.80`
- `type_correct >= 0.90`
- `hallucination_rate == 0`
- Every required parameter in every case is populated

## Prerequisites

You need the GGUF files on disk before running. The bench app does not
download them — that is intentional so runs are reproducible.

**Download into a models directory** (default: `~/Downloads/hark-bench-models` on macOS, `$externalStorage/hark-bench-models` on Android):

```bash
mkdir -p ~/Downloads/hark-bench-models
cd ~/Downloads/hark-bench-models

# EmbeddingGemma — start with Q4_K_M
wget https://huggingface.co/unsloth/embeddinggemma-300m-GGUF/resolve/main/embeddinggemma-300m-Q4_K_M.gguf

# Qwen3 0.6B — start with Q4_K_M
wget https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf
```

Only the files in `filename_candidates` for the quant you want to test
need to be present. The runner tries each candidate for each quant in
priority order and skips missing ones cleanly. If none of a quant's
candidates are present, that quant is recorded as SKIP (not a failure)
and the next quant runs.

## Running

### macOS (fastest iteration — quality numbers)

```bash
cd tools/quant_bench
flutter run -d macos --release
```

The app opens with the models directory pre-filled to
`~/Downloads/hark-bench-models`. Tap **Run benchmark**. Progress streams
into the log view. Results are written to
`~/Library/Containers/com.oacp.hark.quant_bench/Data/Documents/quant_bench/results_<timestamp>.json`
— or whatever `getApplicationDocumentsDirectory()` resolves to on your
macOS setup.

### Android (final timing numbers on the real target device)

1. Push the GGUF files to the Moto G56 via `adb`:
   ```bash
   adb shell mkdir -p /storage/emulated/0/Android/data/com.oacp.hark.quant_bench/files/hark-bench-models
   adb push ~/Downloads/hark-bench-models/embeddinggemma-300m-Q4_K_M.gguf \
     /storage/emulated/0/Android/data/com.oacp.hark.quant_bench/files/hark-bench-models/
   adb push ~/Downloads/hark-bench-models/Qwen3-0.6B-Q4_K_M.gguf \
     /storage/emulated/0/Android/data/com.oacp.hark.quant_bench/files/hark-bench-models/
   ```
2. Build + install the harness APK:
   ```bash
   cd tools/quant_bench
   flutter run -d <device-id> --release
   ```
3. Tap **Run benchmark** in the app.
4. Pull the results file:
   ```bash
   adb exec-out run-as com.oacp.hark.quant_bench \
     cat files/quant_bench/results_*.json > device_results.json
   ```

## Output

Each result JSON contains one entry per `(model, quant)` run, with:

- `passed_quality_gate: bool`
- `embedding` metrics (for embedding model runs): `top1_accuracy`,
  `top3_recall`, `disambiguation_coverage`, `exact_match_all_passed`,
  `avg_top1_score`, `failure_details`
- `slot_fill` metrics (for generation model runs): `json_validity_rate`,
  `exact_match_rate`, `type_correct_rate`, `hallucination_rate`,
  `required_fields_rate`, `failure_details`
- `perf`: `cold_load_ms`, `single_inference_ms`, `file_size_bytes`
- `error` if the run threw

The results file is the input for
`docs/plans/llamadart-quant-benchmark.md` — the writeup that gates
slices 2–4 of the migration.

## Troubleshooting

**"File not found in /path"**: the harness could not find any of the
filename_candidates for this quant. Check that the file is in the
models directory and matches one of the names in
`assets/configs/quant_matrix.json`.

**llamadart native library fails to load on macOS**: llamadart uses
Dart's native assets hook (`hook/build.dart`) to download prebuilt
binaries at `pub get` time. If this failed silently, try
`cd tools/quant_bench && flutter clean && flutter pub get` and check
the logs.

**Benchmark hangs on slot-filling**: Qwen3 generation can be slow
without GPU layers. The runner uses `GpuBackend.auto` which should pick
Metal on macOS. On Android, it falls back to CPU. Expect 2–10 seconds
per slot-fill case on CPU. 15 cases × 3 quants = ~7 minutes in the
worst case.
