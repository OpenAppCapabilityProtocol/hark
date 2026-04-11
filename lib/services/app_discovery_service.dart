import 'package:hark_platform/hark_platform.dart';

import '../models/discovered_app.dart';

class AppDiscoveryService {
  final _api = HarkCommonApi();

  Future<List<DiscoveredApp>> discoverApps() async {
    final results = await _api.discoverOacpApps();
    return results.map(DiscoveredApp.fromMessage).toList();
  }
}
