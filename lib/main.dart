import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import 'router/hark_router.dart';
import 'theme/hark_theme.dart';

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
