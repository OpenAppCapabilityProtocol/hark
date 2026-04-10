# Persistent model backup + contributor adb side-load

**Status**: design doc, not yet implemented. Part of Phase 2b (load-time optimizations) of the Hark near-term plan. See `~/.claude/plans/async-twirling-galaxy.md` for the parent plan and `docs/plans/load-time-baseline.md` for the context.

**Owner**: deferred to Phase 2b implementation slice.

---

## The problem

Hark currently downloads two large model files on first launch:

| Model | Runtime | Size | Purpose |
|---|---|---|---|
| EmbeddingGemma 300M (ONNX, q4) | `flutter_embedder` | ~150-200 MB | Intent classification via semantic similarity |
| Qwen3 0.6B (LiteRT-LM) | `flutter_gemma` | ~600 MB | Slot filling (parameter extraction) |

Total first-install download: **~800-950 MB**. On the Moto G56 5G reference device, measured first-run cold start (with downloads) is roughly 15+ seconds plus the download time, which depends entirely on network speed — easily 5-10 minutes on a 3G connection.

### Failure modes that currently cost the user a full re-download

1. **User "clears app storage" from Android settings.** Android wipes the entire app-private data directory. Next launch triggers a full re-download.
2. **User uninstalls and reinstalls.** Same outcome — private data is destroyed.
3. **Contributors running `flutter run` on a fresh clone.** Every contributor who builds Hark locally hits the same ~1 GB download just to verify their changes compile.
4. **Contributors switching between git branches that use different model versions.** If a future branch changes the model URL, the app triggers a re-download.
5. **CI environments that rebuild from scratch.** If we ever add integration tests that exercise the on-device pipeline, the CI runner pays the download cost on every run.

None of these are "fatal" — the download works — but they all produce a multi-minute friction moment that could be eliminated if the model files lived somewhere more stable than app-private storage.

## Two complementary fixes

### Fix A — Persistent model backup to `Downloads/hark-models/`

After a successful first download, copy the model files to a publicly-addressable location on the device (`Downloads/hark-models/<runtime>/<file>`). On subsequent launches, if the app-private cache is missing, check the public backup and copy back before falling through to HuggingFace.

