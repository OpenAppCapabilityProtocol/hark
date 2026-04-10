import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hark_platform/hark_platform.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/command_resolution.dart';
import '../models/resolved_action.dart';
import '../services/capability_help_service.dart';
import '../services/capability_registry.dart';
import '../services/command_resolver.dart';
import '../services/intent_dispatcher.dart';
import '../services/oacp_result_service.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart';
import 'chat_state.dart';
import 'embedding_notifier.dart';
import 'init_notifier.dart';
import 'registry_provider.dart';
import 'resolver_provider.dart';
import 'services_providers.dart';
import 'slot_filling_notifier.dart';

/// Owns all chat business logic for the Hark voice assistant screen.
///
/// This is a direct port of the legacy `AssistantScreen` state, extracted
/// into a Riverpod 3.x [Notifier]. The UI layer ([ChatScreen]) consumes
/// [ChatState] and invokes the public methods below — it holds only its own
/// text controller and scroll controller, never business logic.
///
/// Lifetime:
/// - [build] kicks off async initialization via `Future.microtask` and
///   registers cleanup via `ref.onDispose`.
/// - STT/TTS/resolver/registry providers are owned by their own notifiers;
///   this class must NOT dispose them.
class ChatNotifier extends Notifier<ChatState> {
  // Services resolved once in build() — they are plain Provider singletons
  // so ref.read is safe and cheap.
  late final SttService _sttService;
  late final TtsService _ttsService;
  late final OacpResultService _resultService;
  late final CapabilityHelpService _capabilityHelpService;
  late final CommandResolver _commandResolver;

  // Async-resolved dependencies — nullable until _initAsync completes.
  CapabilityRegistry? _registry;
  IntentDispatcher? _dispatcher;

  // Transient state that doesn't belong in [ChatState].
  StreamSubscription<OacpResult>? _resultSubscription;
  Timer? _restartTimer;
  int _messageCounter = 0;

  /// Running count of resolve/dispatch failures in continuous-listening
  /// mode. Resets to 0 on any successful dispatch, fire-and-forget or
  /// async. When it reaches [_continuousFailureLimit], continuous mode is
  /// dropped to prevent the mic from relaunching into a repeat failure
  /// loop (e.g. system-assistant trigger + persistent no-match state).
  int _consecutiveFailures = 0;
  static const int _continuousFailureLimit = 3;

  /// Id of the currently streaming STT user bubble, if any.
  String? _pendingUserMessageId;

  /// Id of the thinking assistant bubble that follows a finalized user
  /// message, if any.
  String? _pendingAssistantMessageId;

  final _commonApi = HarkCommonApi();
  final _mainApi = HarkMainApi();

