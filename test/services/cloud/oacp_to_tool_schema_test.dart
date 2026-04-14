import 'package:flutter_test/flutter_test.dart';
import 'package:hark/models/assistant_action.dart';
import 'package:hark/services/cloud/oacp_to_tool_schema.dart';

/// Helper: build a minimally-populated [AssistantAction] for tests. Most
/// fields are irrelevant to schema translation; we only care about
/// `sourceId`, `actionId`, `displayName`, `description`, `examples`, and
/// `parameters`.
AssistantAction _action({
  String sourceId = 'com.example',
  String actionId = 'do_thing',
  String displayName = 'Do Thing',
  String description = 'Performs the thing.',
  List<String> examples = const [],
  List<AssistantActionParameter> parameters = const [],
}) =>
    AssistantAction(
      sourceType: AssistantActionSourceType.oacp,
      sourceId: sourceId,
      actionId: actionId,
      displayName: displayName,
      description: description,
      confirmationMessage: 'Done.',
      domain: null,
      appDomains: const [],
      appKeywords: const [],
      appAliases: const [],
      aliases: const [],
      examples: examples,
      keywords: const [],
      disambiguationHints: const [],
      dispatchType: AssistantActionDispatchType.broadcast,
      androidAction: 'com.example.action',
      extrasMapping: const {},
      parameters: parameters,
    );

