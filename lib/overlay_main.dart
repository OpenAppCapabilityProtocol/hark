import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:hark_platform/hark_platform.dart';

import 'screens/overlay_screen.dart';
import 'theme/hark_theme.dart';

/// Dart entrypoint for the overlay FlutterEngine.
///
/// Runs on its own engine (separate from the main app) and only renders the
/// compact overlay panel. The native side calls [HarkOverlayFlutterApi.onNewSession]
/// on each assist gesture to reset overlay state.
@pragma('vm:entry-point')
Future<void> overlayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: OverlayApp()));
}

/// Provider for the overlay session notifier. The overlay screen watches this
/// to know when a new assist session has started (and should reset state).
final overlaySessionProvider =
    NotifierProvider<OverlaySessionNotifier, String?>(
  OverlaySessionNotifier.new,
);

/// Tracks the current overlay session ID from native.
///
/// When the native side fires [HarkOverlayFlutterApi.onNewSession], we update
/// the session ID. Watchers can react to the change and reset their state.
class OverlaySessionNotifier extends Notifier<String?>
    implements HarkOverlayFlutterApi {
  @override
  String? build() {
    HarkOverlayFlutterApi.setUp(this);
    ref.onDispose(() => HarkOverlayFlutterApi.setUp(null));
    return null;
  }

  @override
  void onNewSession(String sessionId) {
    state = sessionId;
  }
}

/// Minimal app shell for the overlay — only renders [OverlayScreen].
class OverlayApp extends ConsumerWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly initialize so the FlutterApi handler is registered.
    ref.watch(overlaySessionProvider);

    final theme = buildHarkTheme();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      theme: theme.toApproximateMaterialTheme(),
      builder: (_, child) => FTheme(
        data: theme,
        child: child!,
      ),
      home: const OverlayScreen(),
    );
  }
}
