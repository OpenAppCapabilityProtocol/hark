/// Models the user-configured cloud LLM backend used for stage-2
/// parameter extraction. One of several provider-specific config shapes
/// plus a routing mode that decides when to actually call the cloud.
///
/// **No hardcoded URLs, no default model names.** The user supplies
/// every field (base URL, API key, model / deployment name, and any
/// provider-specific extras). The sealed union exists only so adapters
/// and the settings UI can dispatch on auth style — not so we can bake
/// vendor defaults into the data model.
///
/// TODO(byok-simplify): 5 subclasses but 4 are structurally identical
/// (baseUrl + apiKey + model). Only [AzureConfig] adds `apiVersion`.
/// After Slice 4 lands and we know the real adapter shape, consider
/// collapsing to `CloudProviderConfig(kind, baseUrl, apiKey, model,
/// extras: Map<String,String>)`. The "type safety" of the sealed union
/// is illusory — the adapter already runtime-switches on `kind` for
/// auth header selection, and downcasting to reach `apiVersion` is the
/// same runtime check as `extras['api_version']`. Only keep the sealed
/// shape if a provider with structurally different fields shows up
/// (e.g. AWS Bedrock with region + access_key_id + secret + session).
///
/// TODO(byok-schema-version): Persistence blobs have no `_version`
/// field today. Adding one now (`_version: 1`) would be free insurance
/// for future wire-format changes — impossible to retrofit cleanly
/// once existing installs have blobs without it. Bundle with the
/// sealed-union refactor above or do standalone.
///
/// Stored in `flutter_secure_storage` via [CloudProviderNotifier]. The
/// API key is the only field that MUST live in secure storage; the rest
/// could live in shared prefs, but keeping everything together
/// simplifies read/write atomicity.
///
/// Non-goals for this file:
/// - Any network code
/// - Any UI
/// - Any validation against live provider endpoints
/// - Any vendor-specific defaults (URLs, model names)
///
/// See `temp/byok-implementation-plan-2026-04-13.md` for the broader
/// rationale (Slice 1).
library;

import 'dart:convert';

/// Which cloud provider the user has configured. Drives which auth
/// header the adapter emits and which fields the settings screen shows.
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
/// **Every field is user-supplied.** There are no defaults. The
/// settings screen is responsible for any placeholder text or
/// convenience suggestions it wants to offer.
///
/// The API key is stored alongside the rest of the config because
/// [CloudProviderNotifier] writes/reads everything through a single
/// secure-storage blob — simpler than splitting keys from config.
sealed class CloudProviderConfig {
  const CloudProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  /// Base URL for the provider's API. User-supplied, no trailing
  /// `/chat/completions` — the adapter appends the route it needs.
  ///
  /// Examples users might type:
  /// - `https://api.openai.com/v1`
  /// - `https://my-resource.openai.azure.com/openai/v1`
  /// - `https://openrouter.ai/api/v1`
  /// - `https://api.anthropic.com/v1`
  final String baseUrl;

  /// The user's API key. Never log this field. Never include it in
  /// crash reports. See `temp/byok-research-2026-04-13.md` §6.
  final String apiKey;

  /// Model / deployment identifier as the provider expects it in the
  /// request body. For Azure this is the deployment name. For OpenAI,
  /// Gemini, Anthropic, and custom endpoints this is the model id.
  final String model;

  CloudProviderKind get kind;

  // TODO(byok-log-audit): `toJson` returns the raw apiKey for
  // persistence. Any future code doing `debugPrint('${cfg.toJson()}')`
  // would leak the key. Audit / lint when Slice 6 lands its verbose-
  // logging toggle.
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

  /// toString intentionally omits the API key so accidental debug logs
  /// never leak secrets. Subclasses should override if they add
  /// additional sensitive fields.
  @override
  String toString() =>
      '${runtimeType}(baseUrl: $baseUrl, model: $model, apiKey: <redacted>)';
}

/// Vanilla OpenAI direct. Auth via `Authorization: Bearer`.
class OpenAiConfig extends CloudProviderConfig {
  const OpenAiConfig({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.openai;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
      };

  factory OpenAiConfig.fromJson(Map<String, dynamic> json) => OpenAiConfig(
        baseUrl: json['base_url'] as String,
        apiKey: json['api_key'] as String,
        model: json['model'] as String,
      );
}

/// Azure OpenAI. Auth via the `api-key` header (not `Authorization`).
/// The user supplies the full base URL (typically the v1/Foundry
/// surface `https://{resource}.openai.azure.com/openai/v1`), the
/// deployment name (as [model]), and the API version query parameter.
class AzureConfig extends CloudProviderConfig {
  const AzureConfig({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
    required this.apiVersion,
  });

  /// API version query parameter. User-supplied, no default — the
  /// right value depends on the user's region and deployment date.
  /// Example: `2024-10-21`.
  final String apiVersion;

  @override
  CloudProviderKind get kind => CloudProviderKind.azureOpenAi;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
        'api_version': apiVersion,
      };

  factory AzureConfig.fromJson(Map<String, dynamic> json) => AzureConfig(
        baseUrl: json['base_url'] as String,
        apiKey: json['api_key'] as String,
        model: json['model'] as String,
        apiVersion: json['api_version'] as String,
      );
}

/// Google Gemini. Auth via `x-goog-api-key` header, or via the
/// OpenAI-compatibility endpoint with `Authorization: Bearer`. The
/// adapter decides which based on the [baseUrl] the user supplied.
class GeminiConfig extends CloudProviderConfig {
  const GeminiConfig({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.gemini;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
      };

  factory GeminiConfig.fromJson(Map<String, dynamic> json) => GeminiConfig(
        baseUrl: json['base_url'] as String,
        apiKey: json['api_key'] as String,
        model: json['model'] as String,
      );
}

/// Anthropic Claude. Native shape — handled by a dedicated adapter in
/// Slice 7, not by [OpenAiCompatibleAdapter]. This config is declared
/// now so the storage layer, UI, and routing code only need to learn
/// about it once.
///
/// Auth via `x-api-key` + `anthropic-version` headers.
class AnthropicConfig extends CloudProviderConfig {
  const AnthropicConfig({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.anthropic;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
      };

  factory AnthropicConfig.fromJson(Map<String, dynamic> json) =>
      AnthropicConfig(
        baseUrl: json['base_url'] as String,
        apiKey: json['api_key'] as String,
        model: json['model'] as String,
      );
}

/// Custom OpenAI-compatible endpoint. Covers OpenRouter, LiteLLM, vLLM,
/// Together, Groq, self-hosted, and anything else that implements the
/// OpenAI `/v1/chat/completions` (or `/v1/responses`) shape. Structurally
/// identical to [OpenAiConfig]; kept as a distinct kind so the settings
/// UI can offer different placeholder text and help copy.
class CustomOpenAiConfig extends CloudProviderConfig {
  const CustomOpenAiConfig({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
  });

  @override
  CloudProviderKind get kind => CloudProviderKind.customOpenAi;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireName,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
      };

  factory CustomOpenAiConfig.fromJson(Map<String, dynamic> json) =>
      CustomOpenAiConfig(
        baseUrl: json['base_url'] as String,
        apiKey: json['api_key'] as String,
        model: json['model'] as String,
      );
}
