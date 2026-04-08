import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/init_notifier.dart';
import 'assistant_screen.dart';
import 'splash_screen.dart';

/// Holds the splash on screen until all on-device dependencies are ready,
/// then replaces it with the main [AssistantScreen].
class SplashGate extends ConsumerWidget {
  const SplashGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(initProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: init.isReady
          ? const AssistantScreen(key: ValueKey('assistant'))
          : const SplashScreen(key: ValueKey('splash')),
    );
  }
}
