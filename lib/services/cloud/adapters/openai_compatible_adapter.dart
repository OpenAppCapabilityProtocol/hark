import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:openai_dart/openai_dart.dart';

import '../../../models/assistant_action.dart';
import '../cloud_errors.dart';
import '../cloud_provider_config.dart';
import '../hark_llm_client.dart';
import '../oacp_to_tool_schema.dart';
import '../slot_result_validator.dart';

/// Cloud slot filler that targets any OpenAI-compatible backend.
///
/// Covers in one client:
/// - OpenAI direct (`api.openai.com/v1`) via `Authorization: Bearer`
/// - Azure OpenAI (classic per-deployment URL or v1/Foundry surface)
///   via `api-key` header + `?api-version=...` query param
/// - Gemini OpenAI-compat endpoint
///   (`generativelanguage.googleapis.com/v1beta/openai`) via Bearer
/// - Custom OpenAI-compatible backends (OpenRouter, LiteLLM, vLLM,
///   Together, Groq, self-hosted) via Bearer
///
/// Anthropic is NOT handled here — its native `tool_use` shape needs
/// the dedicated [AnthropicAdapter] (Slice 7).
///
/// **Per-call shape:**
/// 1. Translate the action's parameters into an OpenAI tool definition
///    via [OacpToToolSchema].
/// 2. Build a system prompt with extraction instructions + entity
///    context (aliases, known entities) from the same translator.
/// 3. POST chat/completions with `tools=[tool]`,
///    `tool_choice=function(name)` so the model is forced to call our
///    tool (no chit-chat).
/// 4. Parse `tool_calls[0].function.arguments` (JSON string).
/// 5. Validate via [SlotResultValidator] — same coercion rules as the
///    on-device path.
///
/// Failures map to the [HarkLlmClient] failure semantics:
/// - Network / 5xx / malformed JSON → [CloudUnavailableError]
/// - 401 → [CloudUnavailableError] (recoverable: fix key in settings;
///   immediate fallback in CLOUD_PREFERRED is desired)
/// - 404 → [CloudHardError] (deployment / model not found, user must
///   fix it)
/// - Schema with no parameters / unsupported config → [CloudHardError]
/// - Validated map missing required slots → return null (matches local
///   path's `slot_filling_failed`)
class OpenAiCompatibleAdapter implements HarkLlmClient {
  OpenAiCompatibleAdapter(this._config)
      : _client = _buildClient(_config),
        _translator = const OacpToToolSchema(),
        _validator = const SlotResultValidator();

  final CloudProviderConfig _config;
  final OpenAIClient _client;
  final OacpToToolSchema _translator;
  final SlotResultValidator _validator;

  /// Build an [OpenAIClient] from a [CloudProviderConfig]. Dispatches
  /// on `kind` to pick the right auth provider and wire the api-version
  /// query param for Azure.
  static OpenAIClient _buildClient(CloudProviderConfig config) {
    switch (config.kind) {
      case CloudProviderKind.azureOpenAi:
        final azure = config as AzureConfig;
        return OpenAIClient(
          config: OpenAIConfig(
            baseUrl: azure.baseUrl,
            authProvider: AzureApiKeyProvider(azure.apiKey),
            apiVersion: azure.apiVersion,
            timeout: const Duration(seconds: 15),
          ),
        );

      case CloudProviderKind.openai:
      case CloudProviderKind.gemini:
      case CloudProviderKind.customOpenAi:
        return OpenAIClient(
          config: OpenAIConfig(
            baseUrl: config.baseUrl,
            authProvider: ApiKeyProvider(config.apiKey),
            timeout: const Duration(seconds: 15),
          ),
        );

      case CloudProviderKind.anthropic:
        throw CloudHardError(
          'Anthropic is not handled by OpenAiCompatibleAdapter. '
          'Use AnthropicAdapter (Slice 7) instead.',
        );
    }
  }

  @override
  Future<Map<String, dynamic>?> extract({
    required String transcript,
    required AssistantAction action,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    // 1. Translate OACP schema → OpenAI tool definition.
    final toolJson = _translator.translate(action);
    final functionDef = toolJson['function'] as Map<String, dynamic>;
    final functionName = functionDef['name'] as String;
    final tool = Tool.function(
      name: functionName,
      description: functionDef['description'] as String,
      parameters: functionDef['parameters'] as Map<String, dynamic>,
    );

    // 2. Build messages: system prompt with entity context, then user
    //    transcript verbatim. Force the tool call so the model can't
    //    answer in prose.
    final systemPrompt = _buildSystemPrompt(action);
    final messages = [
      ChatMessage.system(systemPrompt),
      ChatMessage.user(transcript),
    ];

    // 3. POST chat/completions with the tool, forcing its invocation.
    final ChatCompletion response;
    try {
      response = await _client.chat.completions
          .create(
            ChatCompletionCreateRequest(
              model: _config.model,
              messages: messages,
              tools: [tool],
              toolChoice: ToolChoice.function(functionName),
            ),
          )
          .timeout(timeout);
    } on TimeoutException catch (e) {
      throw CloudUnavailableError(
        'Cloud request timed out after ${timeout.inSeconds}s',
        cause: e,
      );
    } on OpenAIClientException catch (e) {
      throw _mapClientException(e);
    } catch (e) {
      throw CloudUnavailableError(
        'Cloud request failed: $e',
        cause: e,
      );
    }

    // 4. Extract tool call arguments. We forced the call, so anything
    //    else is malformed.
    if (!response.hasToolCalls) {
      debugPrint(
        'OpenAiCompatibleAdapter: no tool call in response despite '
        'tool_choice=function — finish_reason='
        '${response.choices.first.finishReason}',
      );
      throw CloudUnavailableError(
        'Provider did not return a tool call',
      );
    }
    final toolCall = response.allToolCalls.first;
    final argsRaw = toolCall.function.arguments;

    Map<String, dynamic> argsMap;
    try {
      argsMap = jsonDecode(argsRaw) as Map<String, dynamic>;
    } catch (e) {
      throw CloudUnavailableError(
        'Tool call arguments were not valid JSON: $argsRaw',
        cause: e,
      );
    }

    // 5. Validate against the OACP schema with the same coercion rules
    //    as the local path. Returns null if required slots are missing
    //    — resolver maps that to slot_filling_failed.
    return _validator.validateMap(argsMap, action);
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

  /// Map an [OpenAIClientException] to the appropriate cloud error.
  /// 401 / 429 / 5xx / network → recoverable (fall back to local in
  /// CLOUD_PREFERRED). 404 → hard (user must fix config).
  Exception _mapClientException(OpenAIClientException e) {
    final code = e.code;
    if (code == 404) {
      return CloudHardError(
        'Provider returned 404 — check your base URL and model / '
        'deployment name. Original message: ${e.message}',
        cause: e,
      );
    }
    return CloudUnavailableError(
      e.message,
      cause: e,
      statusCode: code,
    );
  }

  /// Release the underlying HTTP client. Adapters live for the
  /// lifetime of the cloud config so this is rarely called outside of
  /// tests.
  void close() {
    _client.close();
  }
}
