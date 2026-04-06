# Hark NLU Architecture — Intent Routing Design

> Status: Implemented — EmbeddingGemma 308M replaced all-MiniLM-L6-v2 and FunctionGemma for intent routing
> Created: 2026-03-30
> History: This doc was written as a design proposal. The architecture was adopted with EmbeddingGemma (instead of all-MiniLM-L6-v2) and Qwen3 for slot filling (instead of regex-only). Read as a design rationale document, not current API docs.

---

## Problem With The Current Approach

Hark currently uses FunctionGemma 270M (a generative LLM) to route voice commands
to OACP actions. This is the wrong tool for the job:

- **Slow** — generative inference on a mid-range ARM chip takes 1-3 seconds
- **Unreliable** — Tier 2 parameter extraction hallucinates or refuses regularly
- **Fragile** — model output requires robust JSON repair to be parseable
- **Overkill** — "turn off flashlight" is a classification problem, not a generation problem

Google Assistant and Siri do not use generative models for command routing. They
use intent classifiers and slot taggers — fundamentally different model types.

---

## Prior Art: What Google Assistant and Siri Actually Use

Neither Google Assistant nor Siri uses a generative LLM for command routing.
Both use specialized NLU models optimized for classification and slot filling.

### Google Assistant

| Step | Technique |
|---|---|
| Intent classification | BERT-based transformer classifier (multi-task: domain + intent jointly) |
| Slot/entity filling | BiLSTM-CRF sequence tagger (extracts dates, names, locations from utterance) |
| Fallback / open queries | Separate generative path, not the same model |
| On-device vs cloud | Distilled lightweight models on-device; full models in cloud |

Key papers: multi-domain joint semantic frame parsing, SLU task architecture
(Google Patents US20170372199A1, US11183175B2).

### Siri

| Step | Technique |
|---|---|
| Intent classification | Transformer encoder + classification head (fine-tuned on assistant-directed queries) |
| Entity recognition | Semantic parser + NER tightly coupled with intent detection |
| On-device | Core ML, fully on-device on recent Apple hardware |
| Privacy | No raw audio or transcript leaves the device; federated learning for model updates |

Key source: Apple Machine Learning Research — "Hey Siri" and federated
personalization papers (machinelearning.apple.com).

### What both tell us

> **Generative models do not appear in the command-routing hot path of any major
> voice assistant.** LLMs may be used for open-ended queries, training data
> generation, or conversational fallback — but never for "turn off flashlight"
> → intent classification.

The right model type for intent routing is an **encoder** (BERT family), not a
**decoder** (GPT/Gemma family). Encoders produce a fixed-size vector representing
meaning. Decoders generate tokens one at a time — inherently slower and
non-deterministic for what is fundamentally a lookup problem.

Hark's proposed embedding approach (all-MiniLM-L6-v2) is an encoder-only model,
consistent with what the industry actually ships.

### Why Siri feels better (for personal/device tasks)

This is a common observation and worth understanding — it is not about the NLU
model quality, it is about **privileged OS access**:

- Siri has direct API access to Contacts, Calendar, Messages, Reminders, Phone
- No intent needs to be dispatched — the OS processes it internally, sub-100ms
- Hardware Neural Engine on Apple Silicon (A-series, M-series) runs Core ML
  models at extremely low latency
- Federated learning improves Siri's model on your specific voice and vocabulary
  without sending data to Apple

