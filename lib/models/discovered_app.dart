import 'package:hark_platform/hark_platform.dart';

class DiscoveredApp {
  final String packageName;
  final String authority;
  final String appLabel;
  final String versionName;
  final String? manifestJson;
  final String? contextMarkdown;
  final String? error;

  const DiscoveredApp({
    required this.packageName,
    required this.authority,
    required this.appLabel,
    required this.versionName,
    this.manifestJson,
    this.contextMarkdown,
    this.error,
  });

  factory DiscoveredApp.fromMap(Map<Object?, Object?> map) {
    return DiscoveredApp(
      packageName: map['packageName'] as String? ?? '',
      authority: map['authority'] as String? ?? '',
      appLabel: map['appLabel'] as String? ?? '',
      versionName: map['versionName'] as String? ?? '',
      manifestJson: map['manifestJson'] as String?,
      contextMarkdown: map['contextMarkdown'] as String?,
      error: map['error'] as String?,
    );
  }

  factory DiscoveredApp.fromMessage(DiscoveredAppMessage msg) {
    return DiscoveredApp(
      packageName: msg.packageName,
      authority: msg.authority,
      appLabel: msg.appLabel,
      versionName: msg.versionName,
      manifestJson: msg.manifestJson,
      contextMarkdown: msg.contextMarkdown,
      error: msg.error,
    );
  }

  bool get hasCompleteMetadata =>
      packageName.isNotEmpty &&
      authority.isNotEmpty &&
      manifestJson != null &&
      contextMarkdown != null &&
      error == null;
}
