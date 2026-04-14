/// Models the user-configured cloud LLM backend used for stage-2
/// parameter extraction. One of several provider-specific config shapes
/// plus a routing mode that decides when to actually call the cloud.
///
/// Stored in `flutter_secure_storage` via [CloudProviderNotifier]. The
/// API key is the only field that MUST live in secure storage; the rest
/// (provider kind, base URL, model, region) could live in shared prefs,
/// but keeping everything together simplifies read/write atomicity.
///
/// Non-goals for this file:
/// - Any network code
/// - Any UI
/// - Any validation against live provider endpoints
///
/// See `temp/byok-implementation-plan-2026-04-13.md` for the broader
/// rationale (Slice 1).
library;

import 'dart:convert';

/// Which cloud provider the user has configured.
enum CloudProviderKind {
  openai('openai'),
  azureOpenAi('azure'),
  gemini('gemini'),
  anthropic('anthropic'),
  customOpenAi('custom_openai');

  const CloudProviderKind(this.wireName);

  /// Stable string used in JSON persistence. Do not change without a
  /// migration — existing secure-storage blobs rely on this value.
  final String wireName;

  static CloudProviderKind fromWireName(String name) {
    for (final kind in CloudProviderKind.values) {
      if (kind.wireName == name) return kind;
    }
    throw ArgumentError('Unknown CloudProviderKind wireName: $name');
  }
}

/// Routing mode for stage-2 parameter extraction. Determines how
/// [CloudSlotFiller] and the local Qwen3 fallback interact.
enum CloudRoutingMode {
  /// Always run the on-device slot filler. Ignore any configured cloud
  /// provider. The default when no API key is present.
  localOnly('local_only'),

  /// Try cloud first when a key is configured and the network is up.
  /// Fall back to on-device slot fill on any [CloudUnavailableError]
  /// (network, 401, 429, malformed response). Recommended default
  /// after a key is saved.
  cloudPreferred('cloud_preferred'),

  /// Always run cloud. Refuse to fall back silently. Surface a hard
  /// error to the user on any failure. Opt-in for users who would
  /// rather see a clear failure than an inconsistent backend.
  cloudOnly('cloud_only');

  const CloudRoutingMode(this.wireName);
  final String wireName;

  static CloudRoutingMode fromWireName(String name) {
    for (final mode in CloudRoutingMode.values) {
      if (mode.wireName == name) return mode;
    }
    throw ArgumentError('Unknown CloudRoutingMode wireName: $name');
  }
}

/// Sealed base for all cloud provider configurations. Each concrete
/// subclass carries the fields that that provider needs to build a
/// request: base URL, model identifier, auth material.
///
/// The API key is stored alongside the rest of the config because
/// [CloudProviderNotifier] writes/reads everything through a single
/// secure-storage blob — simpler than splitting keys from config.
sealed class CloudProviderConfig {
  const CloudProviderConfig({
    required this.apiKey,
    required this.model,
  });

  /// The user's API key. Never log this field. Never include it in
  /// crash reports. See `temp/byok-research-2026-04-13.md` §6.
  final String apiKey;

  /// Model identifier as the provider expects it. For Azure this is
  /// the *deployment name*, NOT the base model name.
  final String model;

  CloudProviderKind get kind;

  /// The base URL used by [OpenAiCompatibleAdapter] or the provider's
  /// native adapter. For Azure, this is the resource/v1 shape; for
  /// custom OpenAI-compatible providers, the user-supplied URL.
  String get baseUrl;

  Map<String, dynamic> toJson();

  /// Parse a previously-persisted config blob. Throws [ArgumentError]
  /// on unknown kinds or malformed input — callers should treat that
  /// as "no config stored" and prompt the user to re-enter.
  static CloudProviderConfig fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'] as String?;
    if (kindRaw == null) {
      throw ArgumentError('CloudProviderConfig JSON missing "kind" field');
    }
    final kind = CloudProviderKind.fromWireName(kindRaw);
    switch (kind) {
      case CloudProviderKind.openai:
        return OpenAiConfig.fromJson(json);
      case CloudProviderKind.azureOpenAi:
        return AzureConfig.fromJson(json);
      case CloudProviderKind.gemini:
        return GeminiConfig.fromJson(json);
      case CloudProviderKind.anthropic:
        return AnthropicConfig.fromJson(json);
      case CloudProviderKind.customOpenAi:
        return CustomOpenAiConfig.fromJson(json);
    }
  }

  static CloudProviderConfig? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return fromJson(decoded);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