void main() {
  const translator = OacpToToolSchema();

  group('OacpToToolSchema.sanitizeFunctionName', () {
    test('joins source and action with double underscore', () {
      expect(
        OacpToToolSchema.sanitizeFunctionName('com.example.app', 'play_song'),
        'com_example_app__play_song',
      );
    });

    test('replaces invalid characters with underscore', () {
      expect(
        OacpToToolSchema.sanitizeFunctionName('a.b/c', 'x:y'),
        'a_b_c__x_y',
      );
    });

    test('truncates to 64 characters', () {
      final long = 'a' * 50;
      final out = OacpToToolSchema.sanitizeFunctionName(long, long);
      expect(out.length, 64);
    });
  });

  group('OacpToToolSchema.translate — empty parameters', () {
    test('zero-param action emits valid empty schema', () {
      final action = _action();
      final result = translator.translate(action);

      expect(result['type'], 'function');
      expect(result['function']['name'], 'com_example__do_thing');
      expect(result['function']['description'], 'Performs the thing.');

      final params = result['function']['parameters'] as Map<String, dynamic>;
      expect(params['type'], 'object');
      expect(params['properties'], isEmpty);
      expect(params.containsKey('required'), isFalse);
    });
  });

  group('OacpToToolSchema.translate — type mapping', () {
    test('string parameter', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
            description: 'Song title',
          ),
        ],
      );
      final params = translator.translate(action)['function']['parameters']
          as Map<String, dynamic>;
      final song = params['properties']['song'] as Map<String, dynamic>;
      expect(song['type'], 'string');
      expect(song['description'], 'Song title');
      expect(params['required'], ['song']);
    });

    test('integer parameter with bounds', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'minutes',
            type: 'integer',
            required: true,
            description: 'Timer length',
            minimum: 1,
            maximum: 1440,
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['minutes']
          as Map<String, dynamic>;
      expect(p['type'], 'integer');
      expect(p['minimum'], 1);
      expect(p['maximum'], 1440);
    });

    test('number / double parameter both map to JSON Schema number', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'temp',
            type: 'number',
            required: false,
          ),
          AssistantActionParameter(
            name: 'ratio',
            type: 'double',
            required: false,
          ),
        ],
      );
      final props = (translator.translate(action)['function']['parameters']
          as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
      expect(props['temp']['type'], 'number');
      expect(props['ratio']['type'], 'number');
    });

    test('boolean parameter', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'enabled',
            type: 'boolean',
            required: true,
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['enabled']
          as Map<String, dynamic>;
      expect(p['type'], 'boolean');
    });

    test('enum parameter collapses to string + enum[]', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'unit',
            type: 'enum',
            required: false,
            enumValues: ['celsius', 'fahrenheit'],
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['unit']
          as Map<String, dynamic>;
      expect(p['type'], 'string');
      expect(p['enum'], ['celsius', 'fahrenheit']);
    });

    test('unknown type defaults to string', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'mystery',
            type: 'wat',
            required: false,
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['mystery']
          as Map<String, dynamic>;
      expect(p['type'], 'string');
    });
  });

  group('OacpToToolSchema.translate — required[]', () {
    test('only required parameters appear in required[]', () {
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
      final params = translator.translate(action)['function']['parameters']
          as Map<String, dynamic>;
      expect(params['required'], ['song']);
    });

    test('all-optional action has no required[] key', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'artist',
            type: 'string',
            required: false,
          ),
        ],
      );
      final params = translator.translate(action)['function']['parameters']
          as Map<String, dynamic>;
      expect(params.containsKey('required'), isFalse);
    });
  });

  group('OacpToToolSchema.translate — description merging', () {
    test('description + extractionHint merge with space', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'query',
            type: 'string',
            required: true,
            description: 'Search query.',
            extractionHint: 'Use the user\'s exact words.',
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['query']
          as Map<String, dynamic>;
      expect(p['description'], "Search query. Use the user's exact words.");
    });

    test('only description present', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'q',
            type: 'string',
            required: false,
            description: 'just description',
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['q']
          as Map<String, dynamic>;
      expect(p['description'], 'just description');
    });

    test('neither description nor hint omits description key', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'q',
            type: 'string',
            required: false,
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['q']
          as Map<String, dynamic>;
      expect(p.containsKey('description'), isFalse);
    });
  });

  group('OacpToToolSchema.translate — examples + defaults', () {
    test('action examples appear in function description', () {
      final action = _action(
        description: 'Play music.',
        examples: const ['play despacito', 'play bohemian rhapsody'],
      );
      final desc =
          translator.translate(action)['function']['description'] as String;
      expect(desc, contains('Play music.'));
      expect(desc, contains('despacito'));
      expect(desc, contains('bohemian rhapsody'));
    });

    test('parameter defaultValue + examples + pattern propagate', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'lang',
            type: 'string',
            required: false,
            defaultValue: 'en',
            examples: ['en', 'fr', 'de'],
            pattern: r'^[a-z]{2}$',
          ),
        ],
      );
      final p = (translator.translate(action)['function']['parameters']
              as Map<String, dynamic>)['properties']['lang']
          as Map<String, dynamic>;
      expect(p['default'], 'en');
      expect(p['examples'], ['en', 'fr', 'de']);
      expect(p['pattern'], r'^[a-z]{2}$');
    });
  });

  group('OacpToToolSchema.buildEntityContextBlock', () {
    test('returns null when no entity context', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
          ),
        ],
      );
      expect(translator.buildEntityContextBlock(action), isNull);
    });

    test('surfaces entity disambiguation prompts', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'app',
            type: 'string',
            required: true,
            entityDisambiguationPrompt: 'Pick the music app the user named',
          ),
        ],
      );
      final block = translator.buildEntityContextBlock(action);
      expect(block, contains('Pick the music app'));
      expect(block, contains('app:'));
    });

    test('surfaces entitySnapshot known values (capped at 20)', () {
      final entities = [
        for (var i = 0; i < 30; i++) {'name': 'app$i'},
      ];
      final action = _action(
        parameters: [
          AssistantActionParameter(
            name: 'app',
            type: 'string',
            required: true,
            entitySnapshot: entities,
          ),
        ],
      );
      final block = translator.buildEntityContextBlock(action)!;
      expect(block, contains('app0'));
      expect(block, contains('app19'));
      expect(block, isNot(contains('app20')));
    });

    test('surfaces aliases', () {
      final action = _action(
        parameters: const [
          AssistantActionParameter(
            name: 'unit',
            type: 'string',
            required: false,
            aliases: {
              'celsius': ['c', 'centigrade', 'metric'],
            },
          ),
        ],
      );
      final block = translator.buildEntityContextBlock(action)!;
      expect(block, contains('"celsius"'));
      expect(block, contains('centigrade'));
    });
  });

  group('OacpToToolSchema.translate — realistic Hark-shaped fixtures', () {
    test('play music action (multi-param string with optional artist)', () {
      final action = _action(
        sourceId: 'com.example.music',
        actionId: 'play',
        description: 'Play a song on the music app.',
        examples: const [
          'play yesterday by the beatles',
          'play despacito',
        ],
        parameters: const [
          AssistantActionParameter(
            name: 'song',
            type: 'string',
            required: true,
            description: 'Song title.',
          ),
          AssistantActionParameter(
            name: 'artist',
            type: 'string',
            required: false,
            description: 'Artist name.',
          ),
        ],
      );
      final result = translator.translate(action);
      expect(result['function']['name'], 'com_example_music__play');
      final params = result['function']['parameters'] as Map<String, dynamic>;
      expect(params['required'], ['song']);
      expect(
        params['properties']['song']['type'],
        'string',
      );
      expect(
        params['properties']['artist']['type'],
        'string',
      );
    });

    test('set timer action (integer with bounds)', () {
      final action = _action(
        sourceId: 'com.example.clock',
        actionId: 'set_timer',
        description: 'Set a timer for N minutes.',
        parameters: const [
          AssistantActionParameter(
            name: 'minutes',
            type: 'integer',
            required: true,
            description: 'Timer duration in minutes.',
            minimum: 1,
            maximum: 1440,
          ),
        ],
      );
      final params = translator.translate(action)['function']['parameters']
          as Map<String, dynamic>;
      final minutes = params['properties']['minutes'] as Map<String, dynamic>;
      expect(minutes['type'], 'integer');
      expect(minutes['minimum'], 1);
      expect(minutes['maximum'], 1440);
      expect(params['required'], ['minutes']);
    });

    test('weather action (enum unit)', () {
      final action = _action(
        sourceId: 'org.example.weather',
        actionId: 'today',
        description: 'Get today\'s weather forecast.',
        parameters: const [
          AssistantActionParameter(
            name: 'unit',
            type: 'enum',
            required: false,
            enumValues: ['celsius', 'fahrenheit', 'kelvin'],
          ),
        ],
      );
      final params = translator.translate(action)['function']['parameters']
          as Map<String, dynamic>;
      final unit = params['properties']['unit'] as Map<String, dynamic>;
      expect(unit['type'], 'string');
      expect(unit['enum'], ['celsius', 'fahrenheit', 'kelvin']);
      expect(params.containsKey('required'), isFalse);
    });
  });
}
