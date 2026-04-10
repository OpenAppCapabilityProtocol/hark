import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import 'overlay_main.dart' as overlay;
import 'router/hark_router.dart';
import 'theme/hark_theme.dart';

// Force the compiler to include overlay_main.dart in the kernel snapshot.
// Without this, the secondary Dart entrypoint can't be resolved at runtime.
@pragma('vm:entry-point')
final _overlayEntry = overlay.overlayMain;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: HarkApp()));
}

class HarkApp extends ConsumerWidget {
  const HarkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = buildHarkTheme();
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'Hark',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      theme: theme.toApproximateMaterialTheme(),
      builder: (_, child) => FTheme(
        data: theme,
        child: FToaster(child: child!),
      ),
      routerConfig: router,
    );
  }
}
