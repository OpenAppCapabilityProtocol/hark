class DiscoveredAppStatus {
  final String packageName;
  final String authority;
  final String appLabel;
  final String versionName;
  final String? displayName;
  final String? oacpVersion;
  final List<String> capabilities;
  final String? error;

  const DiscoveredAppStatus({
    required this.packageName,
    required this.authority,
    required this.appLabel,
    required this.versionName,
    required this.capabilities,
    this.displayName,
    this.oacpVersion,
    this.error,
  });

  bool get isValid => error == null;
}
