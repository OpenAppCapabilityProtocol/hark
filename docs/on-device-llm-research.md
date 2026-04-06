# Best Flutter + on-device LLM combo for Android function calling

**The winning combination is `flutter_gemma` + Qwen3 0.6B (LiteRT), with FunctionGemma 270M as a fast-path option.** Flutter_gemma is the only package with production-validated Android support, native function calling, and active maintenance from a Google Developer Expert. Qwen3 0.6B scores **0.880** on tool-calling benchmarks — outperforming models 6× its size — making it the strongest sub-1B model available without fine-tuning. However, a critical finding: the **5-second latency target is unrealistic** for Qwen3 0.6B on the Dimensity 7060, where realistic end-to-end inference runs **8–15 seconds**. FunctionGemma 270M at **284MB** can meet the 5-second target but scores only 0.640 without fine-tuning. A dual-model strategy — FunctionGemma for simple slot fills, Qwen3 for complex ones — is the optimal architecture.

---

## The Flutter package landscape is surprisingly thin

Of seven packages evaluated, only **one** is production-ready for Android function calling. The rest are either too new, iOS-only, or lack tool-calling support entirely.

**`flutter_gemma`** dominates with **278 pub.dev likes, 361 GitHub stars**, a verified publisher (Google Developer Expert Denis Denisov), and weekly releases through March 2026. It uses MediaPipe GenAI v0.10.33 as its inference backend, which brings proper Android GPU delegation via OpenCL/OpenGL ES (not Vulkan). Function calling is a first-class API: the model emits `FunctionCallResponse` objects with parsed `name` and `args` fields — no manual JSON extraction required.

**`llamadart`** (v0.3.0, 2 likes) is architecturally promising with llama.cpp GGUF support, Dart Native Assets for zero-config setup, and newly-added `ToolDefinition` + `ChatSession` APIs for tool calling. Its claimed Vulkan support on Android is **unverified by any independent user** and is dangerous on the Dimensity 7060's PowerVR GPU (see hardware section). Watch this package — it may mature into the best GGUF option by late 2026.

**`edge_veda`** has the most impressive feature set on paper (grammar-constrained JSON, RAG pipeline, tool chains) but its **Android support is fabricated**: the pub.dev listing claims Android, while the GitHub README explicitly states "iOS only — Android support is on the roadmap." All benchmarks are on iPhone A16 Bionic. Do not use this for Android.

**`llamafu`** (v0.1.0, 0 likes, published days ago) claims GBNF grammar + tool calling + JSON schema validation — exactly what you want — but with zero community validation, it is too risky for production. **`fllama`** (Telosnex, 185 stars) is battle-tested but has no pub.dev presence, GPL v2 licensing, and no function calling API. **`llama_cpp_dart`** (76 likes, 283 stars) is the most popular llama.cpp binding but requires manually building native libraries and has no tool-calling support.

### Package comparison

| Package | Version | Likes/Stars | Function calling | Android GPU | Model format | Status |
|---------|---------|-------------|-----------------|-------------|-------------|--------|
| **flutter_gemma** | 0.12.2 | **278 / 361** | ✅ Native API | ✅ MediaPipe GPU | LiteRT (.litertlm, .task) | **Production-ready** |
| llamadart | 0.3.0 | 2 / 41 | ✅ ToolDefinition | ⚠️ Vulkan (unverified) | GGUF | Early beta |
| llamafu | 0.1.0 | 0 / new | ✅ Tool + GBNF grammar | ❓ Unverified | GGUF | Days old — avoid |
| edge_veda | 2.1.0 | 5 / low | ✅ Excellent API | ❌ **iOS-only** | GGUF | **Android broken** |
| llama_cpp_dart | 0.2.2 | 76 / 283 | ❌ Manual prompting | ⚠️ Self-compiled | GGUF | Mature but limited |
| fllama | git-only | 4 / 185 | ❌ None | ❌ CPU only | GGUF | GPL license |
| llm_llamacpp | 0.1.9 | 1 / low | ⚠️ Prompt convention | ⚠️ Self-compiled | GGUF | Niche |

