import 'package:flutter_test/flutter_test.dart';
import 'package:hark/models/assistant_action.dart';
import 'package:hark/services/capability_help_service.dart';

void main() {
  final service = CapabilityHelpService();
  final actions = <AssistantAction>[
    _action(
      sourceId: 'com.iakmds.librecamera',
      displayName: 'Libre Camera',
      actionId: 'take_photo_front_camera',
      description: 'Take a photo with the front camera.',
      appAliases: const ['camera'],
      parameters: const [
        AssistantActionParameter(
          name: 'duration_seconds',
          type: 'integer',
          required: false,
        ),
      ],
    ),
    _action(
      sourceId: 'org.wikipedia.dev',
      displayName: 'Wikipedia',
      actionId: 'search_articles',
      description: 'Search Wikipedia for a topic.',
      parameters: const [
        AssistantActionParameter(
          name: 'query',
          type: 'string',
          required: true,
        ),
      ],
    ),
  ];

  test('returns app-specific capability summary for matched app', () {
    final response = service.resolve(
      'what can you do in Libre Camera',
      actions,
    );

    expect(response, isNotNull);
    expect(response!.metadata, 'capability_help • com.iakmds.librecamera');
    expect(response.displayText, contains('Libre Camera can do 1 thing'));
    expect(response.displayText, contains('Optional: duration_seconds.'));
  });

  test('returns explicit app-not-found response for unmatched app-specific help', () {
    final response = service.resolve(
      'what can you do in Libre Camra',
      actions,
    );

    expect(response, isNotNull);
    expect(response!.metadata, 'capability_help • app_not_found');
    expect(
      response.displayText,
      contains('I could not find an installed OACP app matching "libre camra".'),
    );
    expect(response.displayText, contains('Installed OACP apps:'));
    expect(response.displayText, contains('Libre Camera: 1 action'));
  });

  test('returns catalog summary for generic support question', () {
    final response = service.resolve(
      'what apps do you support',
      actions,
    );

    expect(response, isNotNull);
    expect(response!.metadata, 'capability_help • all_apps');
    expect(response.displayText, contains('I currently support 2 OACP apps:'));
    expect(response.displayText, contains('Libre Camera: 1 action'));
    expect(response.displayText, contains('Wikipedia: 1 action'));
  });
}

AssistantAction _action({
  required String sourceId,
  required String displayName,
  required String actionId,
  required String description,
  List<String> appAliases = const [],
  List<AssistantActionParameter> parameters = const [],
}) {
  return AssistantAction(
    sourceType: AssistantActionSourceType.oacp,
    sourceId: sourceId,
    actionId: actionId,
    displayName: displayName,
    description: description,
    confirmationMessage: description,
    domain: null,
    appDomains: const [],
    appKeywords: const [],
    appAliases: appAliases,
    aliases: const [],
    examples: const [],
    keywords: const [],
    disambiguationHints: const [],
    dispatchType: AssistantActionDispatchType.broadcast,
    androidAction: '$sourceId.$actionId',
    extrasMapping: const {},
    parameters: parameters,
  );
}