/// Vanilla OpenAI direct (`api.openai.com`).
class OpenAiConfig extends CloudProviderConfig {
  const OpenAiConfig({
    required super.apiKey,
    super.model = 'gpt-4o-mini',
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.openai;

  @override
  String get baseUrl => 'https://api.openai.com/v1';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'api_key': apiKey,
        'model': model,
      };

  factory OpenAiConfig.fromJson(Map<String, dynamic> json) => OpenAiConfig(
        apiKey: json['api_key'] as String,
        model: (json['model'] as String?) ?? 'gpt-4o-mini',
      );
}

/// Azure OpenAI. Uses the v1/Foundry surface (`/openai/v1/...`) which
/// accepts `model` in the request body like vanilla OpenAI, instead of
/// the classic per-deployment URL. See
/// `temp/byok-research-2026-04-13.md` §1 for why.
class AzureConfig extends CloudProviderConfig {
  const AzureConfig({
    required super.apiKey,
    required this.resourceName,
    required super.model,
    this.apiVersion = '2024-10-21',
  });

  /// The Azure resource subdomain, e.g. `my-hark-resource` for
  /// `https://my-hark-resource.openai.azure.com`.
  final String resourceName;

  /// API version query parameter. Pinned to a known-good value by
  /// default; users on newer regions may need to bump it.
  final String apiVersion;

  @override
  CloudProviderKind get kind => CloudProviderKind.azureOpenAi;

  @override
  String get baseUrl => 'https://$resourceName.openai.azure.com/openai/v1';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'api_key': apiKey,
        'model': model,
        'resource_name': resourceName,
        'api_version': apiVersion,
      };

  factory AzureConfig.fromJson(Map<String, dynamic> json) => AzureConfig(
        apiKey: json['api_key'] as String,
        resourceName: json['resource_name'] as String,
        model: json['model'] as String,
        apiVersion:
            (json['api_version'] as String?) ?? '2024-10-21',
      );
}

/// Google Gemini via the OpenAI-compatibility endpoint. We intentionally
/// target the compat shape from day one so [OpenAiCompatibleAdapter]
/// covers it without a separate Gemini adapter.
class GeminiConfig extends CloudProviderConfig {
  const GeminiConfig({
    required super.apiKey,
    super.model = 'gemini-2.5-flash-lite',
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.gemini;

  @override
  String get baseUrl =>
      'https://generativelanguage.googleapis.com/v1beta/openai';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'api_key': apiKey,
        'model': model,
      };

  factory GeminiConfig.fromJson(Map<String, dynamic> json) => GeminiConfig(
        apiKey: json['api_key'] as String,
        model: (json['model'] as String?) ?? 'gemini-2.5-flash-lite',
      );
}

/// Anthropic Claude. Native shape — handled by a dedicated adapter in
/// Slice 7, not by [OpenAiCompatibleAdapter]. This config is declared
/// now so the storage layer, UI, and routing code only need to learn
/// about it once.
class AnthropicConfig extends CloudProviderConfig {
  const AnthropicConfig({
    required super.apiKey,
    super.model = 'claude-haiku-4-5',
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.anthropic;

  @override
  String get baseUrl => 'https://api.anthropic.com/v1';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'api_key': apiKey,
        'model': model,
      };

  factory AnthropicConfig.fromJson(Map<String, dynamic> json) =>
      AnthropicConfig(
        apiKey: json['api_key'] as String,
        model: (json['model'] as String?) ?? 'claude-haiku-4-5',
      );
}

/// Custom OpenAI-compatible endpoint. Covers OpenRouter, LiteLLM, vLLM,
/// Together, Groq, self-hosted, and anything else that implements the
/// OpenAI `/v1/chat/completions` (or `/v1/responses`) shape.
class CustomOpenAiConfig extends CloudProviderConfig {
  const CustomOpenAiConfig({
    required super.apiKey,
    required super.model,
    required this.customBaseUrl,
  });

  /// User-provided base URL. Should not include `/chat/completions` —
  /// the adapter appends the relevant path.
  final String customBaseUrl;

  @override
  CloudProviderKind get kind => CloudProviderKind.customOpenAi;

  @override
  String get baseUrl => customBaseUrl;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'api_key': apiKey,
        'model': model,
        'custom_base_url': customBaseUrl,
      };

  factory CustomOpenAiConfig.fromJson(Map<String, dynamic> json) =>
      CustomOpenAiConfig(
        apiKey: json['api_key'] as String,
        model: json['model'] as String,
        customBaseUrl: json['custom_base_url'] as String,
      );
}
