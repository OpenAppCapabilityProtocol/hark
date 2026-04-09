import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'bench_types.dart';

/// Loads the three bundled JSON assets used by the quant benchmark:
/// embedding gold set, slot-filling gold set, and quant matrix config.
class GoldLoader {
  const GoldLoader();

  Future<EmbeddingGoldSet> loadEmbeddingGold() async {
    final raw = await rootBundle.loadString('assets/gold/embedding_gold.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return EmbeddingGoldSet.fromJson(json);
  }

  Future<SlotFillGoldSet> loadSlotFillGold() async {
    final raw = await rootBundle.loadString(
      'assets/gold/slot_filling_gold.json',
    );
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return SlotFillGoldSet.fromJson(json);
  }

  Future<QuantMatrixConfig> loadQuantMatrix() async {
    final raw = await rootBundle.loadString(
      'assets/configs/quant_matrix.json',
    );
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return QuantMatrixConfig.fromJson(json);
  }
}
