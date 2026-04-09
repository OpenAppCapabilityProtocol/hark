/// Data types used by the quant_bench harness.
///
/// Mirrors the JSON shapes in `assets/gold/*.json` and
/// `assets/configs/quant_matrix.json`, plus internal result types that flow
/// from the evals to the runner to the UI.
///
/// See `docs/plans/llamadart-migration.md` slice 0 for the design rationale.
library;

// ----------------------------------------------------------------------------
// Embedding gold set

class ActionRef {
  const ActionRef({required this.source, required this.action});

  final String source;
  final String action;

  String get key => '$source.$action';

  factory ActionRef.fromJson(Map<String, dynamic> json) => ActionRef(
        source: json['source'] as String,
        action: json['action'] as String,
      );

  Map<String, dynamic> toJson() => {'source': source, 'action': action};
}

class EmbeddingFixtureAction {
  const EmbeddingFixtureAction({
    required this.source,
    required this.action,
    required this.aliases,
    required this.description,
  });

  final String source;
  final String action;
  final List<String> aliases;
  final String description;

  String get key => '$source.$action';

  /// The "document" text we embed for this action. Combines the aliases
  /// with the description into a single string roughly mirroring what
  /// Hark's real capability registry does — see `nlu_command_resolver.dart`
  /// `_actionDocumentText`.
  String buildDocumentText() {
    final parts = <String>[description];
    if (aliases.isNotEmpty) {
      parts.add('Aliases: ${aliases.join(', ')}');
    }
    return parts.join('\n');
  }

  factory EmbeddingFixtureAction.fromJson(Map<String, dynamic> json) =>
      EmbeddingFixtureAction(
        source: json['source'] as String,
        action: json['action'] as String,
        aliases: (json['aliases'] as List<dynamic>).cast<String>(),
        description: json['description'] as String,
      );
}

class EmbeddingCase {
  const EmbeddingCase({
    required this.id,
    required this.category,
    required this.utterance,
    this.expectedTop1,
    this.expectedInTop3 = const [],
    this.notes,
  });

  final String id;
  final String category;
  final String utterance;
  final ActionRef? expectedTop1;
  final List<ActionRef> expectedInTop3;
  final String? notes;

  factory EmbeddingCase.fromJson(Map<String, dynamic> json) {
    final top1 = json['expected_top1'] as Map<String, dynamic>?;
    final top3 = json['expected_in_top3'] as List<dynamic>?;
    return EmbeddingCase(
      id: json['id'] as String,
      category: json['category'] as String,
      utterance: json['utterance'] as String,
      expectedTop1: top1 == null ? null : ActionRef.fromJson(top1),
      expectedInTop3: top3 == null
          ? const []
          : top3
              .map((e) => ActionRef.fromJson(e as Map<String, dynamic>))
              .toList(growable: false),
      notes: json['notes'] as String?,
    );
  }
}

class EmbeddingGoldSet {
  const EmbeddingGoldSet({
    required this.fixtures,
    required this.cases,
  });

  final List<EmbeddingFixtureAction> fixtures;
  final List<EmbeddingCase> cases;

