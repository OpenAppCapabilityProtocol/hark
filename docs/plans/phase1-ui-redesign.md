# Phase 1 — UI Redesign (forui + Riverpod)

Branch: `feat/ui-redesign-forui`
Worktree: `worktree-hark-ui/`
Scope: **UI/UX only.** No changes to NLU pipeline, STT/TTS, or OACP discovery logic.

---

## Decisions locked in

| Question | Decision |
|---|---|
| State management | **Riverpod only, no codegen, no ChangeNotifier.** Use manual `Notifier` / `NotifierProvider` and plain `Provider`. Existing `ChangeNotifier` services get converted to `Notifier<State>`. |
| Font | **Inter** — forui default. Zero setup, matches minimal aesthetic. |
| Action card "result" section | **Derive from existing fields** — `confirmationMessage` + `resultTransportType`. No oacp.json spec change. |
| Model init UX | **Dedicated splash → chat.** Splash holds until both models ready. (Foreground-service warm-keep is phase 3.) |
| Theme | **Dark only**, `FThemes.green.dark.touch`. Light theme deferred. |
| Framework | **forui** — no Material widgets except `MaterialApp` + `FLocalizations` bridge. |

---

## Success criteria (done-when)

1. App title is "Hark" everywhere (launcher, app bar, manifest).
2. App cold-starts to a branded splash with a visible Hark logo and live model-load progress. Transitions automatically to chat once both `GemmaEmbeddingService` and `SlotFillingService` report ready.
3. Chat screen matches the wireframe: big circular mic button centered-bottom, smaller keyboard-toggle button to its right, no text field visible by default.
4. Pressing mic shows an active-listening visual (ripple or pulse). Live transcript appears **as a user chat bubble** in the conversation list, not in a separate status strip.
5. While NLU + slot-filling run, the assistant bubble shows an animated three-dot "thinking" indicator (no text).
6. Pressing the keyboard toggle swaps the mic UI for a text composer; pressing it again swaps back. Mic and keyboard input both flow through the same `_submitPrompt` path.
7. Discovery Diagnostics screen is **deleted**. Its refresh action is moved to the Actions screen app-bar.
8. Actions screen renders each OACP app as an accordion card. Expanding a capability shows: human-readable name (`displayName`), description, example phrases (`examples`), parameters (name + type + required/optional), and a derived result summary.
9. Refresh on the Actions screen shows a loading indicator in the app-bar and disables the refresh button while running.
10. `flutter analyze` passes with zero issues on the worktree branch.

---

## Architecture

### New directory layout

```
lib/
├── main.dart                         # ProviderScope + MaterialApp + FTheme bridge
├── app.dart                          # App root widget (routing, theme, splash gate)
├── theme/
│   └── hark_theme.dart               # FThemeData builder (dark green + Inter)
├── models/                           # (unchanged — pure data classes)
├── services/                         # Stateless services: STT, TTS, dispatcher, resolver, registry, logger
│   ├── stt_service.dart              # (unchanged)
│   ├── tts_service.dart              # (unchanged)
│   ├── intent_dispatcher.dart        # (unchanged)
│   ├── capability_registry.dart      # (unchanged — already non-reactive)
│   ├── capability_help_service.dart  # (unchanged)
│   ├── command_resolver.dart         # (unchanged)
│   ├── nlu_command_resolver.dart     # CHANGED — takes embed/slot fns instead of ChangeNotifier services
│   ├── logging_command_resolver.dart # (unchanged)
│   ├── inference_logger.dart         # (unchanged)
│   └── oacp_result_service.dart      # (unchanged — already stream-based)
├── state/                            # NEW — ALL Riverpod providers and Notifiers live here
│   ├── providers.dart                # Barrel exports
│   ├── embedding_notifier.dart       # Notifier<EmbeddingState> — owns GemmaEmbedder instance
│   ├── slot_filling_notifier.dart    # Notifier<SlotFillingState> — owns Qwen3 InferenceModel
│   ├── services_providers.dart       # Plain Providers for stateless services
│   ├── registry_provider.dart        # FutureProvider<CapabilityRegistry>
│   ├── resolver_provider.dart        # Provider<CommandResolver> (depends on embed/slot notifiers)
│   ├── init_notifier.dart            # Notifier<InitState> — splash gate, overall readiness
│   ├── chat_notifier.dart            # Notifier<ChatState> — messages, listening, thinking, input mode
│   └── actions_notifier.dart         # Notifier<ActionsState> — refresh state, filter, grouped list
└── screens/
    ├── splash_screen.dart            # NEW — branded init screen
    ├── chat_screen.dart              # RENAMED assistant_screen.dart → chat_screen.dart, rewritten
    ├── actions_screen.dart           # REPLACES available_actions_screen.dart
    └── widgets/                      # NEW — small shared widgets
        ├── hark_logo.dart
        ├── thinking_bubble.dart      # animated 3-dot
        ├── mic_button.dart           # big circular mic with ripple
        ├── composer_bar.dart         # bottom bar: mic + keyboard toggle / text field
        └── action_accordion_item.dart
```

