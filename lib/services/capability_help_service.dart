import '../models/assistant_action.dart';

class CapabilityHelpResponse {
  const CapabilityHelpResponse({
    required this.displayText,
    required this.spokenText,
    required this.metadata,
  });

  final String displayText;
  final String spokenText;
  final String metadata;
}

class CapabilityHelpService {
  CapabilityHelpResponse? resolve(
    String transcript,
    List<AssistantAction> actions,
  ) {
    final normalizedTranscript = transcript.toLowerCase().trim();
    if (!_looksLikeCapabilityQuestion(normalizedTranscript)) {
      return null;
    }

    final groups = _buildGroups(actions);
    if (groups.isEmpty) {
      return const CapabilityHelpResponse(
        displayText: 'No OACP apps are available yet.',
        spokenText: 'No OACP apps are available yet.',
        metadata: 'capability_help',
      );
    }

    final requestedAppHint = _extractRequestedAppHint(normalizedTranscript);
    final matchedGroup = _matchGroup(normalizedTranscript, groups);
    if (matchedGroup != null) {
      return _buildAppHelp(matchedGroup);
    }

    if (requestedAppHint != null) {
      return _buildAppNotFoundHelp(requestedAppHint, groups);
    }

    return _buildCatalogHelp(groups);
  }

  bool _looksLikeCapabilityQuestion(String transcript) {
    for (final phrase in _capabilityQuestionPhrases) {
      if (transcript.contains(phrase)) {
        return true;
      }
    }

    final hasQuestionCue = _questionCueTokens.any(transcript.contains);
    final hasCapabilityCue = _capabilityCueTokens.any(transcript.contains);
    return hasQuestionCue && hasCapabilityCue;
  }

  List<_ActionGroup> _buildGroups(List<AssistantAction> actions) {
    final grouped = <String, List<AssistantAction>>{};
    for (final action in actions) {
      if (action.sourceType != AssistantActionSourceType.oacp) {
        continue;
      }
      grouped.putIfAbsent(action.sourceId, () => []).add(action);
    }

    final groups = grouped.entries.map((entry) {
      final appActions = [...entry.value]
        ..sort((left, right) => left.actionId.compareTo(right.actionId));
      final first = appActions.first;
      return _ActionGroup(
        sourceId: entry.key,
        displayName: first.displayName,
        aliases: {
          first.displayName.toLowerCase(),
          first.sourceId.toLowerCase(),
          ...first.appAliases.map((alias) => alias.toLowerCase()),
        },
        actions: appActions,
      );
    }).toList(growable: false)
      ..sort((left, right) => left.displayName.compareTo(right.displayName));

    return groups;
  }

  _ActionGroup? _matchGroup(
    String transcript,
    List<_ActionGroup> groups,
  ) {
    _ActionGroup? bestGroup;
    var bestScore = 0;

    final transcriptTokens = _tokenize(transcript);
    for (final group in groups) {
      var score = 0;
      for (final alias in group.aliases) {
        if (alias.isEmpty) {
          continue;
        }
        if (transcript.contains(alias)) {
          score += alias.contains('.') ? 4 : 6;
        }

        final aliasTokens = _tokenize(alias);
        final overlap = aliasTokens.intersection(transcriptTokens).length;
        if (overlap > 0 && aliasTokens.isNotEmpty) {
          score += overlap * 2;
          if (overlap == aliasTokens.length) {
            score += 3;
          }
        }
      }

      if (score > bestScore) {
        bestScore = score;
        bestGroup = group;
      }
    }

    if (bestScore < 4) {
      return null;
    }
    return bestGroup;
  }

  CapabilityHelpResponse _buildAppHelp(_ActionGroup group) {
    final lines = <String>[
      '${group.displayName} can do ${group.actions.length} thing${group.actions.length == 1 ? '' : 's'}:',
      for (final action in group.actions) '- ${_describeAction(action)}',
    ];

    return CapabilityHelpResponse(
      displayText: lines.join('\n'),
      spokenText:
          '${group.displayName} supports ${group.actions.length} action${group.actions.length == 1 ? '' : 's'}. I listed them in chat.',
      metadata: 'capability_help • ${group.sourceId}',
    );
  }

