import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import 'bench_types.dart';

/// Evaluates a loaded llamadart [LlamaEngine] on the embedding gold set.
///
/// Uses the classic cosine-similarity pattern: embed each fixture action's
/// "document" text once, embed each case's utterance as a "query", then
/// rank all fixtures by cosine score for each query. Metrics are computed
/// against the expected_top1 and expected_in_top3 fields in the gold set.
///
/// Returns an [EmbeddingMetrics] summarizing top-1 accuracy, top-3 recall,
/// disambiguation coverage, exact-match category performance, and a list
/// of per-case failure details suitable for a benchmark report.
class EmbeddingEvaluator {
  EmbeddingEvaluator({
    required this.engine,
    required this.goldSet,
    void Function(String)? log,
  }) : _log = log ?? ((_) {});

  final LlamaEngine engine;
  final EmbeddingGoldSet goldSet;
  final void Function(String) _log;

  /// Runs the full embedding evaluation. Assumes the model is already
  /// loaded. The caller is responsible for loading and disposing.
  Future<EmbeddingMetrics> run() async {
    _log('Embedding eval: building fixture vectors '
        '(${goldSet.fixtures.length} actions)');
    final fixtureVectors = <String, List<double>>{};
    for (final fixture in goldSet.fixtures) {
      final doc = fixture.buildDocumentText();
      final vec = await engine.embed(doc, normalize: true);
      fixtureVectors[fixture.key] = vec;
    }

    _log('Embedding eval: running ${goldSet.cases.length} cases');

    var top1Total = 0;
    var top1Correct = 0;
    var top3Total = 0;
    var top3Hits = 0;
    var exactMatchTop1Correct = 0;
    var exactMatchTotal = 0;
    var disambiguationCovered = 0;
    var disambiguationTotal = 0;
    var sumTop1Score = 0.0;
    final failureDetails = <String>[];

    for (final c in goldSet.cases) {
      final queryVec = await engine.embed(c.utterance, normalize: true);
      final scored = <_ScoredAction>[];
      for (final entry in fixtureVectors.entries) {
        final score = _cosine(queryVec, entry.value);
        scored.add(_ScoredAction(key: entry.key, score: score));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      final top1Key = scored.first.key;
      final top3Keys = scored.take(3).map((e) => e.key).toSet();
      sumTop1Score += scored.first.score;

      // Scoring by category:
      // - exact_match + paraphrase + cross_app cases that specify
      //   expected_top1: top1 must match
      // - disambiguation + cross_app cases that specify expected_in_top3:
      //   every listed candidate must be in the top 3
      final isExactCategory = c.category == 'exact_match';
      if (isExactCategory) exactMatchTotal += 1;

      var caseTop1Correct = false;
      if (c.expectedTop1 != null) {
        top1Total += 1;
        top3Total += 1;
        caseTop1Correct = top1Key == c.expectedTop1!.key;
        if (caseTop1Correct) {
          top1Correct += 1;
          if (isExactCategory) exactMatchTop1Correct += 1;
        } else {
          failureDetails.add(
            '${c.id} [${c.category}] "${c.utterance}" '
            '→ got $top1Key, expected ${c.expectedTop1!.key}',
          );
        }
        // Top-3 recall is satisfied if the expected top1 is in top3.
        if (top3Keys.contains(c.expectedTop1!.key)) {
          top3Hits += 1;
        }
      }

      if (c.expectedInTop3.isNotEmpty) {
        disambiguationTotal += 1;
        if (c.expectedTop1 == null) top3Total += 1;
        final allPresent =
            c.expectedInTop3.every((e) => top3Keys.contains(e.key));
        if (allPresent) {
          disambiguationCovered += 1;
          if (c.expectedTop1 == null) top3Hits += 1;
        } else {
          final missing = c.expectedInTop3
              .where((e) => !top3Keys.contains(e.key))
              .map((e) => e.key)
              .join(', ');
          failureDetails.add(
            '${c.id} [${c.category}] "${c.utterance}" '
            '→ top3=${top3Keys.take(3).join("/")}, missing=$missing',
          );
        }
      }
    }

    final avgTop1 = goldSet.cases.isEmpty
        ? 0.0
        : sumTop1Score / goldSet.cases.length;

    return EmbeddingMetrics(
      totalCases: goldSet.cases.length,
      top1Total: top1Total,
      top1Correct: top1Correct,
      top3Total: top3Total,
      top3Hits: top3Hits,
      exactMatchTop1Correct: exactMatchTop1Correct,
      exactMatchTotal: exactMatchTotal,
      disambiguationCovered: disambiguationCovered,
      disambiguationTotal: disambiguationTotal,
      avgTop1Score: avgTop1,
      failureDetails: failureDetails,
    );
  }

  static double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vector length mismatch: ${a.length} vs ${b.length}');
    }
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }
}

class _ScoredAction {
  const _ScoredAction({required this.key, required this.score});
  final String key;
  final double score;
}
