// Smoke test: verify the gold set JSON assets parse cleanly.
//
// Does not exercise the llamadart runtime — that requires native
// binaries and actual GGUF files on disk. These tests only check the
// harness's data loading path.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quant_bench/bench/bench_types.dart';

Future<Map<String, dynamic>> _loadAsset(String path) async {
  final raw = await rootBundle.loadString(path);
  return jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('embedding gold set parses cleanly', () async {
    final json = await _loadAsset('assets/gold/embedding_gold.json');
    final gold = EmbeddingGoldSet.fromJson(json);
    expect(gold.fixtures.length, greaterThanOrEqualTo(20));
    expect(gold.cases.length, 20);

    // Every exact-match case must have an expected_top1.
    for (final c in gold.cases.where((c) => c.category == 'exact_match')) {
      expect(c.expectedTop1, isNotNull, reason: 'case ${c.id} missing top1');
    }

    // Every disambiguation case must have expected_in_top3 (at least 1).
    for (final c in gold.cases.where((c) => c.category == 'disambiguation')) {
      expect(c.expectedInTop3.isNotEmpty, isTrue,
          reason: 'case ${c.id} missing top3 candidates');
    }

    // Every referenced action key must exist in the fixtures.
    final fixtureKeys = gold.fixtures.map((f) => f.key).toSet();
    for (final c in gold.cases) {
      if (c.expectedTop1 != null) {
        expect(
          fixtureKeys.contains(c.expectedTop1!.key),
          isTrue,
          reason:
              'case ${c.id} references unknown action ${c.expectedTop1!.key}',
        );
      }
      for (final ref in c.expectedInTop3) {
        expect(
          fixtureKeys.contains(ref.key),
          isTrue,
          reason: 'case ${c.id} references unknown action ${ref.key}',
        );
      }
    }
  });

  test('slot-filling gold set parses cleanly', () async {
    final json = await _loadAsset('assets/gold/slot_filling_gold.json');
    final gold = SlotFillGoldSet.fromJson(json);
    expect(gold.fixtures.isNotEmpty, isTrue);
    expect(gold.cases.length, 15);

    // Every case must reference a fixture.
    for (final c in gold.cases) {
      expect(
        gold.fixtures.containsKey(c.actionKey),
        isTrue,
        reason: 'case ${c.id} references unknown action ${c.actionKey}',
      );
    }
  });

  test('quant matrix config parses cleanly', () async {
    final json = await _loadAsset('assets/configs/quant_matrix.json');
    final matrix = QuantMatrixConfig.fromJson(json);
    expect(matrix.models.length, 2);
    expect(matrix.models.containsKey('embeddinggemma'), isTrue);
    expect(matrix.models.containsKey('qwen3_06b'), isTrue);

    // Both models should have 3 quants, priority-sorted.
    for (final model in matrix.models.values) {
      expect(model.quants.length, 3);
      for (var i = 0; i < model.quants.length - 1; i++) {
        expect(
          model.quants[i].priority,
          lessThan(model.quants[i + 1].priority),
        );
      }
    }
  });
}
