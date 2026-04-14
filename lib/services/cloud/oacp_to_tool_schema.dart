import '../../models/assistant_action.dart';

/// Translates an [AssistantAction] (built from an OACP manifest) into an
/// OpenAI / Azure / Gemini compatible tool definition.
///
/// Output shape (per the OpenAI Chat Completions tool-calling spec):
///
/// ```json
/// {
///   "type": "function",
///   "function": {
///     "name": "play_music",
///     "description": "Play a song on the music player.",
///     "parameters": {
///       "type": "object",
///       "properties": {
///         "song":   {"type": "string", "description": "Song title"},
///         "artist": {"type": "string", "description": "Artist name"}
///       },
///       "required": ["song"]
///     }
///   }
/// }
/// ```
///
/// Anthropic's native shape is similar but uses `input_schema` instead of
/// `function.parameters` and skips the outer `type: function` wrapper.
/// The Slice 7 Anthropic adapter will adapt this output, not produce its
/// own translator from scratch — keep all OACP→schema logic in one
/// place.
///
/// Field-by-field mapping (keep in sync with
/// [AssistantActionParameter] in `lib/models/assistant_action.dart`):
///
/// | OACP field                       | JSON Schema target           |
/// |----------------------------------|------------------------------|
/// | `name`                           | property key                 |
/// | `type`                           | `type` (with mapping table)  |
/// | `required`                       | added to `required[]`        |
/// | `description` + `extractionHint` | merged `description`         |
/// | `enumValues`                     | `enum[]`                     |
/// | `defaultValue`                   | `default`                    |
/// | `minimum` / `maximum`            | `minimum` / `maximum`        |
/// | `pattern`                        | `pattern`                    |
/// | `examples`                       | `examples[]`                 |
/// | `entityType` / `entitySnapshot`  | system-prompt augmentation   |
/// | `aliases`                        | system-prompt augmentation   |
///
/// Entity hints and aliases have no native JSON Schema slot. The
/// adapter is responsible for surfacing them via the system prompt
/// (e.g. "When the user says X, the canonical entity name is Y").
/// This translator does NOT include them in the schema output.
class OacpToToolSchema {
  const OacpToToolSchema();

  /// Sanitize an OACP action id into a function name acceptable to
  /// providers (OpenAI / Azure require `^[a-zA-Z0-9_-]{1,64}$`).
  static String sanitizeFunctionName(String sourceId, String actionId) {
    final raw = '${sourceId}__$actionId';
    final cleaned = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  /// Translate an [AssistantAction] into a tool definition map suitable
  /// for posting to OpenAI/Azure/Gemini chat completions.
  Map<String, dynamic> translate(AssistantAction action) {
    final properties = <String, dynamic>{};
    final required = <String>[];

    for (final p in action.parameters) {
      properties[p.name] = _parameterToSchema(p);
      if (p.required) required.add(p.name);
    }

    final description = _buildActionDescription(action);

    return {
      'type': 'function',
      'function': {
        'name': sanitizeFunctionName(action.sourceId, action.actionId),
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      },
    };
  }

  Map<String, dynamic> _parameterToSchema(AssistantActionParameter p) {
    final schema = <String, dynamic>{
      'type': _mapType(p.type),
    };

    final desc = _mergeDescription(p.description, p.extractionHint);
    if (desc != null) schema['description'] = desc;

    if (p.enumValues.isNotEmpty) {
      // Enum-type collapses to `string` + `enum[]`. Other types with
      // enumValues (rare but legal in OACP) keep their declared type.
      schema['enum'] = List<String>.from(p.enumValues);
    }

    if (p.defaultValue != null) schema['default'] = p.defaultValue;
    if (p.minimum != null) schema['minimum'] = p.minimum;
    if (p.maximum != null) schema['maximum'] = p.maximum;
    if (p.pattern != null && p.pattern!.isNotEmpty) {
      schema['pattern'] = p.pattern;
    }
    if (p.examples.isNotEmpty) {
      schema['examples'] = List<dynamic>.from(p.examples);
    }

    return schema;
  }

  /// OACP's `type` strings map to JSON Schema types as follows:
  ///
  /// | OACP        | JSON Schema |
  /// |-------------|-------------|
  /// | `string`    | `string`    |
  /// | `integer`   | `integer`   |
  /// | `number`    | `number`    |
  /// | `double`    | `number`    |
  /// | `boolean`   | `boolean`   |
  /// | `enum`      | `string`    |
  /// | (anything else) | `string` |
  String _mapType(String oacpType) {
    switch (oacpType) {
      case 'string':
        return 'string';
      case 'integer':
        return 'integer';
      case 'number':
      case 'double':
        return 'number';
      case 'boolean':
        return 'boolean';
      case 'enum':
        return 'string';
      default:
        return 'string';
    }
  }

  String? _mergeDescription(String? description, String? extractionHint) {
    final parts = <String>[];
    if (description != null && description.isNotEmpty) parts.add(description);
    if (extractionHint != null && extractionHint.isNotEmpty) {
      parts.add(extractionHint);
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  String _buildActionDescription(AssistantAction action) {
    final parts = <String>[];
    if (action.description.isNotEmpty) parts.add(action.description);
    if (action.examples.isNotEmpty) {
      final examples = action.examples.take(3).join('", "');
      parts.add('Examples: "$examples".');
    }
    return parts.isEmpty ? action.displayName : parts.join(' ');
  }

  /// Build the entity / alias context block that should be appended to
  /// the system prompt for an action. Returns null if the action has no
  /// entity hints or aliases worth surfacing.
  ///
  /// Adapters call this separately from [translate] and inject the
  /// result into their system prompt — keeping schema (machine-readable)
  /// and entity context (natural language) cleanly separated.
  String? buildEntityContextBlock(AssistantAction action) {
    final lines = <String>[];

    for (final p in action.parameters) {
      // Surface entity disambiguation hints.
      if (p.entityDisambiguationPrompt != null &&
          p.entityDisambiguationPrompt!.isNotEmpty) {
        lines.add('- ${p.name}: ${p.entityDisambiguationPrompt}');
      }

      // Surface known entity snapshot values (e.g. installed app names).
      if (p.entitySnapshot.isNotEmpty) {
        final names = p.entitySnapshot
            .map((e) => e['name'] ?? e['id'] ?? '')
            .where((name) => name.toString().isNotEmpty)
            .take(20)
            .join(', ');
        if (names.isNotEmpty) {
          lines.add('- ${p.name} known values: $names');
        }
      }

      // Surface aliases (canonical → alternate spellings).
      if (p.aliases.isNotEmpty) {
        for (final entry in p.aliases.entries) {
          final aliases = entry.value.take(5).join(', ');
          lines.add('- ${p.name}: "${entry.key}" also called: $aliases');
        }
      }
    }

    if (lines.isEmpty) return null;
    return 'Context for parameter extraction:\n${lines.join('\n')}';
  }
}