  CapabilityHelpResponse _buildCatalogHelp(List<_ActionGroup> groups) {
    final lines = <String>[
      'I currently support ${groups.length} OACP app${groups.length == 1 ? '' : 's'}:',
      for (final group in groups)
        '- ${group.displayName}: ${group.actions.length} action${group.actions.length == 1 ? '' : 's'}',
      'Ask about a specific app, like "what can you do in Libre Camera?", and I will list its actions.',
    ];

    return CapabilityHelpResponse(
      displayText: lines.join('\n'),
      spokenText:
          'I support ${groups.length} OACP app${groups.length == 1 ? '' : 's'}. I listed them in chat.',
      metadata: 'capability_help • all_apps',
    );
  }

  CapabilityHelpResponse _buildAppNotFoundHelp(
    String requestedAppHint,
    List<_ActionGroup> groups,
  ) {
    final lines = <String>[
      'I could not find an installed OACP app matching "$requestedAppHint".',
      'Installed OACP apps:',
      for (final group in groups)
        '- ${group.displayName}: ${group.actions.length} action${group.actions.length == 1 ? '' : 's'}',
    ];

    return CapabilityHelpResponse(
      displayText: lines.join('\n'),
      spokenText:
          'I could not find an installed OACP app matching $requestedAppHint. I listed the supported apps in chat.',
      metadata: 'capability_help • app_not_found',
    );
  }

  String _describeAction(AssistantAction action) {
    final buffer = StringBuffer(action.description.trim());
    if (action.parameters.isEmpty) {
      return buffer.toString();
    }

    final requiredParameters = action.parameters
        .where((parameter) => parameter.required)
        .map((parameter) => parameter.name)
        .toList(growable: false);
    final optionalParameters = action.parameters
        .where((parameter) => !parameter.required)
        .map((parameter) => parameter.name)
        .toList(growable: false);

    if (requiredParameters.isNotEmpty) {
      buffer.write(' Required: ${requiredParameters.join(', ')}.');
    }
    if (optionalParameters.isNotEmpty) {
      buffer.write(' Optional: ${optionalParameters.join(', ')}.');
    }

    return buffer.toString();
  }

  Set<String> _tokenize(String value) {
    return value
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.isNotEmpty)
        .toSet();
  }

  String? _extractRequestedAppHint(String transcript) {
    for (final pattern in _specificAppQuestionPatterns) {
      final match = pattern.firstMatch(transcript);
      final hint = match?.group(1)?.trim();
      if (hint != null && hint.isNotEmpty) {
        return hint;
      }
    }
    return null;
  }
}

class _ActionGroup {
  const _ActionGroup({
    required this.sourceId,
    required this.displayName,
    required this.aliases,
    required this.actions,
  });

  final String sourceId;
  final String displayName;
  final Set<String> aliases;
  final List<AssistantAction> actions;
}

const _capabilityQuestionPhrases = <String>[
  'what can you do',
  'what can i do',
  'what can you help',
  'what are your capabilities',
  'what apps do you support',
  'which apps do you support',
  'show available actions',
  'list available actions',
  'list actions',
  'show actions',
  'show capabilities',
  'list capabilities',
  'what actions are available',
  'what apps are available',
];

const _questionCueTokens = <String>[
  'what',
  'which',
  'show',
  'list',
  'help',
];

const _capabilityCueTokens = <String>[
  'can you do',
  'actions',
  'capabilities',
  'apps',
  'support',
  'available',
  'do for me',
];

final _specificAppQuestionPatterns = <RegExp>[
  RegExp(r'what can you do(?: for me)? in (.+)$', caseSensitive: false),
  RegExp(r'what can you do(?: for me)? on (.+)$', caseSensitive: false),
  RegExp(r'what can you do(?: for me)? for (.+)$', caseSensitive: false),
  RegExp(r'list available actions in (.+)$', caseSensitive: false),
  RegExp(r'list available actions for (.+)$', caseSensitive: false),
  RegExp(r'show available actions in (.+)$', caseSensitive: false),
  RegExp(r'show available actions for (.+)$', caseSensitive: false),
  RegExp(r'list actions in (.+)$', caseSensitive: false),
  RegExp(r'list actions for (.+)$', caseSensitive: false),
  RegExp(r'show actions in (.+)$', caseSensitive: false),
  RegExp(r'show actions for (.+)$', caseSensitive: false),
  RegExp(r'list capabilities in (.+)$', caseSensitive: false),
  RegExp(r'list capabilities for (.+)$', caseSensitive: false),
  RegExp(r'show capabilities in (.+)$', caseSensitive: false),
  RegExp(r'show capabilities for (.+)$', caseSensitive: false),
];