---

## The Dimensity 7060 is CPU-only for LLM inference

The Motorola G56's MediaTek Dimensity 7060 has three compute paths — and **two are dead ends** for LLM inference. This fundamentally shapes model and package selection.

The **GPU is PowerVR BXM-8-256** (not Mali-G68 MC4 as sometimes reported). Vulkan drivers on this GPU are catastrophically broken: documented crashes in PPSSPP, display corruption on Android 14/15, and GSMArena confirmed the GPU is "missing crucial Vulkan extensions" with 3DMark Vulkan tests refusing to run. Any llama.cpp Vulkan backend (llamadart, llama_cpp_dart) **will not work reliably** on this device. However, MediaPipe's GPU delegate uses OpenCL/OpenGL ES, which may still function — this gives `flutter_gemma` a potential GPU advantage that llama.cpp-based packages cannot access.

The **NPU (APU 550)** is a basic-tier accelerator for traditional ML tasks. MediaTek's LiteRT NeuroPilot Accelerator for LLM inference targets only **Dimensity 9300/9400/9500+** flagship chips. The APU 550 cannot run LLM inference.

The **CPU** (2× Cortex-A78 @ 2.6GHz + 6× Cortex-A55 @ 2.0GHz) is the only viable path. Based on scaled benchmarks from the Vivo X300 Pro (Dimensity 9300) and Snapdragon 695 devices running similar workloads, estimated performance for **Qwen3 0.6B Q4 on Dimensity 7060 CPU** is:

| Metric | Optimistic | Realistic | With throttling |
|--------|-----------|-----------|----------------|
| Prefill speed | 50–80 tok/s | 35–50 tok/s | 20–30 tok/s |
| Decode speed | 8–12 tok/s | 4–7 tok/s | 2–4 tok/s |
| Slot-fill latency (250 in, 50 out) | **~8s** | **~12s** | **~20s** |

**RAM is not a constraint.** A 0.6B Q4_K_M model uses ~480–530MB total (weights + KV cache + buffers), leaving 4–5GB free on a 6–8GB device after Android OS overhead.

---

## Qwen3 0.6B leads accuracy; FunctionGemma leads speed

For sub-1B models with commercial-friendly licenses and no fine-tuning required, the field narrows to essentially two contenders — plus one watch-list model.

**Qwen3 0.6B** (Apache 2.0) scores **0.880 on the MikeVeerman tool-calling benchmark** — a 20-run CPU test across 12 prompts of varying difficulty. This outperforms Phi-4-mini (3.8B, 0.780), SmolLM3 (3B, 0.710), and even Qwen3 4B (0.880, but with impractical 63s thinking-mode latency). Qwen3's native `/no_think` mode suppresses chain-of-thought tokens, critical for keeping output short. The model is available in LiteRT format (**586MB**, dynamic int8) from `litert-community/Qwen3-0.6B` on HuggingFace, and as **397MB Q4_K_M GGUF** from Unsloth. Its 32K context window is more than sufficient for the ~300-token slot-filling prompt.

**FunctionGemma 270M** (Gemma license) is purpose-built for function calling with dedicated control tokens (`<start_function_call>`, `<end_function_call>`). At **284MB** in LiteRT int4 format, it is the smallest and fastest option — **435ms** average on desktop CPU, scaling to an estimated **1.5–3s on the Dimensity 7060**. The catch: it scores only **0.640** without fine-tuning, climbing to **0.850** with task-specific fine-tuning on your API definitions. For the constrained slot-filling task (single schema, parameter extraction), its effective accuracy is likely higher than the general benchmark suggests, since the benchmark includes harder judgment tasks like irrelevance detection.