**Files deleted** (cleanup):
- `lib/screens/discovered_apps_screen.dart`
- `lib/screens/assistant_screen.dart` → rewritten as `chat_screen.dart`
- `lib/screens/available_actions_screen.dart` → rewritten as `actions_screen.dart`
- `lib/services/gemma_embedding_service.dart` → moved into `lib/state/embedding_notifier.dart`
- `lib/services/slot_filling_service.dart` → moved into `lib/state/slot_filling_notifier.dart`

---

### Riverpod provider tree

**Rules:**
- **Only Riverpod for state.** Zero `ChangeNotifier`, zero `setState` for business state (UI-local tween controllers still use `setState`).
- **No codegen.** All providers are written manually. No `@riverpod` annotations, no `build_runner`.
- **`Notifier` for mutable state** (not `StateNotifier` — `Notifier` is the modern Riverpod 2.x primitive).
- **Plain `Provider` for stateless services** (STT, TTS, dispatcher).
- **`FutureProvider` for one-shot async** (capability registry init).

```dart
// embedding_notifier.dart
class EmbeddingState {
  const EmbeddingState({
    required this.stage,
    required this.message,
    this.progress,
    this.embedder,
  });

  final EmbeddingStage stage;        // idle, downloading, loading, ready, failed
  final String message;
  final double? progress;
  final GemmaEmbedder? embedder;     // null until ready

  bool get isReady => embedder != null;
  bool get isBusy =>
      stage == EmbeddingStage.downloading || stage == EmbeddingStage.loading;

  EmbeddingState copyWith({ /* ... */ });
}

class EmbeddingNotifier extends Notifier<EmbeddingState> {
  @override
  EmbeddingState build() {
    // Kicked off here, not in a separate prewarm() call. First read of the
    // provider triggers model init automatically.
    Future.microtask(_initialize);
    ref.onDispose(() {
      // Null out the embedder ref so flutter_rust_bridge can GC native state.
      state = state.copyWith(embedder: null);
    });
    return const EmbeddingState(
      stage: EmbeddingStage.idle,
      message: 'Preparing EmbeddingGemma...',
    );
  }

  Future<void> _initialize() async {
    state = state.copyWith(stage: EmbeddingStage.downloading, progress: 0);
    // ... download with progress callbacks updating `state = state.copyWith(progress: p)`
    // ... load model
    state = state.copyWith(
      stage: EmbeddingStage.ready,
      embedder: loadedEmbedder,
    );
  }

  Future<List<double>?> embedQuery(String text) async {
    final e = state.embedder;
    if (e == null) return null;
    final formatted = GemmaEmbedder.formatQuery(query: text);
    return await e.embed(text: formatted);
  }
}

final embeddingProvider =
    NotifierProvider<EmbeddingNotifier, EmbeddingState>(EmbeddingNotifier.new);
```

Same pattern for `SlotFillingNotifier`:

```dart
final slotFillingProvider =
    NotifierProvider<SlotFillingNotifier, SlotFillingState>(
  SlotFillingNotifier.new,
);
```

Stateless services as plain `Provider`s:

```dart
// services_providers.dart
final sttServiceProvider = Provider<SttService>((ref) {
  final svc = SttService();
  ref.onDispose(svc.dispose);
  return svc;
});
final ttsServiceProvider = Provider<TtsService>((ref) {
  final svc = TtsService();
  ref.onDispose(svc.dispose);
  return svc;
});
final inferenceLoggerProvider = Provider((_) => InferenceLogger());
final oacpResultServiceProvider = Provider((_) => OacpResultService());
```

