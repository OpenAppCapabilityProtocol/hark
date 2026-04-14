import 'package:flutter_test/flutter_test.dart';
import 'package:hark/models/assistant_action.dart';
import 'package:hark/services/cloud/slot_result_validator.dart';

AssistantAction _action({
  required List<AssistantActionParameter> parameters,
}) =>
    AssistantAction(
      sourceType: AssistantActionSourceType.oacp,
      sourceId: 'com.example',
      actionId: 'do',
      displayName: 'Do',
      description: '',
      confirmationMessage: '',
      domain: null,
      appDomains: const [],
      appKeywords: const [],
      appAliases: const [],
      aliases: const [],
      examples: const [],
      keywords: const [],
      disambiguationHints: const [],
      dispatchType: AssistantActionDispatchType.broadcast,
      androidAction: 'x',
      extrasMapping: const {},
      parameters: parameters,
    );

void main() {
  const validator = SlotResultValidator();

  group('parseRawText — text cleanup', () {
    test('strips ```json fences', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      const raw = '```json\n{"song": "yesterday"}\n```';
      expect(validator.parseRawText(raw, action), {'song': 'yesterday'});
    });

    test('strips bare ``` fences', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      const raw = '```\n{"song": "yesterday"}\n```';
      expect(validator.parseRawText(raw, action), {'song': 'yesterday'});
    });

    test('finds JSON inside surrounding noise', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      const raw = 'Sure! Here is the JSON: {"song": "yesterday"} hope this helps.';
      expect(validator.parseRawText(raw, action), {'song': 'yesterday'});
    });

    test('returns null on no JSON object', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      expect(validator.parseRawText('no braces here', action), isNull);
    });

    test('returns null on malformed JSON', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      expect(validator.parseRawText('{"song": ', action), isNull);
    });
  });

  group('validateMap — required handling', () {
    test('missing required field returns null', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      expect(validator.validateMap({}, action), isNull);
    });

    test('missing optional field skipped, not failed', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
          AssistantActionParameter(
            name: 'artist',
            type: 'string',
            required: false,
          ),
        ],
      );
      expect(
        validator.validateMap({'song': 'yesterday'}, action),
        {'song': 'yesterday'},
      );
    });
  });

  group('validateMap — type coercion', () {
    test('integer accepts int, double, string', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'n',
            type: 'integer',
            required: true,
          ),
        ],
      );
      expect(validator.validateMap({'n': 5}, action), {'n': 5});
      expect(validator.validateMap({'n': 5.7}, action), {'n': 6});
      expect(validator.validateMap({'n': '12'}, action), {'n': 12});
      expect(validator.validateMap({'n': 'nope'}, action), isNull);
    });

    test('integer clamps to bounds', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'n',
            type: 'integer',
            required: true,
            minimum: 0,
            maximum: 100,
          ),
        ],
      );
      expect(validator.validateMap({'n': -5}, action), {'n': 0});
      expect(validator.validateMap({'n': 1000}, action), {'n': 100});
    });

    test('boolean accepts bool, yes/no, true/false strings', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'on',
            type: 'boolean',
            required: true,
          ),
        ],
      );
      expect(validator.validateMap({'on': true}, action), {'on': true});
      expect(validator.validateMap({'on': 'yes'}, action), {'on': true});
      expect(validator.validateMap({'on': 'YES'}, action), {'on': true});
      expect(validator.validateMap({'on': 'no'}, action), {'on': false});
      expect(validator.validateMap({'on': 'maybe'}, action), isNull);
    });

    test('enum case-insensitive + alias match', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'unit',
            type: 'enum',
            required: true,
            enumValues: ['celsius', 'fahrenheit'],
            aliases: {
              'celsius': ['c', 'metric'],
            },
          ),
        ],
      );
      expect(
        validator.validateMap({'unit': 'celsius'}, action),
        {'unit': 'celsius'},
      );
      expect(
        validator.validateMap({'unit': 'CELSIUS'}, action),
        {'unit': 'celsius'},
      );
      expect(
        validator.validateMap({'unit': 'metric'}, action),
        {'unit': 'celsius'},
      );
      expect(validator.validateMap({'unit': 'kelvin'}, action), isNull);
    });

    test('number/double accepts int, double, string and clamps', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'r',
            type: 'number',
            required: true,
            minimum: 0,
            maximum: 1,
          ),
        ],
      );
      expect(validator.validateMap({'r': 0.5}, action), {'r': 0.5});
      expect(validator.validateMap({'r': 1}, action), {'r': 1.0});
      expect(validator.validateMap({'r': '0.25'}, action), {'r': 0.25});
      expect(validator.validateMap({'r': 2.5}, action), {'r': 1.0});
      expect(validator.validateMap({'r': -1.0}, action), {'r': 0.0});
    });

    test('string trims and rejects empty', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'q',
            type: 'string',
            required: true,
          ),
        ],
      );
      expect(validator.validateMap({'q': '  hello  '}, action), {'q': 'hello'});
      expect(validator.validateMap({'q': '   '}, action), isNull);
    });
  });

  group('validateMap — extra keys', () {
    test('keys not in schema are dropped', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      expect(
        validator.validateMap(
          {'song': 'yesterday', 'extra': 'noise', 'artist': 'beatles'},
          action,
        ),
        {'song': 'yesterday'},
      );
    });
  });
}