**Qwen3.5 0.8B** (Apache 2.0, released March 2026) uses a hybrid Gated DeltaNet + Gated Attention architecture with **262K native context**. It's multimodal (text + image + video) at 0.8B parameters and supports tool calling via Qwen3 templates. A LiteRT variant exists on litert-community. This is worth evaluating as it may offer better accuracy than Qwen3 0.6B with only modestly larger size (~500MB Q4), though tool-calling benchmarks specific to this model are not yet published. A known issue: the 0.8B model is "prone to thinking loops" requiring careful sampling parameters.

### Model comparison

| Model | Params | Format / Size | Tool-call score | License | Latency (est. phone) | Best for |
|-------|--------|--------------|----------------|---------|---------------------|----------|
| **Qwen3 0.6B** | 0.6B | LiteRT 586MB / GGUF Q4 397MB | **0.880** | Apache 2.0 ✅ | ~8–15s | Complex slot filling |
| **FunctionGemma 270M** | 0.27B | LiteRT int4 284MB | 0.640 (0.850 fine-tuned) | Gemma ✅ | **~2–4s** | Simple extraction |
| Qwen3.5 0.8B | 0.8B | LiteRT ~600MB / GGUF Q4 ~500MB | TBD (promising) | Apache 2.0 ✅ | ~10–18s | Future upgrade |
| Hammer 2.1 0.5B | 0.5B | GGUF Q4 ~380MB | BFCL-v3 SOTA at scale | **CC-BY-NC ❌** | ~6–10s | Research only |
| xLAM-1b-fc-r | 1.35B | GGUF Q4_K_M 873MB | 78.94% BFCL | **CC-BY-NC ❌** | ~15–25s | Research only |
| LFM2.5 1.2B | 1.17B | GGUF Q4 ~750MB | **0.920** | Liquid AI (check) | ~5–8s | If size budget allows |
| DeepSeek R1 1.5B | 1.5B | GGUF Q4 ~900MB | 0.720 | MIT ✅ | ~12–20s | Not recommended |
| Gemma 3 1B | 1B | LiteRT 529MB | 0.550 | Gemma ✅ | ~8–12s | Not recommended |

---

## The optimal architecture: dual-model with flutter_gemma

Given the tension between accuracy (Qwen3) and speed (FunctionGemma), the best practical architecture for Hark uses **both models loaded in flutter_gemma**, with Layer 1's confidence score routing between them.

**Fast path — FunctionGemma 270M (284MB):** When Layer 1 (EmbeddingGemma) returns a high-confidence intent match (e.g., cosine similarity >0.92), use FunctionGemma for immediate slot filling. For unambiguous single-parameter commands like "set a timer for 5 minutes" or "call Mom," FunctionGemma's constrained architecture extracts parameters rapidly at **~2–4 seconds**. This covers the majority of voice assistant interactions.

**Accurate path — Qwen3 0.6B (586MB):** When Layer 1 returns lower confidence or the matched schema has complex/optional parameters, route to Qwen3 0.6B with `/no_think` mode. This handles ambiguous transcripts like "remind me about the dentist thing next Tuesday morning" where multiple parameters need extraction from context. Expected latency is **8–15 seconds**, which should be presented to the user with a streaming progress indicator.

**Total model footprint:** 284MB + 586MB = **870MB** on disk, ~530MB peak RAM (only one model active at a time). Well within the 6–8GB device constraints.

### Recommended quantization and download paths

For flutter_gemma (LiteRT format), use pre-converted models from litert-community on HuggingFace:

- **FunctionGemma 270M**: `https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task` (284MB, int4 XNNPACK)
- **Qwen3 0.6B**: `https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm` (586MB, dynamic int8)

If you later switch to a GGUF-based package (llamadart/llamafu), use **Q4_K_M** from Unsloth (`unsloth/Qwen3-0.6B-GGUF`, 397MB). Avoid Q2/Q3 quantizations — below Q4, structured JSON output degrades noticeably in sub-1B models. The Unsloth **UD-Q4_K_XL** variant (405MB) provides marginally better accuracy by upcasting critical layers.

---

## Working code for the winning combination

