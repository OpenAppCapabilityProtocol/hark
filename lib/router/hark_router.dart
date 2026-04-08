import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/assistant_screen.dart';
import '../screens/available_actions_screen.dart';
import '../screens/splash_screen.dart';
import '../state/init_notifier.dart';

/// Route paths used by Hark's [GoRouter]. Kept as constants so screens can
/// navigate via `context.go(HarkRoutes.chat)` without stringly-typed paths.
class HarkRoutes {
  const HarkRoutes._();

  static const splash = '/';
  static const chat = '/chat';
  static const actions = '/actions';
}

/// Provides the app's singleton [GoRouter].
///
/// Subscribes to [initProvider] and refreshes the router whenever the
/// on-device models flip between "busy" and "ready" so the redirect logic
/// re-evaluates. Uses a hand-rolled pure [Listenable] — no [ChangeNotifier].
final goRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefreshListenable();
  ref.onDispose(refresh.dispose);

  ref.listen<InitState>(
    initProvider,
    (previous, next) {
      final wasReady = previous?.isReady ?? false;
      if (wasReady != next.isReady) {
        refresh.notify();
      }
    },
  );

  return GoRouter(
    initialLocation: HarkRoutes.splash,
    refreshListenable: refresh,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) {
      final init = ref.read(initProvider);
      final atSplash = state.matchedLocation == HarkRoutes.splash;

      if (atSplash && init.isReady) {
        return HarkRoutes.chat;
      }
      if (!atSplash && !init.isReady) {
        return HarkRoutes.splash;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: HarkRoutes.splash,
        name: 'splash',
        builder: (_, _) => const SplashScreen(),
      ),
      GoRoute(
        path: HarkRoutes.chat,
        name: 'chat',
        builder: (_, _) => const AssistantScreen(),
      ),
      GoRoute(
        path: HarkRoutes.actions,
        name: 'actions',
        builder: (_, _) => const AvailableActionsScreen(),
      ),
    ],
  );
});

/// Minimal [Listenable] that notifies registered callbacks on demand.
///
/// Deliberately NOT a [ChangeNotifier] — Hark is Riverpod-only.
class _RouterRefreshListenable implements Listenable {
  final List<VoidCallback> _listeners = [];

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notify() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _listeners.clear();
  }
}
