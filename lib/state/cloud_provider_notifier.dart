import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/cloud/cloud_provider_config.dart';

/// SharedPreferences key for the non-sensitive routing mode. Kept out
/// of secure storage because (a) it's not secret and (b) putting enums
/// in secure storage would make the "clear config" path harder.
const _kCloudRoutingMode = 'cloud_routing_mode';

/// Secure-storage key for the serialized [CloudProviderConfig] blob.
/// Single JSON string so reads and writes are atomic.
const _kCloudProviderConfigJson = 'cloud_provider_config_json';

/// Android-side options for [FlutterSecureStorage]. Uses
/// EncryptedSharedPreferences under the hood, backed by an AES key in
/// the Android Keystore. See
/// [flutter_secure_storage docs](https://pub.dev/packages/flutter_secure_storage).
const _androidOptions = AndroidOptions(
  encryptedSharedPreferences: true,
);

/// Immutable view of the user's cloud backend configuration plus the
/// routing mode. Consumed by the resolver (Slice 4) and by the Cloud
/// Brain settings screen (Slice 5).
@immutable
class CloudProviderState {
  const CloudProviderState({
    required this.config,
    required this.mode,
  });

  /// Null when no key is configured yet. Routing should fall back to
  /// local regardless of [mode] in that case.
  final CloudProviderConfig? config;

  final CloudRoutingMode mode;

  bool get hasConfig => config != null;

  CloudProviderState copyWith({
    CloudProviderConfig? config,
    bool clearConfig = false,
    CloudRoutingMode? mode,
  }) =>
      CloudProviderState(
        config: clearConfig ? null : (config ?? this.config),
        mode: mode ?? this.mode,
      );
}

/// Riverpod notifier that owns the user's BYOK cloud config and routing
/// mode. Reads from secure storage on build, persists changes eagerly,
/// and emits `null` config when no key is present.
///
/// Intentionally not an [AsyncNotifier] — we want the resolver to be
/// able to read the current state synchronously via `ref.read` during
/// slot filling (Slice 4 wires this up), which an AsyncNotifier would
/// force into an `await`. The build-time load is tiny (one prefs read
/// + one secure-storage read) so the short "empty" window is
/// acceptable. See [awaitInitialLoad] for callers that need to block
/// on the first load.
class CloudProviderNotifier extends Notifier<CloudProviderState> {
  final _secureStorage = const FlutterSecureStorage(
    aOptions: _androidOptions,
  );

  Future<void>? _initialLoad;

  @override
  CloudProviderState build() {
    // Kick off the async load but return a sensible default immediately.
    // Consumers who need the loaded state can `await` [awaitInitialLoad]
    // once after construction; the resolver (Slice 4) will call it
    // during app init so the steady-state path is synchronous.
    _initialLoad ??= _loadFromStorage();
    return const CloudProviderState(
      config: null,
      mode: CloudRoutingMode.localOnly,
    );
  }

  /// Returns a future that completes when the initial secure-storage
  /// read has finished. Safe to call multiple times — the underlying
  /// load runs exactly once per notifier instance.
  Future<void> awaitInitialLoad() => _initialLoad ?? Future.value();

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeRaw = prefs.getString(_kCloudRoutingMode);
      final mode = modeRaw == null
          ? CloudRoutingMode.localOnly
          : _safeParseMode(modeRaw);

      final configRaw = await _secureStorage.read(key: _kCloudProviderConfigJson);
      final config = CloudProviderConfig.fromJsonString(configRaw);

      state = CloudProviderState(config: config, mode: mode);
    } catch (e, st) {
      debugPrint('CloudProviderNotifier: load failed: $e\n$st');
      // Leave the default empty state in place — user can re-enter
      // config via the settings screen.
    }
  }

  CloudRoutingMode _safeParseMode(String raw) {
    try {
      return CloudRoutingMode.fromWireName(raw);
    } on ArgumentError {
      return CloudRoutingMode.localOnly;
    }
  }

  /// Save or replace the cloud provider config. Does NOT change the
  /// routing mode — callers that flip mode at the same time should
  /// call [setMode] separately.
  Future<void> setConfig(CloudProviderConfig config) async {
    await awaitInitialLoad();
    try {
      await _secureStorage.write(
        key: _kCloudProviderConfigJson,
        value: config.toJsonString(),
      );
      state = state.copyWith(config: config);
    } catch (e) {
      debugPrint('CloudProviderNotifier: setConfig failed: $e');
      rethrow;
    }
  }

  /// Wipe the stored API key + config entirely. Routing falls back to
  /// local regardless of the mode setting.
  Future<void> clearConfig() async {
    await awaitInitialLoad();
    try {
      await _secureStorage.delete(key: _kCloudProviderConfigJson);
      state = state.copyWith(clearConfig: true);
    } catch (e) {
      debugPrint('CloudProviderNotifier: clearConfig failed: $e');
      rethrow;
    }
  }

  /// Change the routing mode without touching the stored config.
  Future<void> setMode(CloudRoutingMode mode) async {
    await awaitInitialLoad();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCloudRoutingMode, mode.wireName);
      state = state.copyWith(mode: mode);
    } catch (e) {
      debugPrint('CloudProviderNotifier: setMode failed: $e');
      rethrow;
    }
  }
}

final cloudProviderNotifierProvider =
    NotifierProvider<CloudProviderNotifier, CloudProviderState>(
  CloudProviderNotifier.new,
);
