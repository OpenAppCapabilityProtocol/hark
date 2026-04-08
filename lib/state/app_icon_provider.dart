import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';

/// Per-package [AppInfo] lookup (name, icon bytes, version, etc).
///
/// Keyed by Android package name (e.g. `com.example.app`). Backed by the
/// `installed_apps` plugin which goes through PackageManager.getApplicationIcon
/// + getApplicationInfo on the native side. Each result is automatically
/// cached by the Riverpod family until the provider is disposed — the icon
/// bytes are only fetched once per session per package.
///
/// Returns null if the package isn't installed, if we lack
/// QUERY_ALL_PACKAGES visibility, or if the lookup throws. Callers should
/// render a fallback in all three cases.
final appInfoProvider =
    FutureProvider.family<AppInfo?, String>((ref, packageName) async {
  try {
    return await InstalledApps.getAppInfo(packageName);
  } catch (_) {
    return null;
  }
});