  @override
  ChatState build() {
    _sttService = ref.read(sttServiceProvider);
    _ttsService = ref.read(ttsServiceProvider);
    _resultService = ref.read(oacpResultServiceProvider);
    _capabilityHelpService = ref.read(capabilityHelpServiceProvider);
    _commandResolver = ref.read(commandResolverProvider);

    // React to discrete model lifecycle transitions so the status line
    // follows the underlying embedding / slot-filling state. Listening on
    // `.select((s) => s.stage)` ensures the callback only fires when the
    // stage enum changes — not on every download progress tick (which can
    // hit 20+ Hz during a large model fetch).
    ref.listen<EmbeddingStage>(
      embeddingProvider.select((s) => s.stage),
      (_, _) => _handleModelStateChanged(),
    );
    ref.listen<SlotFillingStage>(
      slotFillingProvider.select((s) => s.stage),
      (_, _) => _handleModelStateChanged(),
    );

    ref.onDispose(() {
      _restartTimer?.cancel();
      _resultSubscription?.cancel();
      // Do NOT dispose STT/TTS/etc — they are owned by their own providers.
    });

    // Kick off async init after build() returns so `state` is observable.
    Future.microtask(_initAsync);

    return const ChatState(statusText: 'Tap to speak or type a command');
  }

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  Future<void> _initAsync() async {
    try {
      _registry = await ref.read(capabilityRegistryProvider.future);
      _dispatcher = ref.read(intentDispatcherProvider);

      await _ttsService.initialize();
      _commandResolver.initialize();

      _resultSubscription = _resultService.results.listen(_onOacpResult);

      final sttInit = await _sttService.initialize();
      if (!sttInit) {
        debugPrint('Warning: STT failed to initialize.');
      }

      await _checkDefaultAssistant();

      // Success: drop any prior init error so the UI can clear its banner.
      state = state.copyWith(
        isInitializing: false,
        clearInitError: true,
        statusText: _idleStatusText(),
      );
    } catch (error, stackTrace) {
      debugPrint('ChatNotifier: init failed: $error');
      debugPrint('ChatNotifier: $stackTrace');
      // Surface the init failure to the UI so the user has something more
      // useful than a silently dead mic button.
      state = state.copyWith(
        isInitializing: false,
        initError: 'Could not finish starting Hark: $error',
        statusText: 'Initialization failed',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Public API (invoked by ChatScreen)
  // ---------------------------------------------------------------------------

  /// Toggles STT. If already listening, cancels. Otherwise requests
  /// microphone permission and starts a fresh listening session.
  Future<void> onMicPressed() async {
    if (_sttService.isListening) {
      cancelListening();
      return;
    }
    if (state.isInitializing || state.isThinking) return;

    if (_registry == null || !_registry!.hasAvailableActions) {
      await _handleError('No OACP actions are available yet.');
      return;
    }

    // Check permission status first — on Android a prior grant returns
    // instantly from `.status` without any UI round-trip, whereas `.request()`
    // always crosses the platform channel.
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    if (!status.isGranted) {
      state = state.copyWith(statusText: 'Microphone permission denied');
      return;
    }

    await _ttsService.stop();
    await _startListening();
  }

  /// Submits a typed message from the composer.
  Future<void> onTextSubmitted(String text) async {
    if (state.isInitializing || state.isThinking) return;
    final transcript = text.trim();
    if (transcript.isEmpty) return;
    await _submitPrompt(transcript);
  }

  /// Switch between the mic and the text composer. Purely a UI affordance;
  /// the notifier does not otherwise care which mode the composer is in.
  void setInputMode(InputMode mode) {
    if (state.inputMode == mode) return;
    state = state.copyWith(inputMode: mode);
  }

  /// Cancels any active STT session and drops continuous mode.
  void cancelListening() {
    _restartTimer?.cancel();
    _sttService.stopListening();

    // If the user aborted before anything was heard, drop the empty
    // pending bubble so it doesn't linger.
    final pendingId = _pendingUserMessageId;
    if (pendingId != null) {
      final existing = state.messages.firstWhere(
        (m) => m.id == pendingId,
        orElse: () => const ChatMessage(id: '', role: ChatRole.user, text: ''),
      );
      if (existing.id.isNotEmpty && existing.text.trim().isEmpty) {
        _removeMessage(pendingId);
      } else if (existing.id.isNotEmpty) {
        _updateMessage(pendingId, (m) => m.copyWith(isPending: false));
      }
      _pendingUserMessageId = null;
    }

    state = state.copyWith(
      isListening: false,
      continuousListening: false,
      statusText: _idleStatusText(),
    );
  }

  /// Opens the system default-assistant picker.
  Future<void> openAssistantSettings() async {
    await _mainApi.openAssistantSettings();
    // Re-check after returning from settings.
    await Future.delayed(const Duration(seconds: 1));
    await _checkDefaultAssistant();
  }

  // ---------------------------------------------------------------------------
  // Private business logic (ported from AssistantScreen)
  // ---------------------------------------------------------------------------

  Future<void> _startListening() async {
    _restartTimer?.cancel();

    // Create a pending user bubble that will be updated in place as STT
    // partials arrive. The UI renders this as the "live transcript" bubble.
    final pendingId = _nextMessageId();
    _pendingUserMessageId = pendingId;
    _appendMessage(
      ChatMessage(
        id: pendingId,
        role: ChatRole.user,
        text: '',
        isPending: true,
      ),
    );

    state = state.copyWith(
      isListening: true,
      statusText: 'Listening...',
      clearError: true,
    );

    await _sttService.startListening(
      onResult: (text) {
        final currentPendingId = _pendingUserMessageId;
        if (currentPendingId == null) return;
        _updateMessage(currentPendingId, (m) => m.copyWith(text: text));
      },
      onDone: () async {
        final finalizingId = _pendingUserMessageId;
        _pendingUserMessageId = null;

        // Find whatever the final streamed text was.
        String transcript = '';
        if (finalizingId != null) {
          final msg = state.messages.firstWhere(
            (m) => m.id == finalizingId,
            orElse: () =>
                const ChatMessage(id: '', role: ChatRole.user, text: ''),
          );
          transcript = msg.text.trim();
        }

        state = state.copyWith(isListening: false);

        if (transcript.isNotEmpty) {
          // Finalize the pending user bubble in place.
          if (finalizingId != null) {
            _updateMessage(
              finalizingId,
              (m) => m.copyWith(text: transcript, isPending: false),
            );
          }
          debugPrint('HarkDebug user_input: $transcript');
          await _processTranscript(transcript);
        } else {
          // Silence — drop the empty pending bubble and stop continuous
          // mode; do not restart the mic.
          if (finalizingId != null) {
            _removeMessage(finalizingId);
          }
          state = state.copyWith(
            continuousListening: false,
            statusText: _idleStatusText(),
          );
        }
      },
    );
  }

  /// Shared entry point for both typed and spoken submissions. For typed
  /// submissions we synthesize a finalized (non-pending) user bubble; for
  /// spoken submissions the bubble already exists and has been flipped to
  /// non-pending by the STT `onDone` path above.
  Future<void> _submitPrompt(String transcript) async {
    debugPrint('HarkDebug user_input: $transcript');
    _appendMessage(
      ChatMessage(id: _nextMessageId(), role: ChatRole.user, text: transcript),
    );
    await _processTranscript(transcript);
  }

  Future<void> _processTranscript(String transcript) async {
    final registry = _registry;
    if (registry == null || !registry.hasAvailableActions) {
      await _handleError('No OACP actions are available yet.');
      return;
    }

    // Show the "thinking" bubble that the UI animates as three dots.
    final thinkingId = _nextMessageId();
    _pendingAssistantMessageId = thinkingId;
    _appendMessage(
      ChatMessage(
        id: thinkingId,
        role: ChatRole.assistant,
        text: '',
        isPending: true,
      ),
    );

    state = state.copyWith(
      isThinking: true,
      statusText: 'Thinking...',
      clearError: true,
    );

    try {
      final capabilityHelp = _capabilityHelpService.resolve(
        transcript,
        registry.actions,
      );
      if (capabilityHelp != null) {
        _logCommandEvent('capability_help', {
          'transcript': transcript,
          'metadata': capabilityHelp.metadata,
        });
        _finalizePendingAssistant(
          text: capabilityHelp.displayText,
          metadata: capabilityHelp.metadata,
        );
        state = state.copyWith(statusText: 'Speaking...');
        await _ttsService.speak(capabilityHelp.spokenText);
        state = state.copyWith(statusText: 'Done');
        await _restartListeningIfContinuous();
        return;
      }

      final resolution = await _commandResolver.resolveCommand(
        transcript,
        registry.actions,
      );

      if (!resolution.isSuccess) {
        await _handleResolutionFailure(resolution);
        return;
      }

      final resolvedAction = resolution.action!;
      final actionDefinition = registry.findAction(
        resolvedAction.sourceType,
        resolvedAction.sourceId,
        resolvedAction.actionId,
      );
      _logCommandEvent('resolved_action', {
        'transcript': transcript,
        'sourceId': resolvedAction.sourceId,
        'actionId': resolvedAction.actionId,
        'parameters': resolvedAction.parameters,
      });
      _finalizePendingAssistant(
        text: resolvedAction.confirmationMessage,
        metadata: _actionMetadata(resolvedAction),
        sourcePackageName: resolvedAction.sourceId,
        sourceAppName: actionDefinition?.displayName,
      );

      state = state.copyWith(statusText: 'Speaking...');

      // Don't speak confirmation if we expect an async result — the result
      // message will be spoken instead (avoids "Checking the weather" then
      // immediately "Currently 22°C..." with mic interrupting in between).
      final expectsResult =
          actionDefinition?.resultTransportType == 'broadcast';
      if (!expectsResult) {
        await _ttsService.speak(resolvedAction.confirmationMessage);
      }

      state = state.copyWith(statusText: 'Executing...');

      final dispatcher = _dispatcher;
      if (dispatcher == null) {
        await _handleError("I couldn't launch that action.");
        return;
      }
      final dispatchResult = await dispatcher.dispatch(resolvedAction);
      _logCommandEvent('dispatch_result', {
        'sourceId': resolvedAction.sourceId,
        'actionId': resolvedAction.actionId,
        'success': dispatchResult.success,
        'requestId': dispatchResult.requestId,
      });

      if (dispatchResult.success) {
        // Clear the failure counter on any successful dispatch — both
        // fire-and-forget and broadcast paths count as success from the
        // continuous-mode safety valve's perspective.
        _consecutiveFailures = 0;
        state = state.copyWith(
          statusText: expectsResult ? 'Waiting for response...' : 'Done',
        );
        // Only restart mic for fire-and-forget actions. For async results,
        // mic restarts after _onOacpResult speaks the response.
        if (!expectsResult) {
          await _restartListeningIfContinuous();
        }
      } else {
        await _handleError("I couldn't launch that action.");
      }
    } catch (e) {
      await _handleError('An error occurred: $e');
    } finally {
      // Defensive: if _handleError didn't replace it, the pending bubble
      // shouldn't linger.
      final leftoverId = _pendingAssistantMessageId;
      if (leftoverId != null) {
        _updateMessage(leftoverId, (m) => m.copyWith(isPending: false));
        _pendingAssistantMessageId = null;
      }
      final nextStatus = state.statusText == 'Done'
          ? _idleStatusText()
          : state.statusText;
      state = state.copyWith(isThinking: false, statusText: nextStatus);
    }
  }

  Future<void> _handleError(String message) async {
    // If we have a pending thinking bubble, repurpose it as the error
    // message so there is exactly one bubble per exchange.
    final pendingId = _pendingAssistantMessageId;
    if (pendingId != null) {
      _updateMessage(
        pendingId,
        (m) => m.copyWith(text: message, isPending: false, isError: true),
      );
      _pendingAssistantMessageId = null;
    } else {
      _appendMessage(
        ChatMessage(
          id: _nextMessageId(),
          role: ChatRole.assistant,
          text: message,
          isError: true,
        ),
      );
    }

    // Continuous-mode safety valve: if three consecutive resolve/dispatch
    // attempts have failed, stop re-firing the mic. Otherwise a stuck state
    // (e.g. system-assistant long-press → persistent no-match) loops the
    // same error forever.
    _consecutiveFailures += 1;
    if (state.continuousListening &&
        _consecutiveFailures >= _continuousFailureLimit) {
      _consecutiveFailures = 0;
      state = state.copyWith(
        continuousListening: false,
        statusText: 'Error',
        lastError: message,
      );
      await _ttsService.speak(message);
      return;
    }

    state = state.copyWith(statusText: 'Error', lastError: message);
    await _ttsService.speak(message);
    await _restartListeningIfContinuous();
  }

  Future<void> _handleResolutionFailure(
    CommandResolutionResult resolution,
  ) async {
    switch (resolution.errorType) {
      case CommandResolutionErrorType.noMatch:
        await _handleError("Sorry, I didn't understand that command.");
        return;
      case CommandResolutionErrorType.invalidResponse:
      case CommandResolutionErrorType.unavailable:
      case CommandResolutionErrorType.unknown:
      case null:
        await _handleError(
          resolution.message ?? 'The command resolver failed.',
        );
        return;
    }
  }

  Future<void> _onOacpResult(OacpResult result) async {
    _logCommandEvent('oacp_result', {
      'requestId': result.requestId,
      'status': result.status,
      'capabilityId': result.capabilityId,
      'message': result.message,
      'sourcePackage': result.sourcePackage,
    });

    final text = result.displayMessage;
    _appendMessage(
      ChatMessage(
        id: _nextMessageId(),
        role: ChatRole.assistant,
        text: text,
        metadata: result.sourcePackage != null
            ? '${result.sourcePackage} • ${result.capabilityId ?? 'result'}'
            : null,
        isError: result.isFailure,
      ),
    );

    // A successful async result also clears the failure counter — the
    // round trip completed from the user's perspective.
    if (!result.isFailure) {
      _consecutiveFailures = 0;
    }

    await _ttsService.speak(text);
    await _restartListeningIfContinuous();
  }

  Future<void> _restartListeningIfContinuous() async {
    if (!state.continuousListening) return;

    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 500), () {
      if (!state.continuousListening ||
          state.isThinking ||
          _sttService.isListening) {
        return;
      }
      onMicPressed();
    });
  }

  Future<void> _checkDefaultAssistant() async {
    final result = await _commonApi.isDefaultAssistant();
    state = state.copyWith(isDefaultAssistant: result);
  }

  // ---------------------------------------------------------------------------
  // Message list helpers
  // ---------------------------------------------------------------------------

  void _finalizePendingAssistant({
    required String text,
    String? metadata,
    bool isError = false,
    String? sourcePackageName,
    String? sourceAppName,
  }) {
    final pendingId = _pendingAssistantMessageId;
    if (pendingId == null) {
      _appendMessage(
        ChatMessage(
          id: _nextMessageId(),
          role: ChatRole.assistant,
          text: text,
          metadata: metadata,
          isError: isError,
          sourcePackageName: sourcePackageName,
          sourceAppName: sourceAppName,
        ),
      );
      return;
    }
    _updateMessage(
      pendingId,
      (m) => m.copyWith(
        text: text,
        metadata: metadata,
        isPending: false,
        isError: isError,
        sourcePackageName: sourcePackageName,
        sourceAppName: sourceAppName,
      ),
    );
    _pendingAssistantMessageId = null;
    _logChatMessage(
      ChatMessage(
        id: pendingId,
        role: ChatRole.assistant,
        text: text,
        metadata: metadata,
        isError: isError,
        sourcePackageName: sourcePackageName,
        sourceAppName: sourceAppName,
      ),
    );
  }

  void _appendMessage(ChatMessage message) {
    _logChatMessage(message);
    state = state.copyWith(messages: [...state.messages, message]);
  }

  void _updateMessage(
    String id,
    ChatMessage Function(ChatMessage current) transform,
  ) {
    final messages = state.messages;
    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) return;
    final updated = List<ChatMessage>.of(messages);
    updated[index] = transform(messages[index]);
    state = state.copyWith(messages: updated);
  }

