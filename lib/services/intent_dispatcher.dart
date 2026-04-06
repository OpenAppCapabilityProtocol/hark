import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;

import '../models/assistant_action.dart';
import '../models/resolved_action.dart';
import 'capability_registry.dart';

class DispatchResult {
  const DispatchResult({required this.success, this.requestId});

  final bool success;
  final String? requestId;
}

class IntentDispatcher {
  final CapabilityRegistry registry;

  IntentDispatcher(this.registry);

  int _requestCounter = 0;

  String _generateRequestId() {
    _requestCounter += 1;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'hark-$timestamp-$_requestCounter';
  }

  Future<DispatchResult> dispatch(ResolvedAction action) async {
    final actionDefinition = registry.findAction(
      action.sourceType,
      action.sourceId,
      action.actionId,
    );
    if (actionDefinition == null) {
      developer.log(
        'No action definition found for ${action.sourceType}:${action.sourceId}:${action.actionId}',
        name: 'IntentDispatcher',
      );
      return const DispatchResult(success: false);
    }

    final requestId = _generateRequestId();
    final arguments = Map<String, dynamic>.from(
      _buildArguments(actionDefinition, action.parameters),
    );
    arguments['org.oacp.extra.REQUEST_ID'] = requestId;

    try {
      final intent = AndroidIntent(
        action: actionDefinition.androidAction,
        package: actionDefinition.packageName,
        data: _buildData(actionDefinition, action.parameters),
        arguments: arguments,
      );

      debugPrint('IntentDispatcher: requestId=$requestId action=${actionDefinition.androidAction}');

      switch (actionDefinition.dispatchType) {
        case AssistantActionDispatchType.broadcast:
          await intent.sendBroadcast();
          break;
        case AssistantActionDispatchType.activity:
          await intent.launch();
          break;
      }
      return DispatchResult(success: true, requestId: requestId);
    } catch (e) {
      developer.log(
        'Error launching intent',
        name: 'IntentDispatcher',
        error: e,
      );
      return const DispatchResult(success: false);
    }
  }

  Map<String, dynamic> _buildArguments(
    AssistantAction action,
    Map<String, dynamic> parameters,
  ) {
    if (parameters.isEmpty) {
      return const {};
    }

    if (action.extrasMapping.isEmpty) {
      return Map<String, dynamic>.from(parameters);
    }

    final arguments = <String, dynamic>{};
    action.extrasMapping.forEach((parameterName, extraName) {
      if (parameters.containsKey(parameterName)) {
        arguments[extraName] = parameters[parameterName];
      }
    });
    return arguments;
  }

  String? _buildData(AssistantAction action, Map<String, dynamic> parameters) {
    if (action.dataTemplate != null) {
      var data = action.dataTemplate!;
      for (final entry in parameters.entries) {
        final encoded = Uri.encodeComponent(entry.value.toString());
        data = data.replaceAll('{${entry.key}}', encoded);
      }
      return data;
    }
    return action.data;
  }
}
