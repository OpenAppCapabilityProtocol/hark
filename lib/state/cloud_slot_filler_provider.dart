import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud/adapters/openai_compatible_adapter.dart';
import '../services/cloud/cloud_provider_config.dart';
import '../services/cloud/cloud_slot_filler.dart';
import 'cloud_provider_notifier.dart';

/// Compile-time Azure bootstrap for first-pass on-device testing
/// without a settings UI (Slice 5 will replace this with the real
/// Cloud Brain screen).
///
/// Pass these via the flutter run command:
///
/// ```
/// flutter run --release \
///   --dart-define=AZURE_BASE_URL=https://hark-ai-resource.cognitiveservices.azure.com/openai/deployments/hark-cloud-gpt-4-mini \
///   --dart-define=AZURE_API_KEY=<key> \
///   --dart-define=AZURE_MODEL=hark-cloud-gpt-4-mini \
///   --dart-define=AZURE_API_VERSION=2025-01-01-preview
/// ```
///
/// All four values must be supplied for the env-var path to activate.
/// Empty defaults mean "not configured" — the provider falls back to
/// the secure-storage-backed [CloudProviderNotifier] state instead.
const _envBaseUrl = String.fromEnvironment('AZURE_BASE_URL');
const _envApiKey = String.fromEnvironment('AZURE_API_KEY');
const _envModel = String.fromEnvironment('AZURE_MODEL');
const _envApiVersion = String.fromEnvironment('AZURE_API_VERSION');

CloudProviderConfig? _envConfigOrNull() {
  if (_envBaseUrl.isEmpty ||
      _envApiKey.isEmpty ||
      _envModel.isEmpty ||
      _envApiVersion.isEmpty) {
    return null;
  }
  return AzureConfig(
    baseUrl: _envBaseUrl,
    apiKey: _envApiKey,
    model: _envModel,
    apiVersion: _envApiVersion,
  );
}

/// True when the compile-time AZURE_* dart-defines are all set. The
/// resolver wiring treats this as an implicit `cloudPreferred` mode
/// override so a developer running with env vars doesn't also have to
/// flip a mode toggle that doesn't have a UI yet.
bool get hasEnvCloudBootstrap =>
    _envBaseUrl.isNotEmpty &&
    _envApiKey.isNotEmpty &&
    _envModel.isNotEmpty &&
    _envApiVersion.isNotEmpty;

/// Builds a [CloudSlotFiller] from whichever cloud config source has
/// one to offer. Source precedence:
///
/// 1. **`--dart-define` AZURE_* values** (compile-time, dev-only) — for
///    rapid iteration without committing keys to git or building a UI
/// 2. **`CloudProviderNotifier` state** — the proper secure-storage
///    path that Slice 5's settings screen will populate
///
/// Emits `null` when neither source has a config. Watching consumers
/// must treat null as "no cloud configured" and fall back to local.
///
/// This provider is `keepAlive`-style by virtue of being a top-level
/// `Provider` — it rebuilds when [cloudProviderNotifierProvider] emits.
final cloudSlotFillerProvider = Provider<CloudSlotFiller?>((ref) {
  // Source 1: env vars (debug bootstrap)
  final envConfig = _envConfigOrNull();
  if (envConfig != null) {
    debugPrint(
      'cloudSlotFillerProvider: using --dart-define AZURE bootstrap '
      '(baseUrl=${envConfig.baseUrl}, model=${envConfig.model})',
    );
    final adapter = OpenAiCompatibleAdapter(envConfig);
    ref.onDispose(adapter.close);
    return CloudSlotFiller(client: adapter, backend: 'openai_compat');
  }

  // Source 2: secure-storage notifier
  final state = ref.watch(cloudProviderNotifierProvider);
  final config = state.config;
  if (config == null) return null;

  // Anthropic needs the dedicated adapter (Slice 7) — not handled here.
  if (config.kind == CloudProviderKind.anthropic) {
    debugPrint(
      'cloudSlotFillerProvider: anthropic config present but '
      'AnthropicAdapter not implemented yet (Slice 7). Falling back.',
    );
    return null;
  }

  debugPrint(
    'cloudSlotFillerProvider: using stored config '
    '(kind=${config.kind.wireName}, baseUrl=${config.baseUrl}, '
    'model=${config.model})',
  );
  final adapter = OpenAiCompatibleAdapter(config);
  ref.onDispose(adapter.close);
  return CloudSlotFiller(client: adapter, backend: 'openai_compat');
});
