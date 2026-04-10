# Skip model downloads during local development

Hark downloads ~830 MB of model files on first launch. When developing
locally, you can push the models directly to the device via adb and skip
the download entirely.

## Prerequisites

- A debug build of Hark installed on the device (`flutter build apk --debug && adb install -r ...`)
- The app must have been **launched at least once** so Android creates the app-private data directory
- `adb` connected to the device (`adb devices` shows it)

## Step 1 — Download the models to your workstation (one-time)

```bash
mkdir -p ~/hark-dev-models/embedder ~/hark-dev-models/slot-filler

# EmbeddingGemma 300M — ONNX format, used by flutter_embedder
cd ~/hark-dev-models/embedder
curl -LO "https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model_q4.onnx"
curl -LO "https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model_q4.onnx_data"
curl -LO "https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/tokenizer.json"

# Qwen3 0.6B — LiteRT-LM format, used by flutter_gemma
cd ~/hark-dev-models/slot-filler
curl -LO "https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm"
```

Total: ~830 MB. Keep these files around — they work across reinstalls.

## Step 2 — Push to the device

The models live in the app's private storage, which is only accessible
via `adb shell run-as` on debug builds. The `run-as` + `cat` stream
pipe pattern bypasses Android's scoped-storage restrictions.

```bash
PKG=com.oacp.hark

# Create the flutter_embedder cache directory structure
adb shell "run-as $PKG sh -c 'mkdir -p files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX/onnx'"

# Push the embedder files
adb shell "run-as $PKG sh -c 'cat > files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX/onnx/model_q4.onnx'" \
  < ~/hark-dev-models/embedder/model_q4.onnx

adb shell "run-as $PKG sh -c 'cat > files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX/onnx/model_q4.onnx_data'" \
  < ~/hark-dev-models/embedder/model_q4.onnx_data

adb shell "run-as $PKG sh -c 'cat > files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX/tokenizer.json'" \
  < ~/hark-dev-models/embedder/tokenizer.json

# Push the slot-filler model
adb shell "run-as $PKG sh -c 'cat > app_flutter/Qwen3-0.6B.litertlm'" \
  < ~/hark-dev-models/slot-filler/Qwen3-0.6B.litertlm
```

## Step 3 — Create the flutter_embedder metadata file

flutter_embedder's `ModelManager` checks for a `model.json` manifest to
know the model is installed. Create it manually:

```bash
adb shell "run-as $PKG sh -c 'cat > files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX/model.json'" << 'EOF'
{"model_id":"onnx-community/embeddinggemma-300m-ONNX","onnx_file":"onnx/model_q4.onnx"}
EOF
```

## Step 4 — Launch and verify

```bash
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity
```

Watch logcat for the load phases:

```bash
adb logcat -s flutter | grep HarkLoadPerf
```

You should see `embedding.total` with `path: cache_hit` and
`slot_filling.total` with `path: cache_hit` — no download phase.

## Notes

- **Debug builds only.** `adb shell run-as` requires `android:debuggable="true"` which Flutter debug builds include by default. Release builds are not accessible this way.
- **Survives reinstalls.** `adb install -r` preserves the app's private data directory, so you only need to push models once per device. A full `adb uninstall && adb install` wipes the cache.
- **Model versions are pinned.** The URLs above match what `EmbeddingNotifier.modelId` and `SlotFillingNotifier.modelUrl` reference in the Dart code. If those change, update the URLs here.
- **XNNPack cache is auto-generated.** The slot filler's `Qwen3-0.6B.litertlm.xnnpack_cache` file is created automatically by LiteRT on first model load. You don't need to push it — it generates in ~5 seconds on first run.

## File layout reference

After a successful push, the device should have:

```
/data/user/0/com.oacp.hark/
├── files/
│   └── flutter_embedder/
│       └── onnx-community_embeddinggemma-300m-ONNX/
│           ├── model.json                    (213 bytes)
│           ├── tokenizer.json                (20 MB)
│           └── onnx/
│               ├── model_q4.onnx             (519 KB)
│               └── model_q4.onnx_data        (197 MB)
├── app_flutter/
│   ├── Qwen3-0.6B.litertlm                  (614 MB)
│   ├── embedding_cache.json                  (auto-generated, ~800 KB)
│   ├── model_load_logs/                      (auto-generated)
│   └── inference_logs/                       (auto-generated)
└── cache/
    └── Qwen3-0.6B.litertlm.xnnpack_cache    (auto-generated)
```
