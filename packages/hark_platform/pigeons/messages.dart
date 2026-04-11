import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  kotlinOut:
      'android/src/main/kotlin/com/oacp/hark_platform/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.oacp.hark_platform'),
))

// ── Data classes ──────────────────────────────────────────────────

class DiscoveredAppMessage {
  const DiscoveredAppMessage({
    required this.packageName,
    required this.authority,
    required this.appLabel,
    required this.versionName,
    this.manifestJson,
    this.contextMarkdown,
    this.error,
  });

  final String packageName;
  final String authority;
  final String appLabel;
  final String versionName;
  final String? manifestJson;
  final String? contextMarkdown;
  final String? error;
}

class BackupInfo {
  const BackupInfo({required this.path, required this.sizeBytes});

  final String path;
  final int sizeBytes;
}

class OacpResultMessage {
  const OacpResultMessage({
    this.requestId,
    required this.status,
    this.capabilityId,
    this.message,
    this.error,
    this.sourcePackage,
    this.result,
  });

  final String? requestId;
  final String status;
  final String? capabilityId;
  final String? message;
  final String? error;
  final String? sourcePackage;
  final String? result;
}

// ── Overlay state sync data ─────────────────────────────────────

class OverlayChatMessage {
  const OverlayChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.isPending,
    required this.isError,
    this.metadata,
    this.sourceAppName,
  });

  final String id;
  final String role; // "user" | "assistant"
  final String text;
  final bool isPending;
  final bool isError;
  final String? metadata;
  final String? sourceAppName;
}

class OverlayStateMessage {
  const OverlayStateMessage({
    required this.messages,
    required this.isListening,
    required this.isThinking,
    required this.isInitializing,
    required this.statusText,
    required this.inputMode,
  });

  final List<OverlayChatMessage> messages;
  final bool isListening;
  final bool isThinking;
  final bool isInitializing;
  final String statusText;
  final String inputMode; // "mic" | "keyboard"
}

// ── Cross-engine API (registered by plugin on every engine) ──────

@HostApi()
abstract class HarkCommonApi {
  @async
  bool isDefaultAssistant();

  @async
  List<DiscoveredAppMessage> discoverOacpApps();

  @async
  BackupInfo? findBackup(String fileName);

  @async
  String saveBackup(String fileName);

  @async
  String? restoreBackup(String fileName);

  @async
  bool deleteBackup(String fileName);
}

// ── Overlay → Native (registered by OverlayActivity) ────────────

@HostApi()
abstract class HarkOverlayApi {
  void dismiss();
  void openFullApp();
  void micPressed();
  void cancelListening();
  void textSubmitted(String text);
  void setInputMode(String mode);
}

// ── Main engine → Native (push state for overlay relay) ─────────

@HostApi()
abstract class HarkOverlayBridgeApi {
  void pushStateToOverlay(OverlayStateMessage state);
  void notifyOverlayActive(bool active);
}

// ── Main-specific (registered by MainActivity) ───────────────────

@HostApi()
abstract class HarkMainApi {
  void openAssistantSettings();
}

// ── Native → Overlay engine: session + state updates ────────────

@FlutterApi()
abstract class HarkOverlayFlutterApi {
  void onNewSession(String sessionId);
  void onStateUpdate(OverlayStateMessage state);
}

// ── Native → Main engine: relay overlay actions ─────────────────

@FlutterApi()
abstract class HarkMainFlutterApi {
  void onOverlayMicPressed();
  void onOverlayCancelListening();
  void onOverlayTextSubmitted(String text);
  void onOverlayInputModeChanged(String mode);
  void onOverlayOpened();
  void onOverlayDismissed();
}

// ── Native → Dart: OACP result broadcast forwarding ──────────────

@FlutterApi()
abstract class HarkResultFlutterApi {
  void onOacpResult(OacpResultMessage result);
}
