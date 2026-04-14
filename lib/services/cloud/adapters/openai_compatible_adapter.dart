import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../models/assistant_action.dart';
import '../cloud_errors.dart';
import '../cloud_provider_config.dart';
import '../hark_llm_client.dart';
import '../oacp_to_tool_schema.dart';
import '../slot_result_validator.dart';

/// Cloud slot filler that targets any OpenAI-compatible chat/completions
/// endpoint via direct HTTP. Replaces the previous `openai_dart`-based
/// implementation — we POST one well-known shape per call, so the
/// provider-abstraction package was net-negative (its Azure auth
/// defaults bit us with the wrong header for Foundry serverless
/// endpoints, and we couldn't see the actual request bytes).
///
/// Supported in one client:
/// - OpenAI direct (`api.openai.com/v1`)
/// - Azure / Foundry serverless (`*.cognitiveservices.azure.com/openai/deployments/{name}`
///   or `*.services.ai.azure.com/...`)
/// - Gemini OpenAI-compat endpoint
///   (`generativelanguage.googleapis.com/v1beta/openai`)
/// - Custom OpenAI-compatible backends (OpenRouter, LiteLLM, vLLM,
///   Together, Groq, self-hosted)
///
/// Auth: `Authorization: Bearer {apiKey}` for every provider. Microsoft
/// surfaces both `api-key:` and `Authorization: Bearer` in their Azure
/// docs depending on which template generated them; the Foundry-managed
/// flavor (used by every modern model deployment in 2026) wants Bearer.
/// If a future user has a legacy classic Azure OpenAI deployment that
/// only accepts `api-key:`, we'll add a UI toggle then.
///
/// Anthropic is NOT handled here — its native `tool_use` shape needs
/// the dedicated [AnthropicAdapter] (Slice 7).
///
/// **Per-call shape:**
/// 1. Translate the action's parameters into an OpenAI tool definition
///    via [OacpToToolSchema].
/// 2. Build a system prompt with extraction instructions + entity
///    context (aliases, known entities) from the same translator.
/// 3. POST `{baseUrl}/chat/completions[?api-version=...]` with
///    `tools=[tool]`, `tool_choice=function(name)` so the model is
///    forced to call our tool (no chit-chat).
/// 4. Parse `choices[0].message.tool_calls[0].function.arguments`
///    (JSON string).
/// 5. Validate via [SlotResultValidator] — same coercion rules as the
///    on-device path.
class OpenAiCompatibleAdapter implements HarkLlmClient {
  OpenAiCompatibleAdapter(
    this._config, {
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _translator = const OacpToToolSchema(),
        _validator = const SlotResultValidator();

  final CloudProviderConfig _config;
  final http.Client _http;
  final bool _ownsClient;
  final OacpToToolSchema _translator;
  final SlotResultValidator _validator;

  /// Build the full POST URL: `{baseUrl}/chat/completions` with
  /// optional `?api-version=...` query for Azure. We do this by hand
  /// rather than using `Uri.resolve` because resolve mishandles base
  /// URLs whose last segment looks like a path component (e.g.
  /// `/openai/deployments/{name}` would lose `{name}` on resolve).
  Uri _chatCompletionsUri() {
    final base = _config.baseUrl.endsWith('/')
        ? _config.baseUrl.substring(0, _config.baseUrl.length - 1)
        : _config.baseUrl;
    final pathJoined = '$base/chat/completions';
    final uri = Uri.parse(pathJoined);

    final config = _config;
    final apiVersion = config is AzureConfig ? config.apiVersion : null;
    if (apiVersion != null && apiVersion.isNotEmpty) {
      return uri.replace(queryParameters: {'api-version': apiVersion});
    }
    return uri;
  }

  @override
  Future<Map<String, dynamic>?> extract({
    required String transcript,
    required AssistantAction action,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_config.kind == CloudProviderKind.anthropic) {
      throw CloudHardError(
        'Anthropic is not handled by OpenAiCompatibleAdapter. '
        'Use AnthropicAdapter (Slice 7) instead.',
      );
    }

    // 1. Translate OACP schema → OpenAI tool definition.
    final toolJson = _translator.translate(action);
    final functionDef = toolJson['function'] as Map<String, dynamic>;
    final functionName = functionDef['name'] as String;

    // 2. System prompt + user message body.
    final systemPrompt = _buildSystemPrompt(action);
    final body = <String, dynamic>{
      'model': _config.model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': transcript},
      ],
      'tools': [toolJson],
      'tool_choice': {
        'type': 'function',
        'function': {'name': functionName},
      },
    };

    final url = _chatCompletionsUri();

    // Grep-friendly request log: `adb logcat | grep HarkCloudReq`.
    // Never logs the API key.
    final stopwatch = Stopwatch()..start();
    debugPrint(
      'HarkCloudReq: kind=${_config.kind.wireName} '
      'url=$url model=${_config.model} action=$functionName '
      'transcript="$transcript"',
    );

    final http.Response response;
    try {
      response = await _http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${_config.apiKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException catch (e) {
      debugPrint(
        'HarkCloudErr: timeout after ${timeout.inSeconds}s url=$url',
      );
      throw CloudUnavailableError(
        'Cloud request timed out after ${timeout.inSeconds}s',
        cause: e,
      );
    } catch (e) {
      debugPrint('HarkCloudErr: transport url=$url $e');
      throw CloudUnavailableError(
        'Cloud transport error: $e',
        cause: e,
      );
    }

    if (response.statusCode >= 400) {
      debugPrint(
        'HarkCloudErr: HTTP ${response.statusCode} url=$url '
        'body=${response.body}',
      );
      if (response.statusCode == 404) {
        throw CloudHardError(
          'Provider returned 404 — check your base URL, deployment '
          'name (${_config.model}), and api-version. Azure said: '
          '${response.body}',
        );
      }
      throw CloudUnavailableError(
        'HTTP ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }

    // 3. Parse response.
    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint(
        'HarkCloudErr: malformed response body=${response.body}',
      );
      throw CloudUnavailableError(
        'Provider response was not valid JSON',
        cause: e,
      );
    }

    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw CloudUnavailableError(
        'Provider response had no choices: ${response.body}',
      );
    }
    final message =
        (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
    final toolCalls = message?['tool_calls'] as List?;
    if (toolCalls == null || toolCalls.isEmpty) {
      debugPrint(
        'HarkCloudErr: no tool_calls in response despite tool_choice. '
        'finish_reason=${(choices.first as Map)['finish_reason']} '
        'body=${response.body}',
      );
      throw CloudUnavailableError(
        'Provider did not return a tool call',
      );
    }

    final firstCall = toolCalls.first as Map<String, dynamic>;
    final fn = firstCall['function'] as Map<String, dynamic>;
    final argsRaw = fn['arguments'] as String;

    Map<String, dynamic> argsMap;
    try {
      argsMap = jsonDecode(argsRaw) as Map<String, dynamic>;
    } catch (e) {
      throw CloudUnavailableError(
        'Tool call arguments were not valid JSON: $argsRaw',
        cause: e,
      );
    }

    // 4. Validate against the OACP schema with the same coercion rules
    //    as the local path. Returns null if required slots are missing
    //    — resolver maps that to slot_filling_failed.
    final validated = _validator.validateMap(argsMap, action);
    stopwatch.stop();
    debugPrint(
      'HarkCloudRes: ${stopwatch.elapsedMilliseconds}ms '
      'action=$functionName args=$argsMap '
      'validated=${validated != null}',
    );
    return validated;
  }

  /// Build a compact system prompt for the extraction call. Keeps the
  /// instruction language short and surfaces entity context (aliases /
  /// known values) from the action's parameter metadata.
  String _buildSystemPrompt(AssistantAction action) {
    final lines = <String>[
      'You extract structured parameters from a single user voice '
          'command for the action "${action.displayName}". '
          'Call the provided function exactly once with the parameters '
          'you can extract from the user message.',
      'Rules:',
      '- Only fill parameters that are explicitly stated in the user '
          'message. Do not invent values.',
      '- For optional parameters, omit them if the user did not say them.',
      '- For enum parameters, choose the closest canonical value.',
      '- Do not respond in prose. Always call the function.',
    ];

    final entityBlock = _translator.buildEntityContextBlock(action);
    if (entityBlock != null) {
      lines.add('');
      lines.add(entityBlock);
    }

    return lines.join('\n');
  }

  /// Release the underlying HTTP client. Slice 4 wires this via
  /// `ref.onDispose` so old clients don't leak when the cloud config
  /// changes.
  void close() {
    if (_ownsClient) _http.close();
  }
}
