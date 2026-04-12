import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hark_platform/hark_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kWakeWordEnabled = 'wake_word_enabled';

/// User-tunable settings backed by [SharedPreferences].
///
/// Currently only tracks the wake word on/off preference. Built as an
/// [AsyncNotifier] so the UI can `watch` it and react to the persisted value
/// once it loads — the initial `null` state is handled by the Settings screen
/// with a loading indicator.
class SettingsNotifier extends AsyncNotifier<SettingsState> {
  final _commonApi = HarkCommonApi();

  @override
  Future<SettingsState> build() async {
    final prefs = await SharedPreferences.getInstance();
    final wakeWordEnabled = prefs.getBool(_kWakeWordEnabled) ?? true;
    return SettingsState(wakeWordEnabled: wakeWordEnabled);
  }

  /// Toggle wake word detection. Persists immediately and starts/stops the
  /// foreground service.
  Future<void> setWakeWordEnabled(bool enabled) async {
    final prev = switch (state) {
      AsyncData(:final value) => value,
      _ => null,
    };
    state = AsyncData(SettingsState(wakeWordEnabled: enabled));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kWakeWordEnabled, enabled);
      if (enabled) {
        _commonApi.startWakeWordService();
      } else {
        _commonApi.stopWakeWordService();
      }
    } catch (e) {
      debugPrint('SettingsNotifier: wake word toggle failed: $e');
      if (prev != null) state = AsyncData(prev);
    }
  }
}

@immutable
class SettingsState {
  const SettingsState({required this.wakeWordEnabled});

  final bool wakeWordEnabled;
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, SettingsState>(SettingsNotifier.new);

/// Read the persisted wake word preference without spinning up a notifier
/// dependency. Used by [ChatNotifier] at init time to decide whether to
/// start the wake word service at all.
Future<bool> readWakeWordEnabledPref() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kWakeWordEnabled) ?? true;
}
