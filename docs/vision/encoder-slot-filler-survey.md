# Encoder-only token classifiers for on-device slot filling — survey

**Date**: 2026-04-10
**Context**: This survey was originally requested as Track 2 of the llamadart migration findings (see `docs/plans/llamadart-migration-findings.md`). The research agent completed the survey shortly before the user asked to deprioritize Track 2; saving the findings here for the next session because they directly inform the architecture decision Track 1's macOS bench results are forcing.

**Target**: Hark Android voice assistant. Replace Qwen3 0.6B (~30 s/case on Moto G56) with a small specialized encoder.

**Constraints**:
- ONNX-deployable (or clean Optimum export path)
- &lt;100 ms per inference on Cortex-A78 CPU
- &lt;80 MB INT8 ideal / 150 MB hard cap
- Multilingual: English + at least one of Hindi/Punjabi (Hark's main user base)
- Permissive license (MIT / Apache-2.0 / BSD)
- Pre-trained for slot-filling or general NER

## Comparison table

| # | Model (HF repo) | Architecture | Params | FP32 size | INT8 size | Languages | License | Entity types | ONNX on HF? | Latency on A78 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `Xenova/distilbert-base-multilingual-cased-ner-hrl` (mirror of `Davlan/...`) | DistilBERT base multilingual cased | 135 M | 539 MB (safetensors) | ~65–70 MB est. (extrapolated; sibling `Xenova/bert-base-NER` int8 = 108 MB and DistilBERT is ~40% smaller) | 10: ar, de, **en**, es, fr, it, lv, nl, pt, zh — **no hi/pa** | AFL-3.0 (OSI permissive) | PER, ORG, LOC (BIO) | Yes — Xenova mirror has `onnx/` subfolder; base Davlan repo has no ONNX | needs measurement; expect 40–80 ms / 32 tokens |
| 2 | `Xenova/bert-base-NER` (mirror of `dslim/bert-base-NER`) | BERT base cased | 108 M | 431 MB | **108 MB** (model_int8.onnx); 93.7 MB (q4f16) | English only | MIT | PER, ORG, LOC, MISC (CoNLL-03) | Yes — full zoo: fp32, fp16, int8, q4, q4f16, bnb4 | needs measurement; ~60–110 ms |
| 3 | `onnx-community/gliner_small-v2.1` | DeBERTa-v3-small + zero-shot label encoder | 166 M | 611 MB | **183 MB** (over hard cap); q4f16 = 245 MB | English only | Apache-2.0 | **Zero-shot, any label** at inference | Yes — fp32/fp16/int8/q4/q4f16 | needs measurement; expect 120–200 ms |
| 4 | `onnx-community/gliner_multi-v2.1` | mDeBERTa-v3-base | 209 M | 1.16 GB | **349 MB** — fails 150 MB cap | ~100 langs incl. hi, pa | Apache-2.0 | Zero-shot | Yes | likely &gt;250 ms; fails latency budget |
| 5 | `knowledgator/gliner-x-small` (GLiNER-X) | mT5 encoder + bi-encoder label head | ~50–60 M backbone (config not on card) | not stated | not pre-built; ~60–90 MB INT8 estimate via Optimum | 20+ incl. **English, Hindi**, Arabic, Chinese, +17 Euro (**Punjabi NOT listed**) | Apache-2.0 | Zero-shot | "ONNX" tag present but no `onnx/` subfolder visible — `optimum-cli export onnx` required | needs measurement; mT5-small encoder ~70–130 ms |
| 6 | `ai4bharat/IndicNER` | bert-base-multilingual-uncased fine-tuned | 167 M | 539 MB safetensors | ~140 MB INT8 (extrapolated) — borderline | **11 Indic incl. Hindi, Punjabi**, Tamil, Telugu, Bengali, Gujarati, Marathi, Kannada, Malayalam, Oriya, Assamese | MIT | PER, ORG, LOC | **No ONNX** — only safetensors/pytorch. Needs `optimum-cli export onnx --task token-classification` | needs measurement; mBERT-base ~90–150 ms |

Latency numbers are extrapolations from ONNX Runtime mobile benchmarks for DistilBERT/BERT base on Snapdragon 7-class chips — no public Cortex-A78 token-classification benchmarks exist for any of these.

## Recommendation

**Try `Xenova/distilbert-base-multilingual-cased-ner-hrl` first**, in parallel with an ONNX export of `ai4bharat/IndicNER` for the Hindi/Punjabi route.

Why:
1. **Size**: 135 M params, halved from mBERT. Pre-built quantized ONNX in the Xenova mirror. Expected ~65–70 MB INT8 fits the 80 MB ideal budget.
2. **Latency**: DistilBERT base is the canonical "fits on phone" encoder. ONNX Runtime + XNNPACK on A78 typically delivers 40–80 ms for ≤32 token utterances.
3. **Coverage**: PER/ORG/LOC out of the box covers ~half of the gold set. DATE/TIME/NUM/URL are well-trodden territory but go via cheap deterministic logic — note this conflicts with user's "no regex" preference, so we may need a separate encoder for those types or escalate to cloud.
4. **Languages**: Native en + 9 others, but **does not cover Hindi/Punjabi** — main weakness, mitigated by routing Indic traffic to IndicNER.
5. **License**: AFL-3.0 is OSI-approved permissive. Not as common as MIT/Apache so worth a quick legal sign-off.

**Indic mitigation**: pair with `ai4bharat/IndicNER` (MIT, 11 Indic langs incl. hi+pa). Requires manual ONNX export and INT8 quantization; expected ~140 MB post-quant — at the hard cap. May need vocab pruning to fit the budget comfortably.

**Why not GLiNER first**: zero-shot label flexibility is attractive (you could express "artist", "song name", "app name" as runtime labels), but every released variant either overshoots size (small=183 MB INT8, multi=349 MB INT8) or is English-only. `gliner-x-small` is the most promising long-term candidate for Indian languages but ONNX export is DIY, parameter count isn't published, and Punjabi is not in the listed coverage. Park it as a Phase-2 experiment.

**Why not bert-base-NER (dslim)**: English-only and slightly larger than the DistilBERT option for no architectural benefit.

## State of the art for on-device joint intent + slot filling (2024–25)

- **MASSIVE benchmark (Amazon, 2022, 51 langs incl. hi)**: still the standard. Models trained on it are dominated by encoder transformers — XLM-R-base, mDeBERTa-v3, and JointBERT-style dual-head architectures. A 2025 COLING industry paper ("Fine-Tuning Medium-Scale LLMs for Joint Intent…") reports Llama3-70B at 90.8% intent / 86.0% slot F1, but a multi-task RoBERTa-base baseline reaches the same band at &lt;300 M params, which is the relevant comparison for on-device.
- **JPIS (ICASSP 2024, VinAI)**: joint profile-based intent + slot model with slot-to-intent attention. Encoder-based, training code Apache-2.0 on GitHub (`VinAIResearch/JPIS`). Closest 2024 paper to Hark's exact use case but requires fine-tuning — no released general weights.
- **MAG (2025)**: Mamba-based multi-intent + slot. Interesting for very long context, no on-device story or ONNX path.
- **GLiNER (NAACL 2024) + GLiNER-2 (2025, arXiv 2507.18546)**: schema-driven multi-task IE in a single bidirectional encoder. Most active research line and natural future replacement for both regex and the generative model — but today's checkpoints don't fit the A78 budget yet.
- **Rasa DIETClassifier**: still maintained, still the production reference. Light, joint intent+slot, but uses its own training pipeline (sparse features + small transformer), not an off-the-shelf HF checkpoint, no Indic pretraining.
- **Snips SLU**: archived 2018, no active development.

**Bottom line**: there is no off-the-shelf 2025 encoder model that simultaneously hits (a) &lt;80 MB INT8, (b) Hindi+Punjabi, and (c) joint intent+slot pretraining. Realistic stack: DistilBERT-multilingual-NER for slots in 10 supported langs, IndicNER (ONNX-exported) for hi/pa, regex/grammar for DATE/TIME/NUM/URL (which conflicts with the "no regex" preference and needs to be revisited), and keep the existing EmbeddingGemma stage as the intent classifier.

## Key follow-ups

- **Two unverified numbers** to confirm before committing to the architecture:
  - actual parameter count of `knowledgator/gliner-x-small` (download `config.json` to read `hidden_size`/`num_layers`)
  - on-device latency for the picked model on a real Moto G56 — every number in the table is extrapolated, no Cortex-A78 token-classification benchmarks exist publicly
- **License note**: Davlan's base repo is AFL-3.0 (OSI permissive but unusual for ML); worth a 15-minute legal check before committing. If AFL is a blocker, the cleanest fully-MIT path is `ai4bharat/IndicNER` for Indic + `Xenova/bert-base-NER` (MIT) for English, accepting that you lose Spanish/French/etc.

## Sources

- [Davlan/distilbert-base-multilingual-cased-ner-hrl](https://huggingface.co/Davlan/distilbert-base-multilingual-cased-ner-hrl)
- [Xenova/distilbert-base-multilingual-cased-ner-hrl ONNX mirror](https://huggingface.co/Xenova/distilbert-base-multilingual-cased-ner-hrl)
- [Xenova/bert-base-NER (full ONNX zoo)](https://huggingface.co/Xenova/bert-base-NER)
- [onnx-community/gliner_small-v2.1](https://huggingface.co/onnx-community/gliner_small-v2.1)
- [onnx-community/gliner_multi-v2.1](https://huggingface.co/onnx-community/gliner_multi-v2.1)
- [urchade/gliner_multi-v2.1](https://huggingface.co/urchade/gliner_multi-v2.1)
- [knowledgator/gliner-x-small (GLiNER-X, Hindi)](https://huggingface.co/knowledgator/gliner-x-small)
- [ai4bharat/IndicNER](https://huggingface.co/ai4bharat/IndicNER)
- [GLiNER NAACL 2024 paper](https://aclanthology.org/2024.naacl-long.300/)
- [GLiNER-2 (2025)](https://arxiv.org/html/2507.18546v1)
- [JPIS (ICASSP 2024)](https://github.com/VinAIResearch/JPIS)
- [Fine-Tuning Medium-Scale LLMs for Joint Intent and Slot Filling, COLING 2025](https://aclanthology.org/2025.coling-industry.21.pdf)
- [ONNX Runtime mobile deployment guide](https://onnxruntime.ai/docs/tutorials/mobile/)