Async one-shots and derived providers:

```dart
// registry_provider.dart
final capabilityRegistryProvider = FutureProvider<CapabilityRegistry>((ref) async {
  final registry = CapabilityRegistry();
  await registry.initialize();
  return registry;
});

final intentDispatcherProvider = Provider<IntentDispatcher>((ref) {
  final registry = ref.watch(capabilityRegistryProvider).requireValue;
  return IntentDispatcher(registry);
});

// resolver_provider.dart
// NluCommandResolver is refactored to take callables instead of services:
//   NluCommandResolver(
//     embedQuery: (text) => ref.read(embeddingProvider.notifier).embedQuery(text),
//     fillSlots:  (action, text) => ref.read(slotFillingProvider.notifier).extract(action, text),
//   )
// This keeps the resolver Riverpod-agnostic and testable in isolation.
final commandResolverProvider = Provider<CommandResolver>((ref) {
  return LoggingCommandResolver(
    NluCommandResolver(
      embedQuery: (text) => ref.read(embeddingProvider.notifier).embedQuery(text),
      fillSlots: (action, transcript) =>
          ref.read(slotFillingProvider.notifier).extract(action, transcript),
    ),
    ref.watch(inferenceLoggerProvider),
  );
});
```

Screen-level Notifiers:

```dart
// init_notifier.dart — drives the splash gate
class InitState {
  const InitState({
    required this.embeddingReady,
    required this.slotFillingReady,
    required this.registryReady,
    this.error,
  });
  final bool embeddingReady;
  final bool slotFillingReady;
  final bool registryReady;
  final String? error;
  bool get isReady => embeddingReady && slotFillingReady && registryReady;
}

class InitNotifier extends Notifier<InitState> {
  @override
  InitState build() {
    // Re-compute whenever any dependency changes.
    final embedding = ref.watch(embeddingProvider);
    final slot = ref.watch(slotFillingProvider);
    final registry = ref.watch(capabilityRegistryProvider);
    return InitState(
      embeddingReady: embedding.isReady,
      slotFillingReady: slot.isReady,
      registryReady: registry is AsyncData,
      error: /* combine failed states */,
    );
  }
}

final initProvider = NotifierProvider<InitNotifier, InitState>(InitNotifier.new);

// chat_notifier.dart
final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);

// actions_notifier.dart
final actionsProvider = NotifierProvider<ActionsNotifier, ActionsState>(
  ActionsNotifier.new,
);
```

**Key idea:** every piece of mutable state lives in a `Notifier` exposed via a `NotifierProvider`. Screens are `ConsumerWidget`s; they `ref.watch(...)` for reads and `ref.read(...notifier)` for actions. Nothing in `lib/` extends `ChangeNotifier`.

---

### Theme setup (`lib/theme/hark_theme.dart`)

```dart
import 'package:forui/forui.dart';
import 'package:flutter/material.dart';

FThemeData buildHarkTheme() {
  final base = FThemes.green.dark.touch;
  // Inter is already the forui default font — no override needed.
  // If we want to tune scale for phone:
  return base;
}
```

Root wire-up (`main.dart`):

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: HarkApp()));
}

class HarkApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = buildHarkTheme();
    return MaterialApp(
      title: 'Hark',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      theme: theme.toApproximateMaterialTheme(),
      builder: (_, child) => FTheme(
        data: theme,
        child: FToaster(child: child!),
      ),
      home: const SplashGate(),
    );
  }
}
```

`SplashGate` watches `initControllerProvider` and swaps to `ChatScreen` once ready.

---

## Screen-by-screen

### Splash screen

**Purpose:** first cold-start experience. Held until `embeddingService.isReady && slotFillingService.isReady`.

**Layout:**

```
┌──────────────────────────────┐
│                              │
│                              │
│          [Hark logo]         │  ← 128x128, from assets/logo.png
│                              │
│            Hark              │  ← typography.xl2, bold
│                              │
│                              │
│   ● EmbeddingGemma   ──────  │  ← FDeterminateProgress
│   ● Qwen3 0.6B       ──────  │
│                              │
│        Preparing…            │  ← live status text
│                              │
└──────────────────────────────┘
```

- Logo file: copy `oacp-hark-logo.png` (workspace root) into `assets/hark_logo.png` and declare in `pubspec.yaml`.
- On model failure, show an `FAlert` with retry button. Do NOT auto-advance.
- Background: solid `colors.background` (dark).

### Chat screen

**Layout (idle, mic mode — default):**

```
┌──────────────────────────────┐
│  Hark                    ⋯   │  ← FHeader with suffix: actions menu
├──────────────────────────────┤
│                              │
│                              │
│                              │
│   Tap the mic to talk        │  ← empty-state hint, dim
│                              │
│                              │
│                              │
│                              │
│         ╭───────╮            │
│         │  🎙   │  ⌨         │  ← big mic + small keyboard toggle
│         ╰───────╯            │
└──────────────────────────────┘
```

**Layout (listening):**

```
│  [user bubble]: live transcript as it comes in
│         ╭───────╮
│         │ ●●●●● │  ← active pulse ring
│         ╰───────╯
```

**Layout (thinking):**

```
│  [user bubble]: "increment counter by 5"
│  [assistant bubble]: • • •    ← ThinkingBubble
```

**Components:**
- `MicButton`: `FButton.icon` wrapped in a `Container` with `BoxDecoration.circle`. 80px diameter. When `ChatState.listening == true`, overlay an animated ripple (`AnimatedContainer` + repeating `AnimationController`).
- `ComposerBar`: swaps between mic-mode and keyboard-mode. Animated cross-fade (`AnimatedSwitcher`).
- `ThinkingBubble`: three dots pulsing in sequence. Implement with `AnimationController` + `Interval`s (no third-party dep).
- Keyboard mode: `FTextField` + send button + small mic button to return to mic mode.

**ChatState (StateNotifier):**

```dart
class ChatState {
  final List<ChatMessage> messages;
  final bool isListening;
  final bool isThinking;
  final String? liveTranscript;       // drives the live user bubble while mic is open
  final InputMode inputMode;          // mic | keyboard
  final String statusText;            // dim status line (optional)
}

enum InputMode { mic, keyboard }
```

Message model now includes a `pending` flag so the live transcript bubble can be reused:
```dart
class ChatMessage {
  final String id;
  final ChatRole role;                // user | assistant
  final String text;
  final bool isPending;               // user: live transcript / assistant: thinking
  final bool isError;
  final String? metadata;             // small grey text below bubble (app • action)
}
```

**Flow (mic path):**
1. Tap mic → `chatController.startListening()` → creates a pending user bubble with empty text → starts STT.
2. STT `onResult(text)` → `chatController.updateLiveTranscript(text)` → pending user bubble re-renders.
3. STT `onDone` → finalize the user bubble, insert a pending assistant bubble (thinking), call `_processTranscript`.
4. On resolved action → replace the pending assistant bubble with the real confirmation message.
5. On OACP async result → append another assistant bubble with the result.

### Actions screen

**Purpose:** browse + discover what Hark can do. Replaces Available Actions + Discovery Diagnostics.

**Layout:**

```
┌──────────────────────────────┐
│  ← Actions            ↻      │  ← FHeader.nested with back + refresh
├──────────────────────────────┤
│  3 apps · 11 actions         │  ← summary row
│  [ Search capabilities   🔍 ]│  ← FTextField
├──────────────────────────────┤
│  ╭──────────────────────────╮│
│  │ 📱 Counter Demo        ▾ ││  ← FAccordion
│  ├──────────────────────────┤│
│  │ Increment Counter      ▾ ││    ← FAccordionItem per capability
│  │ Decrement Counter      ▾ ││
│  ╰──────────────────────────╯│
│  ╭──────────────────────────╮│
│  │ 🎵 Auxio              ▾  ││
│  ╰──────────────────────────╯│
└──────────────────────────────┘
```

**Expanded capability content (in FAccordionItem child):**
- **Description**: `action.description`
- **Try saying**: bullet list of `action.examples` (up to 3)
- **Parameters**: chip list. Required chips use `colors.primary` background, optional use `colors.secondary`. Format: `count (number, required)`
- **Result**: derived —
  - if `resultTransportType == 'broadcast'` → "App replies with a result (spoken back to you)"
  - else → "Fire-and-forget. Hark will say: *\"\<confirmationMessage\>\"*"

**Refresh behavior:**
- `ActionsController.refresh()` sets `isRefreshing = true`, re-initializes the registry, updates state.
- Refresh button in header shows `FCircularProgress` when `isRefreshing`, otherwise a refresh icon. Button is disabled while refreshing.
- Use `FAlert.primary` for empty state ("No OACP apps found. Install one and tap refresh.").

**Two levels of accordion** is nice UX but forui's `FAccordion` children must all be `FAccordionItem`. To nest, each app card is an `FAccordionItem` whose `child` is a `Column` of custom expandable tiles — OR we just use one flat `FAccordion` per app, each inside an `FCard`. Go with: one `FCard` per app, containing one `FAccordion` of its capabilities. Simpler.

---

## Android housekeeping

- **Launcher label**: `android/app/src/main/AndroidManifest.xml` → `android:label="Hark"` (confirm already set; update if "OACP Assistant").
- **pubspec name / description**: already `hark`. Update description if needed.
- **Launcher icon**: already replaced in mipmap dirs (uncommitted in main). Stage these in the first commit.
- **Dark status bar**: set via `SystemUiOverlayStyle` driven by `context.theme.colors.systemOverlayStyle`.

---

## Dependencies to add

```yaml
dependencies:
  forui: ^0.18.0               # check latest in temp/forui
  flutter_riverpod: ^2.6.0     # NOT riverpod_generator, NOT hooks_riverpod
