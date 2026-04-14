import 'cloud_provider_config.dart';

/// Parses a full Azure OpenAI / Foundry endpoint URL into the discrete
/// fields [AzureConfig] needs.
///
/// The Azure portal shows users a URL like:
///
///   https://hark-ai-resource.cognitiveservices.azure.com/openai/deployments/hark-cloud-gpt-4-mini/chat/completions?api-version=2025-01-01-preview
///
/// rather than three separate fields, so the Cloud Brain settings
/// screen lets users paste it verbatim and we extract:
///
/// - `baseUrl` — everything up to and including `/openai/deployments/{name}`
///   (the adapter appends `/chat/completions`)
/// - `model`  — the deployment name segment (`hark-cloud-gpt-4-mini`)
/// - `apiVersion` — the `api-version` query parameter
///
/// Supports both classic (`*.openai.azure.com`,
/// `*.cognitiveservices.azure.com`) and the newer Foundry domain
/// (`*.services.ai.azure.com`). Also accepts URLs without the trailing
/// `/chat/completions` path (user pre-trimmed) and URLs with extra
/// query params.
///
/// Throws [FormatException] with a user-friendly message if the URL
/// doesn't match the expected shape. The Cloud Brain screen catches
/// this and surfaces it inline.
class AzureUrlParser {
  const AzureUrlParser();

  /// Parse [rawUrl] into an [AzureConfig]. [apiKey] is supplied
  /// separately and persisted via [CloudProviderNotifier.setConfig].
  AzureConfig parse({required String rawUrl, required String apiKey}) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('URL is empty.');
    }

    final Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      throw const FormatException(
        'URL is not a valid URI. Paste the full endpoint from the Azure '
        'portal (Keys and Endpoint tab).',
      );
    }

    if (!uri.hasScheme || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException(
        'URL must start with https://. Paste the full endpoint from '
        'the Azure portal.',
      );
    }
    if (uri.host.isEmpty) {
      throw const FormatException('URL is missing a host.');
    }

    // Find the /openai/deployments/{name} segment.
    final segments = uri.pathSegments;
    final openaiIdx = segments.indexOf('openai');
    if (openaiIdx == -1) {
      throw const FormatException(
        'URL does not look like an Azure OpenAI / Foundry endpoint. '
        'Expected a path containing /openai/deployments/{deployment}.',
      );
    }
    if (openaiIdx + 2 >= segments.length ||
        segments[openaiIdx + 1] != 'deployments') {
      throw const FormatException(
        'URL is missing /deployments/{deployment-name}. Make sure you '
        'copied the full endpoint, not just the resource URL.',
      );
    }
    final deploymentName = segments[openaiIdx + 2];
    if (deploymentName.isEmpty) {
      throw const FormatException(
        'Deployment name is empty in the URL.',
      );
    }

    // api-version is required.
    final apiVersion = uri.queryParameters['api-version'];
    if (apiVersion == null || apiVersion.isEmpty) {
      throw const FormatException(
        'URL is missing the ?api-version=... query parameter. Copy the '
        'full endpoint from the Azure portal — it includes the version.',
      );
    }

    // Reconstruct the base URL: scheme + host + /openai/deployments/{name}
    // (drop any /chat/completions suffix and all query params).
    final baseSegments =
        segments.sublist(0, openaiIdx + 3); // openai, deployments, name
    final baseUri = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: baseSegments,
    );

    return AzureConfig(
      baseUrl: baseUri.toString(),
      apiKey: apiKey,
      model: deploymentName,
      apiVersion: apiVersion,
    );
  }
}
