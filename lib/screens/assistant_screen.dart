import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../state/embedding_notifier.dart';
import '../state/registry_provider.dart';
import '../state/resolver_provider.dart';
import '../state/services_providers.dart';
import '../state/slot_filling_notifier.dart';
import 'package:go_router/go_router.dart';

import '../router/hark_router.dart';

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  late final SttService _sttService = ref.read(sttServiceProvider);
  late final TtsService _ttsService = ref.read(ttsServiceProvider);
  late final OacpResultService _resultService =
      ref.read(oacpResultServiceProvider);
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  late final CapabilityHelpService _capabilityHelpService =
      ref.read(capabilityHelpServiceProvider);
  late final CommandResolver _commandResolver =
      ref.read(commandResolverProvider);

  // Combined model readiness — both must be ready for full pipeline.
  bool get _modelsReady =>
      ref.read(embeddingProvider).isReady &&
      ref.read(slotFillingProvider).isReady;
  late IntentDispatcher _intentDispatcher;
  late CapabilityRegistry _capabilityRegistry;
  StreamSubscription<OacpResult>? _resultSubscription;
  Timer? _restartTimer;

  static const _assistChannel = MethodChannel('com.oacp.hark/assist');

  String _statusText = 'Tap to speak or type a command';
  String _transcript = '';
  String _lastAction = '';
  bool _isInitializing = true;
  bool _isProcessing = false;
  bool _continuousListening = false;
  bool _isDefaultAssistant = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<EmbeddingState>(
      embeddingProvider,
      (previous, next) => _handleModelStateChanged(),
    );
    ref.listenManual<SlotFillingState>(
      slotFillingProvider,
      (previous, next) => _handleModelStateChanged(),
    );
    _initServices();
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _resultSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initServices() async {
    _capabilityRegistry = await ref.read(capabilityRegistryProvider.future);
    _intentDispatcher = ref.read(intentDispatcherProvider);

    await _ttsService.initialize();
    _commandResolver.initialize();

    _resultSubscription = _resultService.results.listen(_onOacpResult);

    _assistChannel.setMethodCallHandler((call) async {
      if (call.method == 'startListening' &&
          mounted &&
          !_isInitializing &&
          !_isProcessing) {
        _continuousListening = true;
        _onMicPressed();
      }
    });

    final sttInit = await _sttService.initialize();
    if (!sttInit) {
      debugPrint('Warning: STT failed to initialize.');
    }

    await _checkDefaultAssistant();

    if (mounted) {
      setState(() {
        _isInitializing = false;
        _statusText = _idleStatusText();
      });
    }
  }

  Future<void> _onMicPressed() async {
    if (_sttService.isListening) {
      _cancelListening();
      return;
    }
    if (_isInitializing || _isProcessing) return;

    if (!_capabilityRegistry.hasAvailableActions) {
      await _handleError('No OACP actions are available yet.');
      return;
    }

    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      setState(() {
        _statusText = 'Microphone permission denied';
      });
      return;
    }

    await _ttsService.stop();
    await _startListening();
  }

  Future<void> _startListening() async {
    _restartTimer?.cancel();

    setState(() {
      _transcript = '';
      _statusText = 'Listening...';
    });

    await _sttService.startListening(
      onResult: (text) {
        setState(() {
          _transcript = text;
        });
      },
      onDone: () async {
        final transcript = _transcript.trim();
        if (transcript.isNotEmpty) {
          await _submitPrompt(transcript);
        } else {
          // Silence — stop continuous mode, don't restart
          _continuousListening = false;
          if (mounted) {
            setState(() {
              _statusText = _idleStatusText();
            });
          }
        }
      },
    );
  }

  void _cancelListening() {
    _continuousListening = false;
    _restartTimer?.cancel();
    _sttService.stopListening();
    if (mounted) {
      setState(() {
        _statusText = _idleStatusText();
      });
    }
  }

  Future<void> _onTextSubmitted() async {
    if (_isInitializing || _isProcessing) return;

    final transcript = _textController.text.trim();
    if (transcript.isEmpty) {
      return;
    }

    _textController.clear();
    await _submitPrompt(transcript);
  }

  Future<void> _submitPrompt(String transcript) async {
    debugPrint('HarkDebug user_input: $transcript');
    _appendMessage(_ChatMessage.user(transcript));
    await _processTranscript(transcript);
  }

  Future<void> _processTranscript(String transcript) async {
    if (!_capabilityRegistry.hasAvailableActions) {
      await _handleError('No OACP actions are available yet.');
      return;
    }

    setState(() {
      _statusText = 'Thinking...';
      _isProcessing = true;
      _transcript = transcript;
    });

    try {
      final capabilityHelp = _capabilityHelpService.resolve(
        transcript,
        _capabilityRegistry.actions,
      );
      if (capabilityHelp != null) {
        _logCommandEvent('capability_help', {
          'transcript': transcript,
          'metadata': capabilityHelp.metadata,
        });
        _appendMessage(
          _ChatMessage.assistant(
            capabilityHelp.displayText,
            metadata: capabilityHelp.metadata,
          ),
        );
        setState(() {
          _lastAction = capabilityHelp.lastAction;
          _statusText = 'Speaking...';
        });
        await _ttsService.speak(capabilityHelp.spokenText);
        if (!mounted) return;
        setState(() {
          _statusText = 'Done';
        });
        _restartListeningIfContinuous();
        return;
      }

      final resolution = await _commandResolver.resolveCommand(
        transcript,
        _capabilityRegistry.actions,
      );

      if (!resolution.isSuccess) {
        await _handleResolutionFailure(resolution);
        return;
      }

      final resolvedAction = resolution.action!;
      final actionDefinition = _capabilityRegistry.findAction(
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
      _appendMessage(
        _ChatMessage.assistant(
          resolvedAction.confirmationMessage,
          metadata: _actionMetadata(resolvedAction),
        ),
      );

      setState(() {
        _statusText = 'Speaking...';
      });

      // Don't speak confirmation if we expect an async result — the result
      // message will be spoken instead (avoids "Checking the weather" then
      // immediately "Currently 22°C..." with mic interrupting in between).
      final expectsResult = actionDefinition?.resultTransportType == 'broadcast';
      if (!expectsResult) {
        await _ttsService.speak(resolvedAction.confirmationMessage);
      }

      if (!mounted) return;

      setState(() {
        _statusText = 'Executing...';
      });

      final dispatchResult = await _intentDispatcher.dispatch(resolvedAction);
      _logCommandEvent('dispatch_result', {
        'sourceId': resolvedAction.sourceId,
        'actionId': resolvedAction.actionId,
        'success': dispatchResult.success,
        'requestId': dispatchResult.requestId,
      });

      if (dispatchResult.success) {
        setState(() {
          _lastAction = 'Sent action to: ${resolvedAction.sourceId}';
          _statusText = expectsResult ? 'Waiting for response...' : 'Done';
        });
        // Only restart mic for fire-and-forget actions (no async result).
        // For async results, mic restarts after _onOacpResult speaks the response.
        if (!expectsResult) {
          _restartListeningIfContinuous();
        }
      } else {
        await _handleError("I couldn't launch that action.");
      }
    } catch (e) {
      await _handleError('An error occurred: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          if (_statusText == 'Done') {
            _statusText = _idleStatusText();
          }
        });
      }
    }
  }

  Future<void> _checkDefaultAssistant() async {
    try {
      final result = await _assistChannel.invokeMethod<bool>('isDefaultAssistant');
      if (mounted) {
        setState(() {
          _isDefaultAssistant = result ?? false;
        });
      }
    } catch (_) {
      // Not available on this platform
    }
  }

  Future<void> _openAssistantSettings() async {
    try {
      await _assistChannel.invokeMethod('openAssistantSettings');
    } catch (_) {}
    // Re-check after returning from settings
    await Future.delayed(const Duration(seconds: 1));
    await _checkDefaultAssistant();
  }

  void _restartListeningIfContinuous() {
    if (!_continuousListening || !mounted) return;

    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _continuousListening && !_isProcessing && !_sttService.isListening) {
        _onMicPressed();
      }
    });
  }

  Future<void> _handleError(String message) async {
    if (!mounted) return;
    _appendMessage(_ChatMessage.assistant(message, isError: true));
    setState(() {
      _statusText = 'Error';
      _lastAction = message;
    });
    await _ttsService.speak(message);
    _restartListeningIfContinuous();
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
    if (!mounted) return;

    _logCommandEvent('oacp_result', {
      'requestId': result.requestId,
      'status': result.status,
      'capabilityId': result.capabilityId,
      'message': result.message,
      'sourcePackage': result.sourcePackage,
    });

    final text = result.displayMessage;
    _appendMessage(_ChatMessage.assistant(
      text,
      metadata: result.sourcePackage != null
          ? '${result.sourcePackage} • ${result.capabilityId ?? 'result'}'
          : null,
      isError: result.isFailure,
    ));

    if (mounted) {
      await _ttsService.speak(text);
      _restartListeningIfContinuous();
    }
  }

  void _appendMessage(_ChatMessage message) {
    if (!mounted) {
      return;
    }

    _logChatMessage(message);
    setState(() {
      _messages.add(message);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  String _actionMetadata(ResolvedAction action) {
    final parameterPart = action.parameters.isEmpty
        ? 'no parameters'
        : action.parameters.entries
              .map((entry) => '${entry.key}=${entry.value}')
              .join(', ');
    return '${action.sourceId} • ${action.actionId} • $parameterPart';
  }

  void _logChatMessage(_ChatMessage message) {
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

  void _handleModelStateChanged() {
    if (!mounted || _isInitializing || _isProcessing || _sttService.isListening) {
      return;
    }

    setState(() {
      _statusText = _idleStatusText();
    });
  }

  String _idleStatusText() {
    if (!_capabilityRegistry.hasAvailableActions) {
      return 'No OACP actions available';
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
      return slotState.message;
    }
    if (slotState.isBusy) {
      return slotState.message;
    }

    if (_modelsReady) {
      return 'Tap to speak or type a command';
    }

    return 'Preparing models...';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('OACP Assistant'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () => context.push(HarkRoutes.actions),
            icon: const Icon(Icons.list_alt),
            tooltip: 'Available actions',
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _sttService.isListening ? _cancelListening : null,
        child: SafeArea(
          child: Column(
            children: [
            if (!_isDefaultAssistant && !_isInitializing)
              MaterialBanner(
                content: const Text(
                  'Set Hark as your default assistant to use long-press Home.',
                ),
                actions: [
                  TextButton(
                    onPressed: _openAssistantSettings,
                    child: const Text('Open Settings'),
                  ),
                ],
                leading: const Icon(Icons.assistant),
              ),
            _StatusBar(
              statusText: _statusText,
              lastAction: _lastAction,
              transcript: _transcript,
              embeddingState: ref.watch(embeddingProvider),
              slotFillingState: ref.watch(slotFillingProvider),
            ),
            Expanded(
              child: _messages.isEmpty
                  ? _EmptyConversation(theme: theme)
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        return _MessageBubble(message: message);
                      },
                    ),
            ),
              _Composer(
                controller: _textController,
                isBusy: _isProcessing || _isInitializing,
                isListening: _sttService.isListening,
                onMicPressed: _onMicPressed,
                onSendPressed: _onTextSubmitted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.statusText,
    required this.lastAction,
    required this.transcript,
    required this.embeddingState,
    required this.slotFillingState,
  });

  final String statusText;
  final String lastAction;
  final String transcript;
  final EmbeddingState embeddingState;
  final SlotFillingState slotFillingState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showModelStatus = embeddingState.isBusy ||
        slotFillingState.isBusy ||
        embeddingState.stage == EmbeddingStage.failed ||
        slotFillingState.stage == SlotFillingStage.failed;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            statusText,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (showModelStatus) ...[
            const SizedBox(height: 8),
            _ModelProgressRow(
              label: 'EmbeddingGemma',
              stage: embeddingState.stage.name,
              progress: embeddingState.progress,
              isBusy: embeddingState.isBusy,
              isFailed: embeddingState.stage == EmbeddingStage.failed,
              isReady: embeddingState.isReady,
            ),
            const SizedBox(height: 4),
            _ModelProgressRow(
              label: 'Qwen3 0.6B',
              stage: slotFillingState.stage.name,
              progress: slotFillingState.progress,
              isBusy: slotFillingState.isBusy,
              isFailed: slotFillingState.stage == SlotFillingStage.failed,
              isReady: slotFillingState.isReady,
            ),
          ],
          if (transcript.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Heard: $transcript', style: theme.textTheme.bodySmall),
          ],
          if (lastAction.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              lastAction,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelProgressRow extends StatelessWidget {
  const _ModelProgressRow({
    required this.label,
    required this.stage,
    required this.progress,
    required this.isBusy,
    required this.isFailed,
    required this.isReady,
  });

  final String label;
  final String stage;
  final double? progress;
  final bool isBusy;
  final bool isFailed;
  final bool isReady;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isFailed
        ? theme.colorScheme.error
        : isReady
            ? Colors.green
            : theme.colorScheme.primary;

    return Row(
      children: [
        Icon(
          isFailed
              ? Icons.error_outline
              : isReady
                  ? Icons.check_circle_outline
                  : Icons.downloading,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        if (isBusy && progress != null)
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
              ),
            ),
          )
        else if (isBusy)
          const Expanded(
            child: ClipRRect(
              child: LinearProgressIndicator(minHeight: 4),
            ),
          )
        else
          Text(
            isFailed ? 'Failed' : 'Ready',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
      ],
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.graphic_eq, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Type or speak a command',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Try commands for installed OACP apps, like "pause music", "show my task inbox", or "add a task buy milk".',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isBusy,
    required this.isListening,
    required this.onMicPressed,
    required this.onSendPressed,
  });

  final TextEditingController controller;
  final bool isBusy;
  final bool isListening;
  final VoidCallback onMicPressed;
  final VoidCallback onSendPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !isBusy,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSendPressed(),
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Type a command...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: isBusy ? null : onSendPressed,
            icon: const Icon(Icons.send),
            tooltip: 'Send',
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: (isBusy && !isListening) ? null : onMicPressed,
            icon: Icon(isListening ? Icons.stop : Icons.mic_none),
            tooltip: isListening ? 'Stop listening' : 'Push to talk',
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == _ChatRole.user;
    final alignment = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = isUser
        ? theme.colorScheme.primary
        : message.isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHigh;
    final textColor = isUser
        ? theme.colorScheme.onPrimary
        : message.isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurface;

    return Align(
      alignment: alignment,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isUser ? 'You' : 'Hark',
              style: theme.textTheme.labelSmall?.copyWith(
                color: textColor.withValues(alpha: 0.8),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
            ),
            if (message.metadata != null && message.metadata!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                message.metadata!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: textColor.withValues(alpha: 0.75),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _ChatRole { user, assistant }

class _ChatMessage {
  const _ChatMessage({
    required this.role,
    required this.text,
    this.metadata,
    this.isError = false,
  });

  const _ChatMessage.user(String text) : this(role: _ChatRole.user, text: text);

  const _ChatMessage.assistant(
    String text, {
    String? metadata,
    bool isError = false,
  }) : this(
         role: _ChatRole.assistant,
         text: text,
         metadata: metadata,
         isError: isError,
       );

  final _ChatRole role;
  final String text;
  final String? metadata;
  final bool isError;
}