**Why `Downloads/`?**
- Survives app uninstall / clear-storage (private app data destruction doesn't touch public Downloads).
- Visible in the system Files app — users can inspect, delete, copy to another device, or share with a friend running Hark on similar hardware.
- Standard user-facing directory with well-understood semantics: "files the user explicitly owns".
- On Android 10+ (scoped storage), writing to `Downloads/` requires `MediaStore` API but no runtime permission prompt for app-owned files.

**Why not `Documents/` or app-external storage (`Android/data/<pkg>/files/`)?**
- `Android/data/<pkg>/files/` is also wiped on app uninstall per modern Android behavior (since Android 11 the `adb` access is restricted too).
- `Documents/` is fine but feels like "user documents", which model files are not.
- `Downloads/` matches user mental model: "a file I downloaded, stored somewhere I can see and delete".

**Android permission story**:

| Android version | Permission needed | Approach |
|---|---|---|
| API 28 and below | `WRITE_EXTERNAL_STORAGE` (already declared in manifest with `maxSdkVersion="28"`) | Direct `File` I/O into the Downloads directory |
| API 29 (Android 10) | None | `MediaStore.Downloads` API |
| API 30+ (Android 11+) | None for MediaStore collection; `MANAGE_EXTERNAL_STORAGE` optionally for broader access | `MediaStore.Downloads.EXTERNAL_CONTENT_URI` via content resolver |
| API 33+ (Android 13+) | `READ_MEDIA_*` for reading other apps' media (not needed for our own files) | Same as API 30+ |

Since Hark only reads/writes its own files in `Downloads/hark-models/`, the scoped-storage MediaStore API path works without any new runtime permission prompts on Android 10+. The existing `WRITE_EXTERNAL_STORAGE` for pre-Android-10 devices is already declared.

**Directory layout**:

```
/sdcard/Download/hark-models/
├── README.txt                              ← human-readable explanation of what this is
├── flutter_embedder/
│   └── embeddinggemma-300m-ONNX/
│       ├── model_q4.onnx                   ← ~150 MB, mirror of app-private cache
│       ├── tokenizer.json
│       ├── config.json
│       └── ... (whatever files the runtime expects)
└── flutter_gemma/
    └── Qwen3-0.6B.litertlm                 ← ~600 MB
```

**Restore logic (per-runtime, called from notifier init)**:

1. Check app-private cache. If present and valid (size > 0, readable), use it. Done.
2. Check `Downloads/hark-models/<runtime>/<file>`. If present:
   a. Verify the file (size check + optional SHA-256 against a bundled hash or HuggingFace metadata).
   b. If valid, copy to app-private cache. Use it. **No network work.**
   c. If invalid, delete the backup and fall through to step 3.
3. Download from HuggingFace (existing behavior).
4. **After download succeeds**, copy the app-private cache to `Downloads/hark-models/<runtime>/<file>` as the new backup. This is the "mirror on first download" step.

**Edge cases**:

- User deletes the backup directory → next launch re-downloads; no harm done.
- User copies a file into the backup with the wrong name → mismatched hash, deleted on verification, re-download.
- User fills the device to 0 free space → backup copy fails silently, user still has working app from private cache, log a warning.
- Two Hark installs on the same device (debug + release variants) → both write to the same backup directory but use their own private caches. First to run populates the backup, second finds it and skips the download. Works correctly as long as both use the same model URLs.
- Model URL change between Hark versions → the restore logic reads the URL from the current app code, not from the backup, so stale backups with old model versions would fail the hash check and trigger re-download. Acceptable.

**What changes in the Hark codebase**:

- New `lib/services/model_backup_service.dart` encapsulating the public-storage read/write logic.
- `EmbeddingNotifier` and `SlotFillingNotifier` each gain a backup-restore step in their `_initialize()` flow, before falling through to the download.
- `AndroidManifest.xml` probably needs no changes — `WRITE_EXTERNAL_STORAGE` for pre-API-29 is already declared, and scoped storage on API 29+ doesn't require a new permission.
- Optional: a settings toggle for "Enable persistent model backup" (default on) so privacy-sensitive users can opt out.

### Fix B — Contributor `adb push` documentation

Complementary to Fix A, but for developers not end-users. A new doc at `docs/dev/local-model-setup.md` explains how to skip the download entirely when building Hark from source.

**Why it's useful**:
- First-time contributor flutter_runs on a fresh clone → hits the ~1 GB download. Frustrating, slow, wastes bandwidth.
- A contributor who's already downloaded the models once can reuse them across fresh debug installs.
- Contributors on metered connections can fetch models via wifi on one device and push to a test device over USB.
- Contributors working on the model pipeline itself (e.g., experimenting with a different quant) can swap files in-place without rebuilding.

**The adb push workflow** (draft):

1. **Download the models once on your workstation** (one-time):
   ```bash
   mkdir -p ~/hark-dev-models
   cd ~/hark-dev-models
   curl -LO "https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model_q4.onnx"
   curl -LO "https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/resolve/main/tokenizer.json"
   # ... (whatever files the runtime expects — need to list exhaustively)
   curl -LO "https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm"
   ```

2. **Install the debug build of Hark on your device**:
   ```bash
   flutter build apk --debug
   adb install -r build/app/outputs/flutter-apk/app-debug.apk
   ```

3. **Launch the app once so Android creates the app-private data directory**, then force-stop it:
   ```bash
   adb shell am start -n com.oacp.hark/.MainActivity
   sleep 2
   adb shell am force-stop com.oacp.hark
   ```

4. **Push the models via `adb shell run-as` stream pipe** (this is the pattern Slice 0 established for `com.oacp.hark.quant_bench`):
   ```bash
   # EmbeddingGemma — flutter_embedder's cache path
   adb shell "run-as com.oacp.hark sh -c 'mkdir -p files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX'"
   adb shell "run-as com.oacp.hark sh -c 'cat > files/flutter_embedder/onnx-community_embeddinggemma-300m-ONNX/model_q4.onnx'" < ~/hark-dev-models/model_q4.onnx
   # ... (repeat for tokenizer.json and any other files)

   # Qwen3 — flutter_gemma's cache path
   adb shell "run-as com.oacp.hark sh -c 'cat > app_flutter/Qwen3-0.6B.litertlm'" < ~/hark-dev-models/Qwen3-0.6B.litertlm
   ```

5. **Launch again** — the notifiers find the models in the cache and skip the download entirely. Cold start time drops from "15s + network download time" to just "15s".

**What changes in the Hark codebase**:

- One new file: `docs/dev/local-model-setup.md` with the full workflow.
- Reference from `README.md` ("For contributors: see docs/dev/local-model-setup.md to skip model downloads during development").
- No code changes.

**Open questions** (need investigation before writing the contributor doc):

- Exact file layout `flutter_embedder` expects. Need to inspect its `ModelManager.withDefaultCacheDir()` behavior — does it use a sanitized model ID as a directory name? Does it need a manifest file alongside the model?
- Exact file layout `flutter_gemma` expects. It seems to use `app_flutter/<modelFileName>` but might have a metadata file for "has active model" state tracking.
- Whether `adb install -r` over an existing cache preserves the cache (Slice 0 verified it does for `com.oacp.hark.quant_bench`, but we should confirm for `com.oacp.hark` too).
- Debug vs release build package IDs — if hark-release has different variants, the `run-as` path differs per variant.

## How Fix A and Fix B combine

Fix A (persistent backup) helps end users. Fix B (adb side-load) helps developers. They're complementary:

- An end user who has Fix A gets restore-on-clear-storage automatically.
- A developer who has Fix A **also** gets restore-on-clear-storage — their `Downloads/hark-models/` survives `adb uninstall` so a fresh `adb install` finds the backup on the next launch and skips the download.
- A developer who doesn't want Fix A to populate Downloads for some reason can still use Fix B by manually pushing via `adb run-as`.

Fix A might actually make Fix B unnecessary for most developers: once the backup is in place, `adb uninstall && adb install` no longer triggers a re-download because the backup survives.

## Estimated scope

- **Fix A** (persistent backup service): M effort. ~200-300 lines in a new `model_backup_service.dart`, + ~20-30 lines of integration in each notifier, + a manual test pass on Android 10, 12, and 14 devices.
- **Fix B** (contributor docs): S effort. Mostly investigation + one markdown file.

Total: **M** (one focused slice, probably 1-2 sessions).

## Relationship to the llamadart migration revert decision

This doc was drafted during the Phase 2a revert discussion in `docs/plans/load-time-baseline.md`. The user proposed the persistent backup idea partly in reaction to the observation that a runtime migration (ONNX → GGUF) would force an unavoidable 313 MB re-download for every existing user. Fix A would have softened that blow — users could have restored from their Downloads backup if they'd ever completed a previous download successfully.

In the end the migration was reverted independently, so Fix A is no longer defending against the migration case. But the underlying problem (one-time catastrophic re-download on clear-storage or uninstall) exists regardless of which runtime is underneath. Fix A and Fix B apply to the current `flutter_embedder` + `flutter_gemma` stack as-is.

## Not in scope

- Cross-device model sync (user's phone A shares models with user's phone B over the local network). Cute but not needed.
- Signature verification of backup files against a bundled public key. If we ever ship a signed model manifest this becomes useful.
- Model version migration (user upgrades Hark, backup has old model, need to detect the version change and re-download). For now: backup is invalidated on hash mismatch, user pays one-time re-download on version bumps. Acceptable.
- Play Store download-on-demand asset modules. Different distribution strategy entirely; out of scope.

## Related docs

- `docs/plans/load-time-baseline.md` — where this doc was proposed.
- `~/.claude/plans/async-twirling-galaxy.md` — the parent near-term plan.
- `docs/plans/llamadart-migration-findings.md` — Slice 0 findings, including the `adb shell run-as` stream-pipe workflow used by `tools/quant_bench/`.
- `AGENTS.md` (workspace root) — working rules; any new service must be Riverpod 3.x notifier-style.
