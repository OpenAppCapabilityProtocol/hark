import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'bench_types.dart';

/// Evaluates a loaded generation model on the slot-filling gold set.
///
/// Builds a prompt per case from the action definition in the gold
/// fixtures, sends it to the model via `engine.create`, collects the
/// streamed response, extracts a JSON object, and compares against the
/// expected parameter map. Metrics capture JSON validity, exact-match
/// accuracy, type-correct accuracy, required-field population, and
/// hallucinations (values that look made up).
///
/// The prompt shape matches the one hark-release/lib/state/
/// slot_filling_notifier.dart already uses for flutter_gemma, minus
/// the /no_think directive (which is Qwen-specific; llamadart's chat
/// template auto-detection handles Qwen3 thinking mode via
/// `enableThinking` on `create`).
class SlotFillEvaluator {
  SlotFillEvaluator({
    required this.engine,
    required this.goldSet,
    void Function(String)? log,
  }) : _log = log ?? ((_) {});

  final LlamaEngine engine;
  final SlotFillGoldSet goldSet;
  final void Function(String) _log;

  Future<SlotFillMetrics> run() async {
    _log('Slot-fill eval: running ${goldSet.cases.length} cases');

    var jsonValid = 0;
    var exactMatch = 0;
    var typeCorrect = 0;
    var hallucinations = 0;
    var requiredFieldsPopulated = 0;
    var requiredFieldsTotal = 0;
    final failureDetails = <String>[];

    for (final c in goldSet.cases) {
      final actionDef = goldSet.fixtures[c.actionKey];
      if (actionDef == null) {
        failureDetails.add('${c.id}: unknown action ${c.actionKey}');
        continue;
      }

      final prompt = _buildPrompt(c, actionDef);
      final response = await _runGeneration(prompt);

      final parsed = _extractJson(response);
      if (parsed == null) {
        failureDetails.add(
          '${c.id} [${c.category}] invalid JSON: '
          '${_truncate(response, 120)}',
        );
        continue;
      }
      jsonValid += 1;

      // Required field check
      for (final p in actionDef.parameters.where((p) => p.required)) {
        requiredFieldsTotal += 1;
        final value = parsed[p.name];
        if (value != null && _nonEmpty(value)) {
          requiredFieldsPopulated += 1;
        }
      }

      final typeOk = _allTypesCorrect(parsed, actionDef);
      if (typeOk) typeCorrect += 1;

      final matches = _exactMatch(parsed, c.expected, actionDef);
      if (matches) {
        exactMatch += 1;
      } else {
        failureDetails.add(
          '${c.id} [${c.category}] "${c.utterance}"\n'
          '    expected: ${jsonEncode(c.expected)}\n'
          '    got:      ${jsonEncode(_pickDefinedParams(parsed, actionDef))}',
        );
      }

      if (_isHallucinated(parsed, c.expected, actionDef)) {
        hallucinations += 1;
      }
    }

    return SlotFillMetrics(
      totalCases: goldSet.cases.length,
      jsonValid: jsonValid,
      exactMatch: exactMatch,
      typeCorrect: typeCorrect,
      hallucinations: hallucinations,
      requiredFieldsPopulated: requiredFieldsPopulated,
      requiredFieldsTotal: requiredFieldsTotal,
      failureDetails: failureDetails,
    );
  }

  String _buildPrompt(SlotFillCase c, SlotFillActionDef actionDef) {
    final buf = StringBuffer();
    buf.writeln('Extract parameters from the voice command below.');
    buf.writeln('ONLY extract values explicitly stated in the voice command.');
    buf.writeln(
      'If a parameter is NOT mentioned, set it to null. '
      'Do NOT guess or use example values.',
    );
    buf.writeln('Return ONLY a JSON object.\n');
    buf.writeln('Action: ${actionDef.actionKey}');
    buf.writeln('Voice command: "${c.utterance}"\n');
    buf.writeln('Parameters:');
    for (final p in actionDef.parameters) {
      buf.write('"${p.name}" (${p.typeString}');
      if (p.required) buf.write(', required');
      buf.writeln(')');
      if (p.description != null && p.description!.isNotEmpty) {
        buf.writeln('  description: ${p.description}');
      }
      if (p.examples.isNotEmpty) {
        buf.writeln('  examples: ${p.examples.join(", ")}');
      }
      if (p.minimum != null || p.maximum != null) {
        final bounds = <String>[];
        if (p.minimum != null) bounds.add('min: ${p.minimum}');
        if (p.maximum != null) bounds.add('max: ${p.maximum}');
        buf.writeln('  ${bounds.join(", ")}');
      }
      buf.writeln();
    }
    buf.write('JSON:');
    return buf.toString();
  }

