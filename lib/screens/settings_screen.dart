import 'package:flutter/material.dart' show Switch;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../router/hark_router.dart';
import '../state/chat_notifier.dart';
import '../state/cloud_provider_notifier.dart';
import '../state/settings_notifier.dart';

/// User-facing settings surface.
///
/// Four sections: permissions, wake word, models, about. Permissions show
/// live status and expose a button to request or open system settings for
/// anything that isn't granted. The wake word section toggles the
/// foreground service via [settingsProvider]. Models are read-only info
/// rows. About shows version + GitHub link.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  PermissionStatus _micStatus = PermissionStatus.denied;
  PermissionStatus _notifStatus = PermissionStatus.denied;
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAll();
  }

  Future<void> _refreshAll() async {
    final mic = await Permission.microphone.status;
    final notif = await Permission.notification.status;
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _micStatus = mic;
      _notifStatus = notif;
      _packageInfo = info;
    });
  }

  Future<void> _requestMic() async {
    final result = await Permission.microphone.request();
    if (result.isPermanentlyDenied) {
      await openAppSettings();
    }
    _refreshAll();
  }

  Future<void> _requestNotif() async {
    final result = await Permission.notification.request();
    if (result.isPermanentlyDenied) {
      await openAppSettings();
    }
    _refreshAll();
  }

  Future<void> _openAssistantSettings() async {
    // TODO: move openAssistantSettings() off ChatNotifier into a dedicated
    // platform notifier so the Settings screen doesn't depend on chat state
    // just to reach a system intent.
    await ref.read(chatProvider.notifier).openAssistantSettings();
  }

  Future<void> _openGitHub() async {
    final uri = Uri.parse('https://github.com/OpenAppCapabilityProtocol/hark');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final settings = ref.watch(settingsProvider);

    return FScaffold(
      header: FHeader.nested(
        title: const Text('Settings'),
        prefixes: [
          FButton.icon(
            onPress: () => context.pop(),
            variant: FButtonVariant.ghost,
            child: const Icon(FIcons.arrowLeft),
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _SectionHeader('Permissions'),
          _PermissionRow(
            icon: FIcons.mic,
            label: 'Microphone',
            description: 'Required to listen to voice commands.',
            status: _micStatus,
            onFix: _requestMic,
          ),
          _PermissionRow(
            icon: FIcons.bell,
            label: 'Notifications',
            description:
                'Lets the wake word foreground service show its status.',
            status: _notifStatus,
            onFix: _requestNotif,
          ),
          _AssistantRoleRow(
            isDefault: chat.isDefaultAssistant,
            onFix: _openAssistantSettings,
          ),

          _SectionHeader('Wake word'),
          _WakeWordToggle(
            state: settings,
            onChanged: (value) =>
                ref.read(settingsProvider.notifier).setWakeWordEnabled(value),
          ),
          const _InfoRow(
            icon: FIcons.file,
            label: 'Model',
            value: 'hey_harkh.onnx · 201 KB',
          ),
          const _InfoRow(
            icon: FIcons.gauge,
            label: 'Threshold',
            value: '0.3 (cooldown 1500 ms)',
          ),

          _SectionHeader('Cloud brain (beta)'),
          _CloudBrainRow(
            state: ref.watch(cloudProviderNotifierProvider),
            onTap: () => context.push(HarkRoutes.cloudBrain),
          ),

          _SectionHeader('Models'),
          // TODO: source model names + sizes from embeddingProvider /
          // slotFillingProvider so they don't drift if the defaults change.
          const _InfoRow(
            icon: FIcons.brain,
            label: 'Intent selection',
            value: 'EmbeddingGemma 308M',
          ),
          const _InfoRow(
            icon: FIcons.wrench,
            label: 'Slot filling',
            value: 'Qwen3 0.6B',
          ),

          _SectionHeader('About'),
          _InfoRow(
            icon: FIcons.info,
            label: 'Version',
            value: _packageInfo == null
                ? '—'
                : '${_packageInfo!.version}+${_packageInfo!.buildNumber}',
          ),
          const _InfoRow(
            icon: FIcons.shield,
            label: 'Protocol',
            value: 'OACP v0.3',
          ),
          _ActionRow(
            icon: FIcons.github,
            label: 'GitHub',
            onTap: _openGitHub,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: typography.xs.copyWith(
          color: colors.mutedForeground,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.icon,
    required this.label,
    required this.description,
    required this.status,
    required this.onFix,
  });

  final IconData icon;
  final String label;
  final String description;
  final PermissionStatus status;
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) {
    final granted = status.isGranted;
    return _Row(
      icon: icon,
      label: label,
      description: description,
      trailing: granted
          ? _StatusPill(text: 'Granted', ok: true)
          : FButton(
              onPress: onFix,
              variant: FButtonVariant.secondary,
              child: Text(status.isPermanentlyDenied ? 'Open' : 'Grant'),
            ),
    );
  }
}

class _AssistantRoleRow extends StatelessWidget {
  const _AssistantRoleRow({required this.isDefault, required this.onFix});

  final bool isDefault;
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) {
    return _Row(
      icon: FIcons.wand,
      label: 'Default assistant',
      description:
          'Required for long-press Home and background overlay launch.',
      trailing: isDefault
          ? _StatusPill(text: 'Active', ok: true)
          : FButton(
              onPress: onFix,
              variant: FButtonVariant.secondary,
              child: const Text('Set'),
            ),
    );
  }
}

class _WakeWordToggle extends StatelessWidget {
  const _WakeWordToggle({required this.state, required this.onChanged});

  final AsyncValue<SettingsState> state;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final current = switch (state) {
      AsyncData(:final value) => value,
      _ => null,
    };
    final enabled = current?.wakeWordEnabled ?? true;
    return _Row(
      icon: FIcons.ear,
      label: '"Hey Hark" detection',
      description: enabled
          ? 'Listening with an on-device 201 KB model.'
          : 'Wake word is off. Use the mic button instead.',
      trailing: state.isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: FCircularProgress(size: FCircularProgressSizeVariant.sm),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  enabled ? 'On' : 'Off',
                  style: context.theme.typography.sm.copyWith(
                    color: enabled ? colors.primary : colors.mutedForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: enabled,
                  onChanged: onChanged,
                  activeThumbColor: colors.primary,
                ),
              ],
            ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return _Row(
      icon: icon,
      label: label,
      trailing: Text(
        value,
        style: typography.sm.copyWith(color: colors.mutedForeground),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return FTappable(
      onPress: onTap,
      child: _Row(
        icon: icon,
        label: label,
        trailing: Icon(
          FIcons.chevronRight,
          size: 16,
          color: colors.mutedForeground,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    this.description,
    required this.trailing,
  });

  final IconData icon;
  final String label;
  final String? description;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: colors.mutedForeground),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: typography.sm.copyWith(
                    color: colors.foreground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    description!,
                    style: typography.xs.copyWith(
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _CloudBrainRow extends StatelessWidget {
  const _CloudBrainRow({required this.state, required this.onTap});

  final CloudProviderState state;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final config = state.config;
    final configured = config != null;
    final description = configured
        ? 'Foundry · ${config.model} · ${state.mode.wireName}'
        : 'Send stage 2 to your own Azure / Foundry deployment.';
    return FTappable(
      onPress: onTap,
      child: _Row(
        icon: FIcons.cloud,
        label: 'Foundry cloud',
        description: description,
        trailing: configured
            ? _StatusPill(text: 'On', ok: true)
            : Icon(
                FIcons.chevronRight,
                size: 16,
                color: colors.mutedForeground,
              ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.ok});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final bg = ok
        ? colors.primary.withValues(alpha: 0.15)
        : colors.destructive.withValues(alpha: 0.15);
    final fg = ok ? colors.primary : colors.destructive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: typography.xs.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
