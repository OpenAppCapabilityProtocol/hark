import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk cache for OACP action document embeddings.
///
/// Keyed by `(model_id, action_key, text_hash)` so the cache auto-invalidates
/// when the embedding model changes, the action set changes, or the action's
/// metadata changes (which alters the semantic text fed to the embedder).
///
/// File format: JSON at `<app_docs>/embedding_cache.json`. Typical size ~2 MB
/// for 49 actions × 768-dim vectors. Loaded once at startup.
class EmbeddingCacheStore {
  EmbeddingCacheStore({required this.modelId});

  final String modelId;
  String? _cachePath;

  Future<String> _getCachePath() async {
    if (_cachePath != null) return _cachePath!;
    final appDir = await getApplicationDocumentsDirectory();
    _cachePath = '${appDir.path}/embedding_cache.json';
    return _cachePath!;
  }

  /// Load cached embeddings from disk. Returns a map of
  /// `action_key → (text_hash, embedding)`. Returns an empty map if the
  /// cache file doesn't exist or is stale (different model_id).
  Future<Map<String, CachedEmbedding>> load() async {
    final path = await _getCachePath();
    final file = File(path);
    if (!await file.exists()) return {};

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      // Model ID mismatch → entire cache invalid (different model produces
      // different vectors).
      if (json['model_id'] != modelId) {
        debugPrint('EmbeddingCacheStore: model_id mismatch, invalidating '
            'cache (cached=${json['model_id']}, current=$modelId)');
        return {};
      }

      final entries = json['entries'] as Map<String, dynamic>? ?? {};
      final result = <String, CachedEmbedding>{};
      for (final entry in entries.entries) {
        final value = entry.value as Map<String, dynamic>;
        final textHash = value['text_hash'] as String?;
        final embeddingList = value['embedding'] as List<dynamic>?;
        if (textHash == null || embeddingList == null) continue;
        result[entry.key] = CachedEmbedding(
          textHash: textHash,
          embedding: embeddingList.cast<num>().map((n) => n.toDouble()).toList(),
        );
      }
      debugPrint('EmbeddingCacheStore: loaded ${result.length} cached '
          'embeddings from disk');
      return result;
    } catch (error, stackTrace) {
      debugPrint('EmbeddingCacheStore: failed to load cache: $error');
      debugPrint('$stackTrace');
      return {};
    }
  }

  /// Save the current in-memory cache to disk. Overwrites the entire file
  /// atomically via a `.tmp` rename.
  Future<void> save(Map<String, CachedEmbedding> cache) async {
    final path = await _getCachePath();
    final tmpPath = '$path.tmp';
    final json = {
      'model_id': modelId,
      'created': DateTime.now().toIso8601String(),
      'entry_count': cache.length,
      'entries': {
        for (final entry in cache.entries)
          entry.key: {
            'text_hash': entry.value.textHash,
            'embedding': entry.value.embedding,
          },
      },
    };
    try {
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsString(
        const JsonEncoder.withIndent(null).convert(json),
      );
      await tmpFile.rename(path);
      debugPrint('EmbeddingCacheStore: saved ${cache.length} embeddings '
          'to disk (${File(path).lengthSync()} bytes)');
    } catch (error) {
      debugPrint('EmbeddingCacheStore: failed to save cache: $error');
    }
  }

  /// Compute a content hash for the semantic text of an action. Used as the
  /// invalidation key — if the action's metadata changes (display name,
  /// description, aliases, examples, keywords, parameters), the hash changes
  /// and the embedding is recomputed.
  static String hashText(String text) {
    return sha256.convert(utf8.encode(text)).toString().substring(0, 16);
  }
}

class CachedEmbedding {
  const CachedEmbedding({required this.textHash, required this.embedding});

  final String textHash;
  final List<double> embedding;
}
