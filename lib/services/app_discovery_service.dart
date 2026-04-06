import 'package:flutter/services.dart';

import '../models/discovered_app.dart';

class AppDiscoveryService {
  static const MethodChannel _channel = MethodChannel(
    'com.oacp.hark/discovery',
  );

  Future<List<DiscoveredApp>> discoverApps() async {
    final rawApps = await _channel.invokeMethod<List<Object?>>(
      'discoverOacpApps',
    );
    if (rawApps == null) {
      return const [];
    }

    return rawApps
        .whereType<Map<Object?, Object?>>()
        .map(DiscoveredApp.fromMap)
        .toList();
  }
}