  Future<String> _runGeneration(String prompt) async {
    final messages = <LlamaChatMessage>[
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: prompt,
      ),
    ];

    final buffer = StringBuffer();
    try {
      await for (final chunk in engine.create(messages, enableThinking: false)) {
        for (final choice in chunk.choices) {
          final content = choice.delta.content;
          if (content != null) buffer.write(content);
        }
      }
    } catch (e) {
      _log('  slot-fill generation error: $e');
      return '';
    }
    return buffer.toString();
  }

  Map<String, dynamic>? _extractJson(String raw) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      cleaned = cleaned
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '');
    }
    final open = cleaned.indexOf('{');
    final close = cleaned.lastIndexOf('}');
    if (open == -1 || close == -1 || close <= open) return null;
    final slice = cleaned.substring(open, close + 1);
    try {
      final decoded = jsonDecode(slice);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _allTypesCorrect(
    Map<String, dynamic> parsed,
    SlotFillActionDef actionDef,
  ) {
    for (final p in actionDef.parameters) {
      final value = parsed[p.name];
      if (value == null) continue; // null is fine if optional
      switch (p.type) {
        case SlotParamType.string:
          if (value is! String) return false;
          break;
        case SlotParamType.integer:
          if (value is! int) {
            // Allow int-coercible doubles with no fractional part
            if (!(value is double && value == value.roundToDouble())) {
              return false;
            }
          }
          break;
        case SlotParamType.number:
          if (value is! num) return false;
          break;
        case SlotParamType.boolean:
          if (value is! bool) return false;
          break;
        case SlotParamType.enumType:
        case SlotParamType.other:
          break;
      }
    }
    return true;
  }

  /// Exact match: every expected key/value is present in [parsed] AND
  /// no extra parameters are populated with non-null values beyond those
  /// in expected. String comparison is case-insensitive and
  /// whitespace-trimmed; numeric comparison is value-equal.
  bool _exactMatch(
    Map<String, dynamic> parsed,
    Map<String, dynamic> expected,
    SlotFillActionDef actionDef,
  ) {
    // Check that every expected value matches.
    for (final entry in expected.entries) {
      final got = parsed[entry.key];
      if (!_valuesEqual(got, entry.value)) return false;
    }
    // Check that no extra defined param was populated with a value.
    for (final p in actionDef.parameters) {
      if (expected.containsKey(p.name)) continue;
      final got = parsed[p.name];
      if (got != null && _nonEmpty(got)) return false;
    }
    return true;
  }

  bool _valuesEqual(dynamic got, dynamic expected) {
    if (got == null && expected == null) return true;
    if (got == null || expected == null) return false;
    if (expected is String && got is String) {
      return expected.trim().toLowerCase() == got.trim().toLowerCase();
    }
    if (expected is num && got is num) {
      return expected == got;
    }
    return got == expected;
  }

  bool _nonEmpty(dynamic value) {
    if (value == null) return false;
    if (value is String && value.trim().isEmpty) return false;
    return true;
  }

  /// A result is "hallucinated" if any non-expected parameter got
  /// populated with a value that isn't present in the utterance text.
  /// This is a conservative heuristic — false positives are OK, we are
  /// measuring the max plausible hallucination rate.
  bool _isHallucinated(
    Map<String, dynamic> parsed,
    Map<String, dynamic> expected,
    SlotFillActionDef actionDef,
  ) {
    for (final p in actionDef.parameters) {
      if (expected.containsKey(p.name)) continue;
      final got = parsed[p.name];
      if (got == null) continue;
      if (!_nonEmpty(got)) continue;
      return true;
    }
    return false;
  }

  Map<String, dynamic> _pickDefinedParams(
    Map<String, dynamic> parsed,
    SlotFillActionDef actionDef,
  ) {
    return {
      for (final p in actionDef.parameters)
        if (parsed.containsKey(p.name) && parsed[p.name] != null)
          p.name: parsed[p.name],
    };
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
