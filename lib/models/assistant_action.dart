enum AssistantActionSourceType { oacp }

enum AssistantActionDispatchType { broadcast, activity }

class AssistantActionParameter {
  const AssistantActionParameter({
    required this.name,
    required this.type,
    required this.required,
    this.description,
    this.extractionHint,
    this.examples = const [],
    this.aliases = const {},
    this.enumValues = const [],
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.pattern,
    this.entityType,
    this.entityResolution,
    this.entityDisambiguationPrompt,
    this.entitySnapshot = const [],
  });

  final String name;
  final String type;
  final bool required;
  final String? description;
  final String? extractionHint;
  final List<dynamic> examples;
  final Map<String, List<String>> aliases;
  final List<String> enumValues;
  final dynamic defaultValue;
  final num? minimum;
  final num? maximum;
  final String? pattern;
  final String? entityType;
  final String? entityResolution;
  final String? entityDisambiguationPrompt;
  final List<Map<String, dynamic>> entitySnapshot;

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type,
      'required': required,
      if (description != null && description!.isNotEmpty)
        'description': description,
      if (extractionHint != null && extractionHint!.isNotEmpty)
        'extractionHint': extractionHint,
      if (examples.isNotEmpty) 'examples': examples,
      if (aliases.isNotEmpty) 'aliases': aliases,
      if (enumValues.isNotEmpty) 'enumValues': enumValues,
      if (defaultValue != null) 'default': defaultValue,
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
      if (pattern != null && pattern!.isNotEmpty) 'pattern': pattern,
      if (entityType != null) 'entityType': entityType,
      if (entityResolution != null) 'entityResolution': entityResolution,
      if (entityDisambiguationPrompt != null)
        'entityDisambiguationPrompt': entityDisambiguationPrompt,
      if (entitySnapshot.isNotEmpty) 'entitySnapshot': entitySnapshot,
    };
  }
}

class AssistantAction {
  const AssistantAction({
    required this.sourceType,
    required this.sourceId,
    required this.actionId,
    required this.displayName,
    required this.description,
    required this.confirmationMessage,
    this.confirmationPrompt,
    required this.domain,
    required this.appDomains,
    required this.appKeywords,
    required this.appAliases,
    required this.aliases,
    required this.examples,
    required this.keywords,
    required this.disambiguationHints,
    required this.dispatchType,
    required this.androidAction,
    required this.extrasMapping,
    required this.parameters,
    this.completionMode,
    this.resultTransportType,
    this.resultTransportAction,
    this.errorCodes = const [],
    this.supportsCancellation = false,
    this.cancelCapabilityId,
    this.packageName,
    this.data,
    this.dataTemplate,
  });

  final AssistantActionSourceType sourceType;
  final String sourceId;
  final String actionId;
  final String displayName;
  final String description;
  final String confirmationMessage;
  final String? confirmationPrompt;
  final String? domain;
  final List<String> appDomains;
  final List<String> appKeywords;
  final List<String> appAliases;
  final List<String> aliases;
  final List<String> examples;
  final List<String> keywords;
  final List<String> disambiguationHints;
  final AssistantActionDispatchType dispatchType;
  final String androidAction;
  final String? packageName;
  final String? data;
  final String? dataTemplate;
  final Map<String, String> extrasMapping;
  final List<AssistantActionParameter> parameters;
  final String? completionMode;
  final String? resultTransportType;
  final String? resultTransportAction;
  final List<String> errorCodes;
  final bool supportsCancellation;
  final String? cancelCapabilityId;

  Map<String, dynamic> toJson() {
    return {
      'sourceType': sourceType.name,
      'sourceId': sourceId,
      'actionId': actionId,
      'displayName': displayName,
      'description': description,
      'confirmationMessage': confirmationMessage,
      if (confirmationPrompt != null) 'confirmationPrompt': confirmationPrompt,
      if (domain != null) 'domain': domain,
      if (appDomains.isNotEmpty) 'appDomains': appDomains,
      if (appKeywords.isNotEmpty) 'appKeywords': appKeywords,
      if (appAliases.isNotEmpty) 'appAliases': appAliases,
      if (aliases.isNotEmpty) 'aliases': aliases,
      if (examples.isNotEmpty) 'examples': examples,
      if (keywords.isNotEmpty) 'keywords': keywords,
      if (disambiguationHints.isNotEmpty)
        'disambiguationHints': disambiguationHints,
      'dispatchType': dispatchType.name,
      'androidAction': androidAction,
      if (packageName != null) 'packageName': packageName,
      if (data != null) 'data': data,
      if (dataTemplate != null) 'dataTemplate': dataTemplate,
      'extrasMapping': extrasMapping,
      'parameters': parameters.map((parameter) => parameter.toJson()).toList(),
      if (completionMode != null) 'completionMode': completionMode,
      if (resultTransportType != null)
        'resultTransportType': resultTransportType,
      if (resultTransportAction != null)
        'resultTransportAction': resultTransportAction,
      if (errorCodes.isNotEmpty) 'errorCodes': errorCodes,
      if (supportsCancellation) 'supportsCancellation': supportsCancellation,
      if (cancelCapabilityId != null) 'cancelCapabilityId': cancelCapabilityId,
    };
  }
}