```

**No codegen packages.** Do not add `riverpod_annotation`, `riverpod_generator`, `build_runner`, or `custom_lint`. All providers written manually.

Remove `uses-material-design: true`? **Keep it** — forui depends on Material for icons/fonts internally and we need `MaterialApp` for localizations.

Inter font: already bundled by forui. No `google_fonts` needed.

**Lint guard:** add a grep check to CI (or a pre-commit) for `ChangeNotifier` in `lib/` — should return zero after slice 2.

---

## Implementation order (slices)

Each slice ends with `flutter analyze` clean and an in-device smoke test.

1. **Bootstrap** — add `forui` + `flutter_riverpod`, build theme, wrap root in `ProviderScope` + `FTheme`, replace `Scaffold` with `FScaffold` on a stub home. Verify app title "Hark" and green accent.
2. **Convert services to Notifiers** — rewrite `GemmaEmbeddingService` and `SlotFillingService` as `EmbeddingNotifier` / `SlotFillingNotifier` under `lib/state/`. Delete the old files. Refactor `NluCommandResolver` to accept callables instead of service instances. Register plain `Provider`s for STT/TTS/dispatcher/registry. Existing `AssistantScreen` temporarily becomes a `ConsumerStatefulWidget` reading from providers. No visual change yet, but zero `ChangeNotifier` references remain — verify with grep.
3. **Splash screen + InitNotifier** — add logo asset, build splash, gate home on `initProvider`. Verify cold start flow.
4. **Chat screen skeleton** — new `ChatScreen` using forui widgets. Static layout, no behavior. Wire mic button press as a no-op.
5. **ChatController + live transcript** — hook STT through the controller. Pending user bubble updates live.
6. **Thinking bubble + assistant flow** — pending assistant bubble, three-dot animation, resolve + dispatch, replace bubble with result.
7. **Keyboard toggle** — swap composer bar. Shared `submit()` path.
8. **Actions screen** — new accordion design, refresh button with loading state, derived result section.
9. **Delete dead screens** — remove `discovered_apps_screen.dart`, old `assistant_screen.dart`, `available_actions_screen.dart`. Update imports.
10. **Polish + analyze** — final pass, motion tuning, empty states, error states, analyzer clean.

Each slice is a separate commit with a conventional prefix (`feat:`, `refactor:`, `chore:`).

---

## Out of scope (phase 2+)

- Overlay/floating assistant screen (phase 2).
- Wake-word detection (phase 3).
- Learning from user interactions (phase 4).
- Light theme.
- iOS.
- Foreground-service model warm-keep (phase 3 prerequisite).
- Visual polish beyond "clean and coherent" (no mascot animations, no custom transitions between screens beyond default).

---

## Open questions to confirm before coding slice 4+

- Mic button size on small phones — 80px or scale down to 72px?
- Keyboard-mode default: should tapping the keyboard icon *also* dismiss the on-screen keyboard after sending? (Proposed: yes.)
- On mic tap with models still warming: show an `FToast` "Still warming up…" or simply disable the button? (Proposed: disable + tooltip.)
