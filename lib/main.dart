import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import 'theme/hark_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: HarkApp()));
}

class HarkApp extends StatelessWidget {
  const HarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = buildHarkTheme();
    return MaterialApp(
      title: 'Hark',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      theme: theme.toApproximateMaterialTheme(),
      builder: (_, child) => FTheme(
        data: theme,
        child: FToaster(child: child!),
      ),
      home: const _BootstrapHome(),
    );
  }
}

/// Placeholder home used while slice 1 (bootstrap) is the only landed work.
///
/// Replaced by `SplashGate` in slice 3 and `ChatScreen` from slice 4 onward.
class _BootstrapHome extends StatelessWidget {
  const _BootstrapHome();

  @override
  Widget build(BuildContext context) {
    return FScaffold(
      header: const FHeader(title: Text('Hark')),
      child: Center(
        child: Text(
          'Hark is warming up…',
          style: context.theme.typography.lg,
        ),
      ),
    );
  }
}