```dart
import 'package:flutter_gemma/flutter_gemma.dart';

/// Hark Layer 2: Slot-filling service using flutter_gemma
class SlotFillingService {
  static const _functionGemmaUrl =
      'https://huggingface.co/sasha-denisov/function-gemma-270M-it/'
      'resolve/main/functiongemma-270M-it.task';
  static const _qwen3Url =
      'https://huggingface.co/litert-community/Qwen3-0.6B/'
      'resolve/main/Qwen3-0.6B.litertlm';

  /// Install both models (call once, supports resume on interrupt)
  Future<void> installModels() async {
    await FlutterGemma.installModel(modelType: ModelType.functionGemma)
        .fromNetwork(_functionGemmaUrl)
        .install();
    await FlutterGemma.installModel(modelType: ModelType.qwen)
        .fromNetwork(_qwen3Url)
        .install();
  }

  /// Extract parameters from transcript using the matched OACP schema.
  /// [useFastPath] routes to FunctionGemma (fast) vs Qwen3 (accurate).
  Future<Map<String, dynamic>?> extractSlots({
    required Map<String, dynamic> oacpSchema,
    required String transcript,
    required bool useFastPath,
  }) async {
    // Select model based on routing decision from Layer 1
    final modelType =
        useFastPath ? ModelType.functionGemma : ModelType.qwen;

    final model = await FlutterGemma.getActiveModel(
      maxTokens: 512,
      preferredBackend: PreferredBackend.gpu, // Falls back to CPU if needed
    );

    // Define the slot-filling "tool" from the OACP action schema
    final tools = _buildToolsFromSchema(oacpSchema);

    final chat = await model.createChat(
      temperature: 0.1,       // Low temperature for deterministic extraction
      topK: 1,                // Greedy decoding for structured output
      tools: tools,
      supportsFunctionCalls: true,
      toolChoice: ToolChoice.required, // Force a function call
      modelType: modelType,
    );

    // Construct the extraction prompt
    final prompt = useFastPath
        ? transcript // FunctionGemma: minimal prompt, schema in tools
        : '/no_think\nExtract parameters from this voice command '
          'into the function call. Voice transcript: "$transcript"';

    await chat.addQueryChunk(
      Message.text(text: prompt, isUser: true),
    );

    // Collect the response
    Map<String, dynamic>? result;
    await for (final response in chat.generateChatResponseAsync()) {
      if (response is FunctionCallResponse) {
        result = {
          'action': response.name,
          'parameters': response.args,
        };
        break; // Single-turn: stop after first function call
      }
    }

    return result;
  }

  /// Convert OACP schema to flutter_gemma Tool definitions
  List<Tool> _buildToolsFromSchema(Map<String, dynamic> schema) {
    // Map your OACP action schema to flutter_gemma's Tool format
    return [
      Tool(
        name: schema['action_name'] as String,
        description: schema['description'] as String,
        parameters: (schema['parameters'] as Map<String, dynamic>)
            .map((key, value) => MapEntry(
                  key,
                  ToolParameter(
                    type: value['type'] as String,
                    description: value['description'] as String,
                    required: value['required'] as bool? ?? false,
                  ),
                )),
      ),
    ];
  }
}

// Usage in your voice assistant flow:
final slotFiller = SlotFillingService();

// Layer 1 matched intent "set_timer" with high confidence (0.95)
final result = await slotFiller.extractSlots(
  oacpSchema: {
    'action_name': 'set_timer',
    'description': 'Set a countdown timer for a specified duration',
    'parameters': {
      'duration_minutes': {
        'type': 'integer',
        'description': 'Timer duration in minutes',
        'required': true,
      },
      'label': {
        'type': 'string',
        'description': 'Optional label for the timer',
        'required': false,
      },
    },
  },
  transcript: 'set a timer for five minutes for the pasta',
  useFastPath: true, // High confidence → FunctionGemma (fast)
);
// result: {"action": "set_timer", "parameters": {"duration_minutes": 5, "label": "pasta"}}
```

> **Note:** The exact `Tool` and `ToolParameter` class names may differ slightly in flutter_gemma's API — consult the current v0.12.x documentation. The `FunctionCallResponse` pattern (name + args) is confirmed from the package source.