  void _removeMessage(String id) {
    final messages = state.messages;
    final filtered = messages.where((m) => m.id != id).toList(growable: false);
    if (filtered.length == messages.length) return;
    state = state.copyWith(messages: filtered);
  }

  String _nextMessageId() {
    _messageCounter += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_messageCounter';
  }

  String _actionMetadata(ResolvedAction action) {
    final parameterPart = action.parameters.isEmpty
        ? 'no parameters'
        : action.parameters.entries
              .map((entry) => '${entry.key}=${entry.value}')
              .join(', ');
    return '${action.sourceId} • ${action.actionId} • $parameterPart';
  }

  // ---------------------------------------------------------------------------
  // Status + model-state plumbing
  // ---------------------------------------------------------------------------

  void _handleModelStateChanged() {
    if (state.isInitializing || state.isThinking || _sttService.isListening) {
      return;
    }
    state = state.copyWith(statusText: _idleStatusText());
  }

  String _idleStatusText() {
    final registry = _registry;
    if (registry == null || !registry.hasAvailableActions) {
      return registry == null
          ? 'Preparing models...'
          : 'No OACP actions available';
    }

    final embeddingState = ref.read(embeddingProvider);
    final slotState = ref.read(slotFillingProvider);

    // Show embedding model status first (it's needed for all commands).
    if (embeddingState.stage == EmbeddingStage.failed) {
      return embeddingState.message;
    }
    if (embeddingState.isBusy) {
      return embeddingState.message;
    }

    // Then slot-filling model status.
    if (slotState.stage == SlotFillingStage.failed) {
      // In degraded mode, show a warning but allow simple commands.
      final init = ref.read(initProvider);
      if (init.isDegraded && init.degradedAccepted) {
        return 'Limited mode — simple commands only';
      }
      return slotState.message;
    }
    if (slotState.isBusy) {
      return slotState.message;
    }

    if (embeddingState.isReady && slotState.isReady) {
      return 'Tap to speak or type a command';
    }

    return 'Preparing models...';
  }

  // ---------------------------------------------------------------------------
  // Logging (preserved verbatim from legacy AssistantScreen)
  // ---------------------------------------------------------------------------

  void _logChatMessage(ChatMessage message) {
    _logCommandEvent('chat_bubble', {
      'role': message.role.name,
      'text': message.text,
      'metadata': message.metadata,
      'isError': message.isError,
    });
  }

  void _logCommandEvent(String event, Map<String, dynamic> payload) {
    final entry = jsonEncode({
      'timestamp': DateTime.now().toIso8601String(),
      'event': event,
      ...payload,
    });
    debugPrint('HarkDebug $entry');
    developer.log(entry, name: 'HarkDebug');
  }
}

/// Riverpod provider exposing [ChatNotifier] and its [ChatState].
final chatProvider = NotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);