Google Assistant is better at:
- Open-ended knowledge queries (Google's knowledge graph)
- Android app breadth and cross-app actions
- Multilingual and accent robustness (larger training set)
- Web-backed answers

**Neither is universally better.** Siri wins on personal/device tasks because it
has OS-level privileges. Google wins on knowledge/search tasks. The OACP
philosophy is closer to Siri's model: apps register capabilities, the assistant
dispatches to them with direct intent access — no API middleman.

### Open source models that combine both approaches

The open source ecosystem has reproduced and in some cases improved on both
techniques:

| Model | Technique | vs Google/Siri | Size | Notes |
|---|---|---|---|---|
| **DIET** (Rasa) | Transformer encoder + CRF jointly | Combines both approaches | ~50MB | Purpose-built for voice assistants |
| **JointBERT** | BERT + joint intent+slot | Matches Google's multi-task approach | ~110MB | Strong on SNIPS/ATIS benchmarks |
| **DistilBERT** fine-tuned | Intent classification | Slightly below BERT, much faster | ~66MB | Good zero-shot with sentence-transformers |
| **RoBERTa** fine-tuned | Intent classification | Stronger than base BERT | ~125MB | Best accuracy in this family |
| **all-MiniLM-L6-v2** | Semantic similarity | Weaker on intent, faster | ~23MB | Our current proposal — zero-shot |

**DIET** is the most directly relevant for Hark. It does what both Google and
Siri do in a single forward pass:

```
Utterance
    │
    ▼
Transformer encoder  ←── Siri-style: shared encoder, on-device, fast
    │
    ├─► Classification head  →  intent label  ("set_alarm")
    │
    └─► CRF sequence tagger  →  entity spans  ←── Google-style: BiLSTM-CRF
                                ("7am" → time, "bedroom" → location)
```

One model, one forward pass, intent + entities simultaneously.

### DIET vs all-MiniLM-L6 for Hark

| | all-MiniLM-L6 | DIET (Rasa) |
|---|---|---|
| Intent accuracy | Good (zero-shot) | Better (with examples) |
| Entity extraction | Separate regex step needed | Built-in, same model |
| New OACP apps (zero-shot) | Yes — no training needed | Needs examples per intent |
| `oacp.json` examples field | Not used | Used as few-shot training data |
| Size | 23MB | ~50MB |
| ONNX export | Yes | Yes |
| Complexity | Low | Medium |

The key trade-off: `all-MiniLM-L6` works with any new OACP app out of the box
(zero-shot). DIET gives better accuracy but needs the `examples` array from
`oacp.json` to know what each intent looks like — which is exactly what that
field was designed for.

**Recommendation**: start with `all-MiniLM-L6` (simpler, zero-shot, proven),
evaluate DIET once there is a real eval set of OACP commands to measure against.

---

## Core Insight: Two Different Problems

Voice assistant requests fall into two distinct categories that require different
solutions:

```
"turn off flashlight"     →  TOOL INVOCATION  →  classification + dispatch
"set alarm for 7am"       →  TOOL INVOCATION  →  classification + slot fill
"tell me a joke"          →  CONVERSATION     →  generation or OACP delegation
"what is 15% of 84"       →  CONVERSATION     →  generation or OACP delegation
```

Mixing these into one LLM call is the root cause of both the speed and reliability
problems.

---

## Proposed Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Transcript (from STT)              │
└─────────────────────────┬───────────────────────────┘
                          │
                          ▼ ~1ms
┌─────────────────────────────────────────────────────┐
│              Stage 0: BM25 Heuristic                 │
│  keyword/alias/example matching (already exists)     │
│  clear winner (score gap ≥ 3) → skip everything      │
└──────┬──────────────────────────────────────────────┘
       │ ambiguous
       ▼ ~5-15ms
┌─────────────────────────────────────────────────────┐
│         Stage 1: Sentence Embedding Classifier       │
│                                                      │
│  Model: all-MiniLM-L6-v2 (ONNX, ~23MB)              │
│  Runtime: onnxruntime Flutter plugin                 │
│                                                      │
│  - Embed transcript once                             │
│  - Compare cosine similarity vs pre-embedded         │
│    action descriptions + examples + aliases          │
│  - Re-embed actions only when registry changes       │
│                                                      │
│  Output:                                             │
│    confidence ≥ 0.75  →  TOOL MATCH  →  Stage 2     │
│    confidence < 0.35  →  CONVERSATION →  Stage 3     │
│    0.35 – 0.75        →  AMBIGUOUS   →  Stage 2      │
│                           (ask for clarification     │
│                            or try with best match)   │
└──────┬─────────────────────────────┬────────────────┘
       │ tool match                  │ conversation
       ▼ ~5ms                        ▼
┌──────────────────┐     ┌───────────────────────────┐
│  Stage 2:        │     │  Stage 3: Conversation     │
│  Param Extractor │     │  Router                    │
│                  │     │                            │
│  - Regex rules   │     │  Priority:                 │
│    per param     │     │  1. OACP ecosystem check   │
│    type (time,   │     │     (is there a joke app?  │
│    number, name, │     │      a calculator app?)    │
│    location)     │     │     → dispatch as OACP tool│
│  - Date parsing  │     │                            │
│    (intl pkg)    │     │  2. Cloud LLM fallback     │
│  - Entity hints  │     │     (BYOK: user's own key) │
│    from oacp.json│     │     OpenAI / Gemini /       │
│                  │     │     Anthropic               │
│  → dispatch      │     │                            │
└──────────────────┘     │  3. On-device generative   │
                         │     (future: Gemma 2B for  │
                         │      high-end devices)      │
                         │                            │
                         │  4. Graceful decline        │
                         │     "I can only control     │
                         │      apps right now"        │
                         └───────────────────────────┘
```

---

## Stage 1: Sentence Embedding Classifier

### Why embeddings, not a fine-tuned classifier

OACP actions come from third-party apps discovered at runtime. You cannot
pre-train a classifier on actions that don't exist yet. Embeddings are
**zero-shot** — they work with any new OACP app automatically because they measure
semantic distance rather than matching learned labels.

### Model choice

**all-MiniLM-L6-v2** (sentence-transformers family):

| Property | Value |
|---|---|
| Size | ~23MB (quantized ONNX) |
| Embedding dim | 384 |
| Inference latency | ~10ms on Cortex-A55 |
| Context | 256 tokens (more than enough for short commands) |
| License | Apache 2.0 |

Alternative: **paraphrase-MiniLM-L3-v2** (~17MB, ~6ms, slightly lower quality).

### Pre-embedding strategy

Action descriptions do not change until the registry updates. Pre-embed once on
registry change, cache vectors in memory. Transcript embedding is the only
per-request compute.

```
registry changed?
    yes → embed all action (description + top 3 examples + aliases joined)
    no  → use cached vectors

per request:
    embed(transcript) → compare cosine sim against all cached vectors → top match
```

### Confidence thresholds

These are starting points — tune against a real eval set:

| Score | Decision |
|---|---|
| ≥ 0.75 | High confidence — route to tool |
| 0.50 – 0.75 | Moderate — route to tool, flag for logging |
| 0.35 – 0.50 | Low — ask clarification or try conversation |
| < 0.35 | No match — route to conversation |

---

## Stage 2: Parameter Extraction

LLMs are bad at this because they generate tokens one by one and can hallucinate
values. Slot filling is a solved problem with deterministic tools:

### Per-type extraction rules

| Param type | Extraction method |
|---|---|
| `time` | `intl` DateFormat parsing + regex (`7am`, `half past 6`, `in 10 minutes`) |
| `duration` | Regex (`10 minutes`, `2 hours`, `30 seconds`) |
| `number` | `int.tryParse`, word-to-number (`five` → `5`) |
| `location` | Entity snapshot lookup first, then noun phrase after preposition |
| `string` | Remaining transcript after removing matched intent words |
| `boolean` | Keyword match (`on/off`, `yes/no`, `enable/disable`) |
| `enum` | Fuzzy match against allowed values from `parametersSchema` |

Entity snapshots from `oacp.json` (`entitySnapshot` field) give per-app value
lists (alarm names, playlist names, contact names) that enable exact matching.

### Fallback ordering

1. Regex / rule-based extraction
2. Entity snapshot lookup
3. Examples from `oacp.json` (pick closest)
4. Leave parameter empty and let the app ask

---

## Stage 3: Conversation Router

### The OACP-first principle

Before reaching for a cloud LLM, check whether any installed OACP app can handle
the conversational request. This keeps Hark as a router, not a brain.

Examples:
- "tell me a joke" → check registry for `tell_joke` capability → dispatch
- "what's the weather" → `get_weather` OACP capability (Breezy Weather) → dispatch
- "calculate 15% of 84" → check for calculator OACP app → dispatch
- "play something relaxing" → `play_music` with mood parameter → dispatch

Only requests that no OACP app handles should reach the cloud fallback.

### Cloud fallback (BYOK)

Users who want open-ended conversation provide their own API key. The request is
sent to their chosen provider. Hark passes:

- the transcript
- a system prompt describing Hark's purpose
- the list of available OACP action names (so the cloud model can suggest routing)

This is the only path where `OACP.md` content is useful — cloud models have the
context budget to consume it.

Provider priority (user-configurable):
1. OpenAI-compatible self-hosted (Ollama on PC/server)
2. Gemini (Google AI Studio key)
3. OpenAI
4. Anthropic Claude

### Graceful decline

If no OACP app matches and no cloud key is configured:

> "I can control your apps but I'm not set up for open-ended questions yet.
>  Add an API key in Settings to enable that."

---

## What This Replaces

| Current | Proposed |
|---|---|
| FunctionGemma 270M for tool selection | Sentence embeddings (Stage 1) |
| FunctionGemma 270M for param extraction | Regex / entity rules (Stage 2) |
| No conversation support | OACP delegation + BYOK cloud (Stage 3) |
| 1-3 second latency on mid-range phones | <50ms for tool invocation |

FunctionGemma (or any on-device generative model) moves to an **optional** role:
- Conversation fallback on high-end devices
- Handling ambiguous multi-step commands
- Never in the tool-invocation hot path

---

## Implementation Plan

### Phase A: Embedding classifier (replaces Tier 1 + Tier 2 model calls)

1. Add `onnxruntime` Flutter dependency
2. Bundle `all-MiniLM-L6-v2` ONNX model in app assets (~23MB)
3. Implement `EmbeddingService` — loads model, exposes `embed(String) → List<double>`
4. Implement `EmbeddingResolver implements CommandResolver`
   - pre-embeds registry on change
   - cosine similarity ranking
   - confidence-gated routing
5. Replace `LocalGemmaResolver` as default resolver (keep gemma resolver as
   fallback for high-end devices that want it)
6. Implement deterministic param extractor (replaces Tier 2 model call)

### Phase B: Conversation router

1. Add conversation vs tool-invocation classifier (simple: if Stage 1 confidence
   < 0.35, it's conversation)
2. Add OACP conversation delegation (check registry for conversational capabilities)
3. Add BYOK settings screen (provider URL + API key, stored in secure storage)
4. Add cloud fallback HTTP client (OpenAI-compatible endpoint)

### Phase C: On-device conversation (optional, high-end devices)

1. Gate behind device capability check (RAM ≥ 6GB, chip tier)
2. Keep Gemma 2B for conversation only — never for tool routing

---

## Open Questions

- **Embedding model size trade-off**: 23MB in app assets is reasonable but adds
  to APK size. Could be downloaded on first run like the current LLM model.
- **Confidence threshold tuning**: The 0.75/0.35 values need empirical validation
  against a real OACP command eval set.
- **Ambiguous commands**: "turn it off" with no prior context — embeddings won't
  help. May need conversational context (last dispatched action) to resolve.
- **Multi-intent utterances**: "set an alarm and turn off the lights" — out of
  scope for now, single-intent only.
- **Wake word integration**: Wake word detection runs before this pipeline.
  Architecture assumes transcript arrives already segmented and cleaned.
