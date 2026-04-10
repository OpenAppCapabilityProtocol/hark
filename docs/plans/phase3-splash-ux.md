# Phase 3 — Splash / Init UI-UX Redesign

**Status**: plan drafted, not yet started. Starts after `feat/llamadart-migration` merges to main.

## Context

Phase 2b shipped a persistent embedding cache that cut cold-start-to-first-query from ~24.8s to ~12.1s. The splash UX was functional but minimal during that work. Phase 3 makes the remaining ~12s of load time feel honest, informative, and polished — because the splash is the first thing any new user sees.

## What already exists (discovered by exploration)

The splash is more built-out than expected:

- **Dedicated widget**: `lib/screens/splash_screen.dart` — a `ConsumerWidget` at 109 lines. Not embedded in ChatScreen.
- **Router gate**: `hark_router.dart` uses GoRouter redirect. `/` → `SplashScreen`, redirect to `/chat` when `InitState.isReady` is true.
- **Per-model status rows**: `_ModelRow` widget renders dot indicators (idle/downloading/loading/ready/failed) + progress bars (deterministic when progress != null, indeterminate when busy but no progress).
- **Registry status row**: shows when OACP app discovery completes.
- **Error panel**: `_FailurePanel` shows error messages. **No retry button** — failure is displayed but not recoverable in-app.
- **Visual elements**: Hark logo (128×128), title "Hark", subtitle "Voice assistant for your apps", per-model status rows, status text.
- **Forui design system**: uses `FScaffold`, `FProgress`, `FDeterminateProgress`.
- **`aggregateProgress`**: computed in `InitState` (averages embedding + slot-filling progress) but currently unused in the UI.

## What Phase 3 improves

### Must-have (ship-blocking)

1. **Retry button on error panel.** Currently failure is a dead end — user must force-close and relaunch. Add a "Retry" button that clears `_initFuture` on both notifiers and re-triggers init. Requires adding a `retry()` method to both `EmbeddingNotifier` and `SlotFillingNotifier`.

2. **Per-model download progress with bytes.** Current progress is a 0-1 fraction. Add "Downloading EmbeddingGemma... 45 MB / 197 MB" text alongside the bar. Both notifiers already expose `receivedBytes` / `totalBytes` in their state — just need to render them.

3. **First-run explanation.** On the very first launch (no models cached), show a brief one-liner above the progress area: "Downloading on-device AI models (~830 MB). This happens once — after this, Hark works offline." Users need to understand why a voice assistant is downloading hundreds of MB before they can use it. Gate this on: if both models are in `downloading` stage, show the explanation. If both are in `loading` stage (cache hit), hide it.

### Nice-to-have (polish, not blocking)

4. **Aggregate progress bar.** Use the already-computed `InitState.aggregateProgress` to show a single overall progress bar at the top. The per-model rows stay below it. Gives users a single "how much longer" signal.

5. **Animated transitions.** When a model moves from downloading → loading → ready, animate the dot indicator color change and cross-fade the progress bar to a checkmark. Use `AnimatedSwitcher` or Forui's built-in animation patterns.

6. **Status text animation.** The "Preparing on-device models..." text could cycle through informative tips: "Hark discovers what your apps can do via OACP", "Commands work entirely on-device — no cloud required", "Once loaded, Hark responds in under a second". Low priority but adds personality.

7. **Error recovery for partial failures.** If the embedder loads but the slot filler fails, allow the user to proceed in "embedding-only mode" (keyword fast-path + embedding ranking still work, slot filling is degraded). Show a warning rather than a hard block. Requires updating `InitState.isReady` logic and the router redirect condition.

### Out of scope for Phase 3

- Wake word integration (separate session).
- Overlay integration (Phase 4).
- Model selection screen (future, v2 vision).
- Dark/light theme toggle (existing deferral from phase1-ui-redesign.md).

## Implementation plan

### Slice 3.1 — Retry button + error improvements (S effort)

**Files**:
- `lib/state/embedding_notifier.dart` — add `void retry()` method that sets `_initFuture = null` and calls `_initialize()` again.
- `lib/state/slot_filling_notifier.dart` — same `retry()` method.
- `lib/state/init_notifier.dart` — expose a `void retryAll()` that triggers both retries.
- `lib/screens/splash_screen.dart` — add a `FilledButton` to `_FailurePanel` that calls `ref.read(initProvider.notifier).retryAll()`.

**Test**: kill the network mid-download, verify the error panel shows, tap retry, verify the download resumes.

### Slice 3.2 — Download progress with bytes + first-run explanation (S effort)

**Files**:
- `lib/screens/splash_screen.dart` — modify `_ModelRow` to render `receivedBytes` / `totalBytes` alongside the progress bar. Add a conditional first-run explanation text widget above the model rows, gated on both models being in `downloading` stage.

**Test**: fresh install, verify "Downloading... 45 MB / 197 MB" text is visible and updates. Verify the first-run explanation appears on first launch and is absent on subsequent cached launches.

### Slice 3.3 — Aggregate progress + animation polish (M effort)

**Files**:
- `lib/screens/splash_screen.dart` — add aggregate `FDeterminateProgress` at the top using `InitState.aggregateProgress`. Wrap model row state transitions in `AnimatedSwitcher`. Add cycling tip text via a `Timer`-based rotation.

**Test**: visual review on device. Smooth transitions. No jank on the progress bar. Tips rotate every 3-4 seconds.

### Slice 3.4 — Partial failure degraded mode (M effort, nice-to-have)

**Files**:
- `lib/state/init_notifier.dart` — add `isDegraded` getter: embedding ready + slot filler failed + registry ready → allow proceeding with a warning.
- `hark_router.dart` — update redirect condition to allow `isDegraded` as a "ready with caveat" state.
- `lib/screens/splash_screen.dart` — show a "Continue in limited mode" button when `isDegraded` is true.
- `lib/state/chat_notifier.dart` — handle the case where slot filler is null during `resolveCommand` (fall back to no-params extraction).

**Test**: force the slot filler to fail (e.g., corrupt the model file). Verify the user can proceed to chat. Verify keyword fast-path commands still work. Verify slot-fill-requiring commands gracefully fail with an informative message.

## Critical files

- `lib/screens/splash_screen.dart` — primary target for all slices
- `lib/state/init_notifier.dart` — retry logic + degraded mode
- `lib/state/embedding_notifier.dart` — retry method
- `lib/state/slot_filling_notifier.dart` — retry method
- `hark_router.dart` — redirect condition for degraded mode

## Verification

- Fresh install on Moto G56: per-model progress bars with byte counts visible, first-run explanation visible, aggregate progress bar shows.
- Network kill mid-download: error panel with retry button works.
- Cached launch: no first-run explanation, progress bars show briefly then transition to ready.
- Overall: splash feels polished, honest, and informative. Someone watching over the user's shoulder understands what's happening.
