import 'dart:convert';

import '../../models/assistant_action.dart';

/// Validates and coerces a slot-fill result against an [AssistantAction]'s
/// parameter schema. Shared by the local Qwen3 path and the cloud
/// [HarkLlmClient] adapters so both produce parameter maps that
/// [IntentDispatcher] can consume without re-validating.
///
/// Extracted from `lib/state/slot_filling_notifier.dart` (was `_parseOutput`
/// + `_coerceValue`). Net zero behavior change for the local path — the
/// notifier now delegates here.
///
/// Two entry points:
///
/// - [parseRawText] takes the raw text emitted by an LLM (which may be
///   wrapped in markdown fences, prefixed with reasoning, or otherwise
///   noisy). It strips fences, finds the first `{...}` block, parses it,
///   then validates against the schema.
/// - [validateMap] takes an already-parsed `Map<String, dynamic>` (e.g.
///   from a tool-call's `function.arguments` JSON). Cloud adapters use
///   this entry point because OpenAI/Azure/Gemini/Anthropic return
///   structured tool-call args, not free text.
///
/// Returns `null` from either entry point if a required parameter is
/// missing or fails type coercion. Callers treat null as "extraction
/// failed" and surface it as `slot_filling_failed` upstream.
class SlotResultValidator {
  const SlotResultValidator();

  /// Parse free-form LLM text output and validate against the action's
  /// parameter schema. Used by the on-device Qwen3 path.
  Map<String, dynamic>? parseRawText(String raw, AssistantAction action) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      cleaned = cleaned
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '');
    }

    final openBrace = cleaned.indexOf('{');
    final closeBrace = cleaned.lastIndexOf('}');
    if (openBrace == -1 || closeBrace == -1 || closeBrace <= openBrace) {
      return null;
    }
    cleaned = cleaned.substring(openBrace, closeBrace + 1);

    Map<String, dynamic> json;
    try {
      json = jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    return validateMap(json, action);
  }

  /// Validate an already-parsed parameter map against the action's
  /// schema. Used by cloud adapters that receive structured tool-call
  /// arguments rather than free text.
  Map<String, dynamic>? validateMap(
    Map<String, dynamic> input,
    AssistantAction action,
  ) {
    final result = <String, dynamic>{};
    for (final p in action.parameters) {
      final value = input[p.name];

      if (value == null) {
        if (p.required) return null;
        continue;
      }

      final coerced = _coerceValue(value, p);
      if (coerced == null) {
        if (p.required) return null;
        continue;
      }

      result[p.name] = coerced;
    }
    return result;
  }

  dynamic _coerceValue(dynamic value, AssistantActionParameter param) {
    switch (param.type) {
      case 'integer':
        if (value is int) return _clampInt(value, param);
        if (value is double) return _clampInt(value.round(), param);
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return _clampInt(parsed, param);
        }
        return null;

      case 'boolean':
        if (value is bool) return value;
        if (value is String) {
          final lower = value.toLowerCase();
          if (lower == 'true' || lower == 'yes') return true;
          if (lower == 'false' || lower == 'no') return false;
        }
        return null;

      case 'enum':
        final str = value.toString();
        if (param.enumValues.contains(str)) return str;
        // Try case-insensitive match.
        final lower = str.toLowerCase();
        for (final enumVal in param.enumValues) {
          if (enumVal.toLowerCase() == lower) return enumVal;
        }
        // Try alias match.
        for (final entry in param.aliases.entries) {
          for (final alias in entry.value) {
            if (alias.toLowerCase() == lower) return entry.key;
          }
        }
        return null;

      case 'number':
      case 'double':
        if (value is double) return _clampDouble(value, param);
        if (value is int) return _clampDouble(value.toDouble(), param);
        if (value is String) {
          final parsed = double.tryParse(value);
          if (parsed != null) return _clampDouble(parsed, param);
        }
        return null;

      case 'string':
        final str = value.toString().trim();
        return str.isEmpty ? null : str;

      default:
        return value;
    }
  }

  int _clampInt(int value, AssistantActionParameter param) {
    if (param.minimum != null && value < param.minimum!) {
      return param.minimum!.toInt();
    }
    if (param.maximum != null && value > param.maximum!) {
      return param.maximum!.toInt();
    }
    return value;
  }

  double _clampDouble(double value, AssistantActionParameter param) {
    if (param.minimum != null && value < param.minimum!) {
      return param.minimum!.toDouble();
    }
    if (param.maximum != null && value > param.maximum!) {
      return param.maximum!.toDouble();
    }
    return value;
  }
}
