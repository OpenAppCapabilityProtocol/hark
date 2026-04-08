import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/capability_registry.dart';
import '../services/intent_dispatcher.dart';

/// Capability registry requires async initialization (OACP provider discovery
/// and manifest parsing), so it is exposed as a [FutureProvider]. Callers
/// should watch this provider and render loading / error UI while the
/// underlying `AsyncValue<CapabilityRegistry>` is settling.
final capabilityRegistryProvider = FutureProvider<CapabilityRegistry>((
  ref,
) async {
  final registry = CapabilityRegistry();
  await registry.initialize();
  return registry;
});

/// Intent dispatcher depends on a ready [CapabilityRegistry].
///
/// This provider uses `requireValue`, so it MUST only be read once
/// [capabilityRegistryProvider] has resolved successfully. Callers that might
/// read this before the registry is ready should gate access on the
/// registry's `AsyncValue` state first (e.g. via `ref.watch(
/// capabilityRegistryProvider).when(...)`).
final intentDispatcherProvider = Provider<IntentDispatcher>((ref) {
  final registry = ref.watch(capabilityRegistryProvider).requireValue;
  return IntentDispatcher(registry);
});
