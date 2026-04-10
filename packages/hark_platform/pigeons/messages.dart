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

// ── Overlay-specific (registered by OverlayActivity) ─────────────

@HostApi()
abstract class HarkOverlayApi {
  void dismiss();
  void openFullApp();
}

// ── Main-specific (registered by MainActivity) ───────────────────

@HostApi()
abstract class HarkMainApi {
  void openAssistantSettings();
}

// ── Native → Dart: overlay session lifecycle ─────────────────────

@FlutterApi()
abstract class HarkOverlayFlutterApi {
  void onNewSession(String sessionId);
}

// ── Native → Dart: OACP result broadcast forwarding ──────────────

@FlutterApi()
abstract class HarkResultFlutterApi {
  void onOacpResult(OacpResultMessage result);
}
