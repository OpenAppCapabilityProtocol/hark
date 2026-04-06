class AgentManifest {
  final String oacpVersion;
  final String appId;
  final String displayName;
  final List<String> appDomains;
  final List<String> appKeywords;
  final List<String> appAliases;
  final List<EntityTypeDefinition> entityTypes;
  final List<EntityProviderDefinition> entityProviders;
  final List<Capability> capabilities;

  AgentManifest({
    required this.oacpVersion,
    required this.appId,
    required this.displayName,
    required this.appDomains,
    required this.appKeywords,
    required this.appAliases,
    required this.entityTypes,
    required this.entityProviders,
    required this.capabilities,
  });

  factory AgentManifest.fromJson(Map<String, dynamic> json) {
    return AgentManifest(
      oacpVersion: json['oacpVersion'] as String,
      appId: json['appId'] as String,
      displayName: json['displayName'] as String,
      appDomains: _stringList(json['appDomains']),
      appKeywords: _stringList(json['appKeywords']),
      appAliases: _stringList(json['appAliases']),
      entityTypes:
          (json['entityTypes'] as List?)
              ?.map(
                (e) => EntityTypeDefinition.fromJson(e as Map<String, dynamic>),
              )
              .toList(growable: false) ??
          const [],
      entityProviders:
          (json['entityProviders'] as List?)
              ?.map(
                (e) => EntityProviderDefinition.fromJson(
                  e as Map<String, dynamic>,
                ),
              )
              .toList(growable: false) ??
          const [],
      capabilities: (json['capabilities'] as List)
          .map((e) => Capability.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'oacpVersion': oacpVersion,
    'appId': appId,
    'displayName': displayName,
    if (appDomains.isNotEmpty) 'appDomains': appDomains,
    if (appKeywords.isNotEmpty) 'appKeywords': appKeywords,
    if (appAliases.isNotEmpty) 'appAliases': appAliases,
    if (entityTypes.isNotEmpty)
      'entityTypes': entityTypes.map((e) => e.toJson()).toList(),
    if (entityProviders.isNotEmpty)
      'entityProviders': entityProviders.map((e) => e.toJson()).toList(),
    'capabilities': capabilities.map((e) => e.toJson()).toList(),
  };
}

class Capability {
  final String id;
  final String description;
  final String? domain;
  final List<String> aliases;
  final List<String> examples;
  final List<String> keywords;
  final List<String> disambiguationHints;
  final List<Parameter> parameters;
  final Map<String, dynamic>? parametersSchema;
  final String confirmation;
  final String? confirmationMessage;
  final String? executionMessage;
  final String visibility;
  final String? completionMode;
  final String? sensitivity;
  final String? sideEffects;
  final bool? idempotent;
  final bool requiresUnlock;
  final Map<String, dynamic>? resultSchema;
  final List<String> errorCodes;
  final ResultTransport? resultTransport;
  final bool supportsCancellation;
  final String? cancelCapabilityId;
  final InvokeConfig invoke;

  Capability({
    required this.id,
    required this.description,
    this.domain,
    required this.aliases,
    required this.examples,
    required this.keywords,
    required this.disambiguationHints,
    required this.parameters,
    this.parametersSchema,
    required this.confirmation,
    this.confirmationMessage,
    this.executionMessage,
    required this.visibility,
    this.completionMode,
    this.sensitivity,
    this.sideEffects,
    this.idempotent,
    this.requiresUnlock = false,
    this.resultSchema,
    this.errorCodes = const [],
    this.resultTransport,
    this.supportsCancellation = false,
    this.cancelCapabilityId,
    required this.invoke,
  });

  factory Capability.fromJson(Map<String, dynamic> json) {
    final parametersSchema = json['parametersSchema'] as Map<String, dynamic>?;
    final parameters = Parameter.mergeLegacyAndSchema(
      (json['parameters'] as List?)
              ?.map((e) => Parameter.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      parametersSchema,
    );

    return Capability(
      id: json['id'] as String,
      description: json['description'] as String,
      domain: json['domain'] as String?,
      aliases: _stringList(json['aliases']),
      examples: _stringList(json['examples']),
      keywords: _stringList(json['keywords']),
      disambiguationHints: _stringList(json['disambiguationHints']),
      parameters: parameters,
      parametersSchema: parametersSchema,
      confirmation: json['confirmation'] as String,
      confirmationMessage: json['confirmationMessage'] as String?,
      executionMessage: json['executionMessage'] as String?,
      visibility: json['visibility'] as String,
      completionMode: json['completionMode'] as String?,
      sensitivity: json['sensitivity'] as String?,
      sideEffects: json['sideEffects'] as String?,
      idempotent: json['idempotent'] as bool?,
      requiresUnlock: json['requiresUnlock'] as bool? ?? false,
      resultSchema: json['resultSchema'] as Map<String, dynamic>?,
      errorCodes: _stringList(json['errorCodes']),
      resultTransport: json['resultTransport'] is Map<String, dynamic>
          ? ResultTransport.fromJson(
              json['resultTransport'] as Map<String, dynamic>,
            )
          : null,
      supportsCancellation: json['supportsCancellation'] as bool? ?? false,
      cancelCapabilityId: json['cancelCapabilityId'] as String?,
      invoke: InvokeConfig.fromJson(json['invoke'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    if (domain != null) 'domain': domain,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (examples.isNotEmpty) 'examples': examples,
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (disambiguationHints.isNotEmpty)
      'disambiguationHints': disambiguationHints,
    'parameters': parameters.map((e) => e.toJson()).toList(),
    if (parametersSchema != null) 'parametersSchema': parametersSchema,
    'confirmation': confirmation,
    if (confirmationMessage != null) 'confirmationMessage': confirmationMessage,
    if (executionMessage != null) 'executionMessage': executionMessage,
    'visibility': visibility,
    if (completionMode != null) 'completionMode': completionMode,
    if (sensitivity != null) 'sensitivity': sensitivity,
    if (sideEffects != null) 'sideEffects': sideEffects,
    if (idempotent != null) 'idempotent': idempotent,
    if (requiresUnlock) 'requiresUnlock': requiresUnlock,
    if (resultSchema != null) 'resultSchema': resultSchema,
    if (errorCodes.isNotEmpty) 'errorCodes': errorCodes,
    if (resultTransport != null) 'resultTransport': resultTransport!.toJson(),
    if (supportsCancellation) 'supportsCancellation': supportsCancellation,
    if (cancelCapabilityId != null) 'cancelCapabilityId': cancelCapabilityId,
    'invoke': invoke.toJson(),
  };
}

class Parameter {
  final String name;
  final String type;
  final bool required;
  final String? description;
  final String? extractionHint;
  final List<dynamic> examples;
  final Map<String, List<String>> aliases;
  final List<String> enumValues;
  final String? prompt;
  final dynamic defaultValue;
  final num? minimum;
  final num? maximum;
  final String? pattern;
  final EntityRefDefinition? entityRef;
  final List<EntityRecord> entitySnapshot;

  Parameter({
    required this.name,
    required this.type,
    required this.required,
    this.description,
    this.extractionHint,
    this.examples = const [],
    this.aliases = const {},
    this.enumValues = const [],
    this.prompt,
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.pattern,
    this.entityRef,
    this.entitySnapshot = const [],
  });

  factory Parameter.fromJson(Map<String, dynamic> json) {
    return Parameter(
      name: json['name'] as String,
      type: json['type'] as String,
      required: json['required'] as bool,
      description: json['description'] as String?,
      extractionHint: json['extractionHint'] as String?,
      examples: (json['examples'] as List?)?.toList() ?? const [],
      aliases: _stringListMap(json['aliases']),
      enumValues: _stringList(json['enum']),
      prompt: json['prompt'] as String?,
      defaultValue: json['default'],
      minimum: json['minimum'] as num?,
      maximum: json['maximum'] as num?,
      pattern: json['pattern'] as String?,
      entityRef: json['entityRef'] is Map<String, dynamic>
          ? EntityRefDefinition.fromJson(
              json['entityRef'] as Map<String, dynamic>,
            )
          : null,
      entitySnapshot:
          (json['entitySnapshot'] as List?)
              ?.map((e) => EntityRecord.fromJson(e as Map<String, dynamic>))
              .toList(growable: false) ??
          const [],
    );
  }

  factory Parameter.fromSchemaProperty(
    String name,
    Map<String, dynamic> schema,
    bool required,
  ) {
    final schemaType = schema['type'] as String? ?? 'string';
    return Parameter(
      name: name,
      type: schemaType == 'number' ? 'integer' : schemaType,
      required: required,
      description: schema['description'] as String?,
      extractionHint: schema['extractionHint'] as String?,
      examples: (schema['examples'] as List?)?.toList() ?? const [],
      aliases: _stringListMap(schema['aliases'] ?? schema['x-oacp-aliases']),
      enumValues: _stringList(schema['enum']),
      prompt: schema['prompt'] as String?,
      defaultValue: schema['default'],
      minimum: schema['minimum'] as num?,
      maximum: schema['maximum'] as num?,
      pattern: schema['pattern'] as String?,
      entityRef: schema['entityRef'] is Map<String, dynamic>
          ? EntityRefDefinition.fromJson(
              schema['entityRef'] as Map<String, dynamic>,
            )
          : null,
      entitySnapshot:
          (schema['entitySnapshot'] as List?)
              ?.map((e) => EntityRecord.fromJson(e as Map<String, dynamic>))
              .toList(growable: false) ??
          const [],
    );
  }

  static List<Parameter> mergeLegacyAndSchema(
    List<Parameter> legacyParameters,
    Map<String, dynamic>? parametersSchema,
  ) {
    if (parametersSchema == null) {
      return legacyParameters;
    }

    final schemaProperties =
        parametersSchema['properties'] as Map<String, dynamic>? ?? const {};
    final requiredNames = Set<String>.from(
      (parametersSchema['required'] as List?)?.cast<String>() ?? const [],
    );

    final merged = <String, Parameter>{};

    for (final parameter in legacyParameters) {
      final schemaProperty =
          schemaProperties[parameter.name] as Map<String, dynamic>?;
      if (schemaProperty == null) {
        merged[parameter.name] = parameter;
        continue;
      }

      final schemaParameter = Parameter.fromSchemaProperty(
        parameter.name,
        schemaProperty,
        requiredNames.contains(parameter.name) || parameter.required,
      );

      merged[parameter.name] = Parameter(
        name: parameter.name,
        type: parameter.type,
        required: parameter.required || schemaParameter.required,
        description: parameter.description ?? schemaParameter.description,
        extractionHint:
            parameter.extractionHint ?? schemaParameter.extractionHint,
        examples: parameter.examples.isNotEmpty
            ? parameter.examples
            : schemaParameter.examples,
        aliases: parameter.aliases.isNotEmpty
            ? parameter.aliases
            : schemaParameter.aliases,
        enumValues: parameter.enumValues.isNotEmpty
            ? parameter.enumValues
            : schemaParameter.enumValues,
        prompt: parameter.prompt ?? schemaParameter.prompt,
        defaultValue: parameter.defaultValue ?? schemaParameter.defaultValue,
        minimum: parameter.minimum ?? schemaParameter.minimum,
        maximum: parameter.maximum ?? schemaParameter.maximum,
        pattern: parameter.pattern ?? schemaParameter.pattern,
        entityRef: parameter.entityRef ?? schemaParameter.entityRef,
        entitySnapshot: parameter.entitySnapshot.isNotEmpty
            ? parameter.entitySnapshot
            : schemaParameter.entitySnapshot,
      );
    }

    for (final entry in schemaProperties.entries) {
      if (merged.containsKey(entry.key) ||
          entry.value is! Map<String, dynamic>) {
        continue;
      }
      merged[entry.key] = Parameter.fromSchemaProperty(
        entry.key,
        entry.value as Map<String, dynamic>,
        requiredNames.contains(entry.key),
      );
    }

    return merged.values.toList(growable: false);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'required': required,
    if (description != null) 'description': description,
    if (extractionHint != null) 'extractionHint': extractionHint,
    if (examples.isNotEmpty) 'examples': examples,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (enumValues.isNotEmpty) 'enum': enumValues,
    if (prompt != null) 'prompt': prompt,
    if (defaultValue != null) 'default': defaultValue,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (pattern != null) 'pattern': pattern,
    if (entityRef != null) 'entityRef': entityRef!.toJson(),
    if (entitySnapshot.isNotEmpty)
      'entitySnapshot': entitySnapshot.map((e) => e.toJson()).toList(),
  };
}

class EntityTypeDefinition {
  final String id;
  final String displayName;
  final String? description;

  const EntityTypeDefinition({
    required this.id,
    required this.displayName,
    this.description,
  });

  factory EntityTypeDefinition.fromJson(Map<String, dynamic> json) {
    return EntityTypeDefinition(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    if (description != null) 'description': description,
  };
}

class EntityProviderDefinition {
  final String id;
  final String entityType;
  final String transport;
  final String? uri;

  const EntityProviderDefinition({
    required this.id,
    required this.entityType,
    required this.transport,
    this.uri,
  });

  factory EntityProviderDefinition.fromJson(Map<String, dynamic> json) {
    return EntityProviderDefinition(
      id: json['id'] as String,
      entityType: json['entityType'] as String,
      transport: json['transport'] as String,
      uri: json['uri'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'entityType': entityType,
    'transport': transport,
    if (uri != null) 'uri': uri,
  };
}

class EntityRefDefinition {
  final String entityType;
  final String resolution;
  final String? entityDisambiguationPrompt;

  const EntityRefDefinition({
    required this.entityType,
    required this.resolution,
    this.entityDisambiguationPrompt,
  });

  factory EntityRefDefinition.fromJson(Map<String, dynamic> json) {
    return EntityRefDefinition(
      entityType: json['entityType'] as String,
      resolution: json['resolution'] as String,
      entityDisambiguationPrompt: json['entityDisambiguationPrompt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'entityType': entityType,
    'resolution': resolution,
    if (entityDisambiguationPrompt != null)
      'entityDisambiguationPrompt': entityDisambiguationPrompt,
  };
}

class EntityRecord {
  final String id;
  final String displayName;
  final List<String> aliases;
  final String? description;
  final List<String> keywords;
  final Map<String, dynamic>? metadata;

  const EntityRecord({
    required this.id,
    required this.displayName,
    this.aliases = const [],
    this.description,
    this.keywords = const [],
    this.metadata,
  });

  factory EntityRecord.fromJson(Map<String, dynamic> json) {
    return EntityRecord(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      aliases: _stringList(json['aliases']),
      description: json['description'] as String?,
      keywords: _stringList(json['keywords']),
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (description != null) 'description': description,
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (metadata != null) 'metadata': metadata,
  };
}

class InvokeConfig {
  final AndroidInvoke android;

  InvokeConfig({required this.android});

  factory InvokeConfig.fromJson(Map<String, dynamic> json) {
    return InvokeConfig(
      android: AndroidInvoke.fromJson(json['android'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {'android': android.toJson()};
}

class ResultTransport {
  final AndroidResultTransport android;

  const ResultTransport({required this.android});

  factory ResultTransport.fromJson(Map<String, dynamic> json) {
    return ResultTransport(
      android: AndroidResultTransport.fromJson(
        json['android'] as Map<String, dynamic>,
      ),
    );
  }

  Map<String, dynamic> toJson() => {'android': android.toJson()};
}

class AndroidResultTransport {
  final String type;
  final String? action;

  const AndroidResultTransport({required this.type, this.action});

  factory AndroidResultTransport.fromJson(Map<String, dynamic> json) {
    return AndroidResultTransport(
      type: json['type'] as String,
      action: json['action'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (action != null) 'action': action,
  };
}

class AndroidInvoke {
  final String type;
  final String action;
  final Map<String, String>? extrasMapping;

  AndroidInvoke({required this.type, required this.action, this.extrasMapping});

  factory AndroidInvoke.fromJson(Map<String, dynamic> json) {
    return AndroidInvoke(
      type: json['type'] as String,
      action: json['action'] as String,
      extrasMapping: (json['extrasMapping'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v as String),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'action': action,
    if (extrasMapping != null) 'extrasMapping': extrasMapping,
  };
}

List<String> _stringList(dynamic value) {
  return (value as List?)?.whereType<String>().toList(growable: false) ??
      const [];
}

Map<String, List<String>> _stringListMap(dynamic value) {
  final map = value as Map<String, dynamic>?;
  if (map == null) {
    return const {};
  }

  return {for (final entry in map.entries) entry.key: _stringList(entry.value)};
}
