import 'package:flutter/foundation.dart';

/// Which role sent a chat message.
enum ChatRole { user, assistant }

/// Whether the composer is currently showing the mic or the text field.
enum InputMode { mic, keyboard }

/// A single message rendered in the conversation list.
///
/// A *pending* message is one that is still being produced:
/// - For user messages, this means STT is still streaming the transcript —
///   the bubble re-renders as new partial results arrive.
/// - For assistant messages, this means the NLU/slot-filling pipeline is
///   still running — the bubble renders a three-dot "thinking" animation
///   instead of its (empty) text.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.isPending = false,
    this.isError = false,
    this.metadata,
  });

  /// Client-generated stable id. Used for list keying and for in-place
  /// updates when a pending message is finalized.
  final String id;
  final ChatRole role;
  final String text;
  final bool isPending;
  final bool isError;

  /// Small dim text shown below the bubble (e.g. `com.example.app • increment_counter`).
  final String? metadata;

  ChatMessage copyWith({
    String? text,
    bool? isPending,
    bool? isError,
    String? metadata,
    bool clearMetadata = false,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      isPending: isPending ?? this.isPending,
      isError: isError ?? this.isError,
      metadata: clearMetadata ? null : (metadata ?? this.metadata),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          other.id == id &&
          other.role == role &&
          other.text == text &&
          other.isPending == isPending &&
          other.isError == isError &&
          other.metadata == metadata;

  @override
  int get hashCode =>
      Object.hash(id, role, text, isPending, isError, metadata);
}

/// Top-level state for the chat screen.
@immutable
class ChatState {
  const ChatState({
    this.messages = const [],
    this.isListening = false,
    this.isThinking = false,
    this.isInitializing = true,
    this.initError,
    this.inputMode = InputMode.mic,
    this.statusText = '',
    this.lastError,
    this.continuousListening = false,
    this.isDefaultAssistant = false,
  });

  final List<ChatMessage> messages;
  final bool isListening;
  final bool isThinking;

  /// True while `ChatNotifier._initAsync` is still running (TTS init,
  /// STT init, MethodChannel handler setup, capability registry future).
  /// Distinct from [InitState.isReady] which tracks the on-device *models*.
  /// The composer uses this to visibly disable the mic during the brief
  /// post-splash window before the notifier is fully wired.
  final bool isInitializing;

  /// Fatal error raised during [ChatNotifier._initAsync]. When set, the
  /// mic cannot be used and the UI should surface the message so the user
  /// understands why (instead of a silently dead button).
  final String? initError;

  final InputMode inputMode;

  /// Short status line, mostly used for debug/informational text.
  final String statusText;

  /// Last user-visible error string, if any.
  final String? lastError;

  /// Whether continuous listening mode is active (triggered via Android
  /// system voice-assist intent; restart mic after TTS finishes).
  final bool continuousListening;

  /// Whether Hark is currently set as the system default assistant.
  final bool isDefaultAssistant;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isListening,
    bool? isThinking,
    bool? isInitializing,
    String? initError,
    bool clearInitError = false,
    InputMode? inputMode,
    String? statusText,
    String? lastError,
    bool clearError = false,
    bool? continuousListening,
    bool? isDefaultAssistant,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isListening: isListening ?? this.isListening,
      isThinking: isThinking ?? this.isThinking,
      isInitializing: isInitializing ?? this.isInitializing,
      initError: clearInitError ? null : (initError ?? this.initError),
      inputMode: inputMode ?? this.inputMode,
      statusText: statusText ?? this.statusText,
      lastError: clearError ? null : (lastError ?? this.lastError),
      continuousListening: continuousListening ?? this.continuousListening,
      isDefaultAssistant: isDefaultAssistant ?? this.isDefaultAssistant,
    );
  }
}