  factory EmbeddingGoldSet.fromJson(Map<String, dynamic> json) {
    final fixturesMap = json['fixtures'] as Map<String, dynamic>;
    final actionsRaw =
        (fixturesMap['actions'] as List<dynamic>).cast<Map<String, dynamic>>();
    final casesRaw =
        (json['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
    return EmbeddingGoldSet(
      fixtures: actionsRaw
          .map(EmbeddingFixtureAction.fromJson)
          .toList(growable: false),
      cases: casesRaw.map(EmbeddingCase.fromJson).toList(growable: false),
    );
  }
}

// ----------------------------------------------------------------------------
// Slot filling gold set

enum SlotParamType { string, integer, number, boolean, enumType, other }

SlotParamType _parseSlotParamType(String raw) {
  switch (raw) {
    case 'string':
      return SlotParamType.string;
    case 'integer':
      return SlotParamType.integer;
    case 'number':
    case 'double':
      return SlotParamType.number;
    case 'boolean':
      return SlotParamType.boolean;
    case 'enum':
      return SlotParamType.enumType;
    default:
      return SlotParamType.other;
  }
}

class SlotFillParamDef {
  const SlotFillParamDef({
    required this.name,
    required this.type,
    required this.required,
    this.description,
    this.examples = const [],
    this.minimum,
    this.maximum,
  });

  final String name;
  final SlotParamType type;
  final bool required;
  final String? description;
  final List<String> examples;
  final num? minimum;
  final num? maximum;

  String get typeString => switch (type) {
        SlotParamType.string => 'string',
        SlotParamType.integer => 'integer',
        SlotParamType.number => 'number',
        SlotParamType.boolean => 'boolean',
        SlotParamType.enumType => 'enum',
        SlotParamType.other => 'other',
      };

  factory SlotFillParamDef.fromJson(Map<String, dynamic> json) =>
      SlotFillParamDef(
        name: json['name'] as String,
        type: _parseSlotParamType(json['type'] as String? ?? 'string'),
        required: json['required'] as bool? ?? false,
        description: json['description'] as String?,
        examples: (json['examples'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        minimum: json['minimum'] as num?,
        maximum: json['maximum'] as num?,
      );
}

class SlotFillActionDef {
  const SlotFillActionDef({
    required this.actionKey,
    required this.description,
    required this.parameters,
  });

  final String actionKey;
  final String description;
  final List<SlotFillParamDef> parameters;

  factory SlotFillActionDef.fromJson(
    String actionKey,
    Map<String, dynamic> json,
  ) {
    final paramsRaw =
        (json['parameters'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>();
    return SlotFillActionDef(
      actionKey: actionKey,
      description: json['description'] as String? ?? '',
      parameters: paramsRaw
          .map(SlotFillParamDef.fromJson)
          .toList(growable: false),
    );
  }
}

class SlotFillCase {
  const SlotFillCase({
    required this.id,
    required this.category,
    required this.utterance,
    required this.actionKey,
    required this.expected,
  });

  final String id;
  final String category;
  final String utterance;
  final String actionKey;
  final Map<String, dynamic> expected;

  factory SlotFillCase.fromJson(Map<String, dynamic> json) => SlotFillCase(
        id: json['id'] as String,
        category: json['category'] as String,
        utterance: json['utterance'] as String,
        actionKey: json['action_key'] as String,
        expected:
            (json['expected'] as Map<String, dynamic>? ?? const <String, dynamic>{})
                .cast<String, dynamic>(),
      );
}

class SlotFillGoldSet {
  const SlotFillGoldSet({
    required this.fixtures,
    required this.cases,
  });

  final Map<String, SlotFillActionDef> fixtures;
  final List<SlotFillCase> cases;

  factory SlotFillGoldSet.fromJson(Map<String, dynamic> json) {
    final fixturesRaw = (json['fixtures'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(
        k,
        SlotFillActionDef.fromJson(k, v as Map<String, dynamic>),
      ),
    );
    final casesRaw =
        (json['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
    return SlotFillGoldSet(
      fixtures: fixturesRaw,
      cases: casesRaw.map(SlotFillCase.fromJson).toList(growable: false),
    );
  }
}

// ----------------------------------------------------------------------------
// Quant matrix config

enum ModelKind { embedding, generation }

class EmbeddingQualityGate {
  const EmbeddingQualityGate({
    required this.top1AccuracyMin,
    required this.top3RecallMin,
    required this.disambiguationCoverageMin,
    required this.exactMatchTop1MustAllPass,
  });

  final double top1AccuracyMin;
  final double top3RecallMin;
  final double disambiguationCoverageMin;
  final bool exactMatchTop1MustAllPass;

  factory EmbeddingQualityGate.fromJson(Map<String, dynamic> json) =>
      EmbeddingQualityGate(
        top1AccuracyMin: (json['top1_accuracy_min'] as num).toDouble(),
        top3RecallMin: (json['top3_recall_min'] as num).toDouble(),
        disambiguationCoverageMin:
            (json['disambiguation_coverage_min'] as num).toDouble(),
        exactMatchTop1MustAllPass:
            json['exact_match_top1_must_all_pass'] as bool? ?? true,
      );
}

class SlotFillQualityGate {
  const SlotFillQualityGate({
    required this.jsonValidityMin,
    required this.exactMatchMin,
    required this.typeCorrectMin,
    required this.hallucinationMax,
    required this.requiredFieldsPopulatedMin,
  });

  final double jsonValidityMin;
  final double exactMatchMin;
  final double typeCorrectMin;
  final double hallucinationMax;
  final double requiredFieldsPopulatedMin;

  factory SlotFillQualityGate.fromJson(Map<String, dynamic> json) =>
      SlotFillQualityGate(
        jsonValidityMin: (json['json_validity_min'] as num).toDouble(),
        exactMatchMin: (json['exact_match_min'] as num).toDouble(),
        typeCorrectMin: (json['type_correct_min'] as num).toDouble(),
        hallucinationMax: (json['hallucination_max'] as num).toDouble(),
        requiredFieldsPopulatedMin:
            (json['required_fields_populated_min'] as num).toDouble(),
      );
}

class QuantConfig {
  const QuantConfig({
    required this.tag,
    required this.priority,
    required this.repo,
    required this.filenameCandidates,
    required this.fallbackRepos,
    required this.expectedSizeMb,
  });

  final String tag;
  final int priority;
  final String repo;
  final List<String> filenameCandidates;
  final List<String> fallbackRepos;
  final int expectedSizeMb;

  factory QuantConfig.fromJson(Map<String, dynamic> json) => QuantConfig(
        tag: json['tag'] as String,
        priority: json['priority'] as int,
        repo: json['repo'] as String,
        filenameCandidates: (json['filename_candidates'] as List<dynamic>)
            .cast<String>(),
        fallbackRepos: (json['fallback_repos'] as List<dynamic>? ?? const [])
            .cast<String>(),
        expectedSizeMb: json['expected_size_mb'] as int? ?? 0,
      );
}

class ModelConfig {
  const ModelConfig({
    required this.modelId,
    required this.kind,
    required this.displayName,
    required this.contextSize,
    required this.nEmbd,
    required this.poolingType,
    required this.embeddingGate,
    required this.slotFillGate,
    required this.quants,
  });

  final String modelId;
  final ModelKind kind;
  final String displayName;
  final int? contextSize;
  final int? nEmbd;
  final String? poolingType;
  final EmbeddingQualityGate? embeddingGate;
  final SlotFillQualityGate? slotFillGate;
  final List<QuantConfig> quants;

  factory ModelConfig.fromJson(String modelId, Map<String, dynamic> json) {
    final kind = switch (json['kind'] as String) {
      'embedding' => ModelKind.embedding,
      'generation' => ModelKind.generation,
      final other => throw FormatException('Unknown model kind: $other'),
    };
    final gateJson = (json['quality_gate'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    final quantsRaw =
        (json['quants'] as List<dynamic>).cast<Map<String, dynamic>>();
    final quants = quantsRaw.map(QuantConfig.fromJson).toList(growable: false)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return ModelConfig(
      modelId: modelId,
      kind: kind,
      displayName: json['display_name'] as String,
      contextSize: json['context_size'] as int?,
      nEmbd: json['n_embd'] as int?,
      poolingType: json['pooling_type'] as String?,
      embeddingGate:
          kind == ModelKind.embedding
              ? EmbeddingQualityGate.fromJson(gateJson)
              : null,
      slotFillGate: kind == ModelKind.generation
          ? SlotFillQualityGate.fromJson(gateJson)
          : null,
      quants: quants,
    );
  }
}

class QuantMatrixConfig {
  const QuantMatrixConfig({required this.models});

  final Map<String, ModelConfig> models;

  factory QuantMatrixConfig.fromJson(Map<String, dynamic> json) {
    final modelsRaw = (json['models'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, ModelConfig.fromJson(k, v as Map<String, dynamic>)),
    );
    return QuantMatrixConfig(models: modelsRaw);
  }
}

// ----------------------------------------------------------------------------
// Result types

class EmbeddingMetrics {
  const EmbeddingMetrics({
    required this.totalCases,
    required this.top1Total,
    required this.top1Correct,
    required this.top3Total,
    required this.top3Hits,
    required this.exactMatchTop1Correct,
    required this.exactMatchTotal,
    required this.disambiguationCovered,
    required this.disambiguationTotal,
    required this.avgTop1Score,
    required this.failureDetails,
  });

  /// Total cases in the gold set. Not used as a metric denominator
  /// any more — see [top1Total] and [top3Total] for the actual
  /// denominators.
  final int totalCases;

  /// Number of gold cases that specified an `expected_top1`. This is
  /// the correct denominator for top-1 accuracy — only the cases that
  /// asked a top-1 question are counted.
  final int top1Total;

  /// Number of top-1 cases where the predicted top action matched the
  /// expected one.
  final int top1Correct;

  /// Number of gold cases that had EITHER an expected_top1 or a
  /// non-empty expected_in_top3. Used as the top-3 recall denominator.
  final int top3Total;

  /// Number of cases where the expected top1 (or all expected_in_top3
  /// entries) were present in the actual top-3 predictions.
  final int top3Hits;
  final int exactMatchTop1Correct;
  final int exactMatchTotal;
  final int disambiguationCovered;
  final int disambiguationTotal;
  final double avgTop1Score;
  final List<String> failureDetails;

  double get top1Accuracy => top1Total == 0 ? 0 : top1Correct / top1Total;
  double get top3Recall => top3Total == 0 ? 0 : top3Hits / top3Total;
  double get disambiguationCoverage => disambiguationTotal == 0
      ? 1.0
      : disambiguationCovered / disambiguationTotal;
  bool get exactMatchAllPassed =>
      exactMatchTotal > 0 && exactMatchTop1Correct == exactMatchTotal;

  Map<String, dynamic> toJson() => {
        'total_cases': totalCases,
        'top1_total': top1Total,
        'top1_correct': top1Correct,
        'top1_accuracy': top1Accuracy,
        'top3_total': top3Total,
        'top3_hits': top3Hits,
        'top3_recall': top3Recall,
        'exact_match_top1_correct': exactMatchTop1Correct,
        'exact_match_total': exactMatchTotal,
        'exact_match_all_passed': exactMatchAllPassed,
        'disambiguation_covered': disambiguationCovered,
        'disambiguation_total': disambiguationTotal,
        'disambiguation_coverage': disambiguationCoverage,
        'avg_top1_score': avgTop1Score,
        'failure_details': failureDetails,
      };
}

class SlotFillMetrics {
  const SlotFillMetrics({
    required this.totalCases,
    required this.jsonValid,
    required this.exactMatch,
    required this.typeCorrect,
    required this.hallucinations,
    required this.requiredFieldsPopulated,
    required this.requiredFieldsTotal,
    required this.failureDetails,
  });

  final int totalCases;
  final int jsonValid;
  final int exactMatch;
  final int typeCorrect;
  final int hallucinations;
  final int requiredFieldsPopulated;
  final int requiredFieldsTotal;
  final List<String> failureDetails;

  double get jsonValidityRate => totalCases == 0 ? 0 : jsonValid / totalCases;
  double get exactMatchRate => totalCases == 0 ? 0 : exactMatch / totalCases;
  double get typeCorrectRate => totalCases == 0 ? 0 : typeCorrect / totalCases;
  double get hallucinationRate =>
      totalCases == 0 ? 0 : hallucinations / totalCases;
  double get requiredFieldsRate => requiredFieldsTotal == 0
      ? 1.0
      : requiredFieldsPopulated / requiredFieldsTotal;

  Map<String, dynamic> toJson() => {
        'total_cases': totalCases,
        'json_valid': jsonValid,
        'json_validity_rate': jsonValidityRate,
        'exact_match': exactMatch,
        'exact_match_rate': exactMatchRate,
        'type_correct': typeCorrect,
        'type_correct_rate': typeCorrectRate,
        'hallucinations': hallucinations,
        'hallucination_rate': hallucinationRate,
        'required_fields_populated': requiredFieldsPopulated,
        'required_fields_total': requiredFieldsTotal,
        'required_fields_rate': requiredFieldsRate,
        'failure_details': failureDetails,
      };
}

class PerfMetrics {
  const PerfMetrics({
    required this.coldLoadMs,
    required this.singleInferenceMs,
    required this.fileSizeBytes,
  });

  final int coldLoadMs;
  final int singleInferenceMs;
  final int fileSizeBytes;

  Map<String, dynamic> toJson() => {
        'cold_load_ms': coldLoadMs,
        'single_inference_ms': singleInferenceMs,
        'file_size_bytes': fileSizeBytes,
        'file_size_mb': (fileSizeBytes / (1024 * 1024)).toStringAsFixed(1),
      };
}

class QuantRunResult {
  const QuantRunResult({
    required this.modelId,
    required this.displayName,
    required this.quantTag,
    required this.modelPath,
    required this.kind,
    required this.embedding,
    required this.slotFill,
    required this.perf,
    required this.passedQualityGate,
    required this.notes,
    required this.error,
  });

  final String modelId;
  final String displayName;
  final String quantTag;
  final String modelPath;
  final ModelKind kind;
  final EmbeddingMetrics? embedding;
  final SlotFillMetrics? slotFill;
  final PerfMetrics? perf;
  final bool passedQualityGate;
  final List<String> notes;
  final String? error;

  Map<String, dynamic> toJson() => {
        'model_id': modelId,
        'display_name': displayName,
        'quant_tag': quantTag,
        'model_path': modelPath,
        'kind': kind.name,
        if (embedding != null) 'embedding': embedding!.toJson(),
        if (slotFill != null) 'slot_fill': slotFill!.toJson(),
        if (perf != null) 'perf': perf!.toJson(),
        'passed_quality_gate': passedQualityGate,
        if (notes.isNotEmpty) 'notes': notes,
        if (error != null) 'error': error,
      };
}