---

## Critical gotchas and blockers to know

**Latency is the biggest risk.** The 5-second target is achievable only with FunctionGemma 270M on simple commands. Qwen3 0.6B will realistically take 8–15 seconds per inference on the Dimensity 7060 CPU. Mitigations: minimize prompt tokens (compress your OACP schema representation to ~50–80 tokens instead of 100–200), use streaming to show progress, and keep the model pre-loaded in memory to eliminate the 0.5–1.5s cold-start penalty.

**Thermal throttling kills sustained performance.** After ~90 seconds of continuous inference on mid-range ARM, token generation drops from ~8 tok/s to ~1.2 tok/s. For a voice assistant processing multiple commands in sequence, implement a thermal-aware scheduling system with cooldown periods between inferences.

**LiteRT format lock-in.** Choosing flutter_gemma means you use LiteRT models, not GGUF. You cannot use GBNF grammar-constrained generation (a llama.cpp feature that guarantees valid JSON output). Flutter_gemma relies entirely on the model producing valid function calls natively. Qwen3 0.6B at 0.880 accuracy is reliable enough for production, but implement JSON validation and retry logic for the ~12% failure rate.

**Vulkan is a trap on this device.** The PowerVR BXM-8-256 GPU has documented Vulkan driver bugs causing crashes, display corruption, and missing extensions. Any package claiming Vulkan acceleration (llamadart, llama_cpp_dart with custom build) will be unreliable. Flutter_gemma's MediaPipe backend sidesteps this by using OpenCL/OpenGL ES delegates, which have broader driver support on PowerVR hardware.

**License landmines.** Hammer 2.1 0.5B and Salesforce xLAM-1b-fc-r both use **CC-BY-NC-4.0** — non-commercial only. These are viable for prototyping but cannot ship in a production app. Stick with Apache 2.0 (Qwen3) or Gemma Terms (FunctionGemma) for commercial deployment.

**No published Flutter LLM benchmarks exist.** Despite extensive searching, there are no academic papers or blog posts comparing Flutter LLM packages for on-device inference on Android mid-range phones. All performance estimates in this report are extrapolated from llama.cpp benchmarks on comparable ARM hardware and the LiteRT benchmark suite on flagship devices.

**Qwen3.5 0.8B is promising but risky.** Released March 2026 with a hybrid DeltaNet architecture and 262K context, it should offer better tool-calling accuracy than Qwen3 0.6B. A LiteRT variant exists on litert-community. However, it has a known bug causing infinite thinking loops and its tool-calling scores are not yet published. Evaluate it once flutter_gemma confirms support.

---

## Conclusion: what to ship and what to plan for

**Ship now:** `flutter_gemma` + FunctionGemma 270M (fast path) + Qwen3 0.6B (accurate path), routing based on Layer 1 confidence. Total disk footprint is 870MB. This gives you sub-5-second responses for ~70% of simple voice commands and reliable extraction for complex ones at 8–15 seconds.

**Plan for Q3 2026:** When fine-tuning infrastructure is ready, fine-tune FunctionGemma 270M on your exact OACP action schemas. Google's published data shows accuracy jumps from **0.640 → 0.850** with domain-specific fine-tuning, and Distil Labs demonstrated 0.90–0.97 accuracy on multi-turn tasks. A fine-tuned FunctionGemma could handle nearly all slot filling under 5 seconds, eliminating the need for the Qwen3 fallback path.

**Watch for next:** `llamadart` maturing to production readiness (bringing GGUF flexibility + grammar-constrained JSON), `edge_veda` shipping real Android support (bringing the best overall architecture), and Qwen3.5 0.8B tool-calling benchmarks confirming its improvement over Qwen3 0.6B. The LFM2.5 1.2B from Liquid AI (0.920 agent score, 7× faster than comparably-scored models) deserves evaluation if your size budget can stretch to ~750MB for a single model — its non-transformer architecture offers dramatically better CPU throughput.