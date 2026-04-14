import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../services/cloud/azure_url_parser.dart';
import '../services/cloud/cloud_provider_config.dart';
import '../state/cloud_provider_notifier.dart';

/// Minimal Cloud Brain settings screen — single Foundry / Azure
/// integration with two inputs (full URL + API key). Saves to secure
/// storage via [CloudProviderNotifier] and bumps the routing mode to
/// `cloudPreferred` so the next voice command takes the cloud path.
///
/// This is the Slice 5 "minimum viable UI" — no provider dropdown, no
/// mode toggle, no test-connection button, no cost meter. Those land in
/// later slices once the basic save/load round trip is solid.
class CloudBrainScreen extends ConsumerStatefulWidget {
  const CloudBrainScreen({super.key});

  @override
  ConsumerState<CloudBrainScreen> createState() => _CloudBrainScreenState();
}

class _CloudBrainScreenState extends ConsumerState<CloudBrainScreen> {
  final _urlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _parser = const AzureUrlParser();

  String? _errorMessage;
  String? _statusMessage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Pre-populate the URL field if a config is already saved so the
    // user can see what they had last time. Never pre-populate the API
    // key — making them paste it again is the safer default.
    Future.microtask(_loadExisting);
  }

  Future<void> _loadExisting() async {
    final notifier = ref.read(cloudProviderNotifierProvider.notifier);
    await notifier.awaitInitialLoad();
    if (!mounted) return;
    final state = ref.read(cloudProviderNotifierProvider);
    final config = state.config;
    if (config is AzureConfig) {
      // Reconstruct the kind of URL the user originally pasted, so the
      // field round-trips visibly. This is just `baseUrl` with the
      // api-version query param tacked back on.
      _urlController.text =
          '${config.baseUrl}/chat/completions?api-version=${config.apiVersion}';
      setState(() {
        _statusMessage = 'Configured · deployment ${config.model}';
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
      _saving = true;
    });

    try {
      final config = _parser.parse(
        rawUrl: _urlController.text,
        apiKey: _apiKeyController.text,
      );
      if (config.apiKey.isEmpty) {
        throw const FormatException('API key is empty.');
      }

      final notifier = ref.read(cloudProviderNotifierProvider.notifier);
      await notifier.setConfig(config);
      // Flip routing to cloudPreferred so the next voice command
      // actually exercises the cloud path. The user can still toggle
      // back to local-only via a future settings screen.
      await notifier.setMode(CloudRoutingMode.cloudPreferred);

      if (!mounted) return;
      // Don't keep the key in the field after a successful save.
      _apiKeyController.clear();
      setState(() {
        _statusMessage =
            'Saved · deployment ${config.model} · cloud preferred';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Save failed: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    setState(() {
      _errorMessage = null;
      _statusMessage = null;
      _saving = true;
    });
    try {
      final notifier = ref.read(cloudProviderNotifierProvider.notifier);
      await notifier.clearConfig();
      await notifier.setMode(CloudRoutingMode.localOnly);
      _urlController.clear();
      _apiKeyController.clear();
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Cleared · using local Qwen3';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Clear failed: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final state = ref.watch(cloudProviderNotifierProvider);
    final hasConfig = state.hasConfig;

    return FScaffold(
      header: FHeader.nested(
        title: const Text('Cloud Brain'),
        prefixes: [
          FButton.icon(
            onPress: () => context.pop(),
            variant: FButtonVariant.ghost,
            child: const Icon(FIcons.arrowLeft),
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Foundry / Azure OpenAI',
            style: typography.lg.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Paste the full endpoint URL and API key from the Azure '
            'portal (Keys and Endpoint tab). Hark sends voice transcripts '
            'directly to your deployment — they never go through Hark.',
            style: typography.sm.copyWith(color: colors.mutedForeground),
          ),
          const SizedBox(height: 20),

          Text(
            'Endpoint URL',
            style: typography.sm.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          FTextField(
            control: FTextFieldControl.managed(
              controller: _urlController,
            ),
            hint:
                'https://{resource}.cognitiveservices.azure.com/openai/deployments/{deployment}/chat/completions?api-version=...',
            maxLines: 4,
          ),

          const SizedBox(height: 16),
          Text(
            'API key',
            style: typography.sm.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          FTextField(
            control: FTextFieldControl.managed(
              controller: _apiKeyController,
            ),
            hint: hasConfig ? '••••• (saved — paste to replace)' : 'Azure key',
            obscureText: true,
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            _StatusBanner(
              text: _errorMessage!,
              color: colors.destructive,
            ),
          ],
          if (_statusMessage != null) ...[
            const SizedBox(height: 12),
            _StatusBanner(
              text: _statusMessage!,
              color: colors.primary,
            ),
          ],

          const SizedBox(height: 20),
          FButton(
            onPress: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
          if (hasConfig) ...[
            const SizedBox(height: 10),
            FButton(
              onPress: _saving ? null : _clear,
              variant: FButtonVariant.secondary,
              child: const Text('Clear'),
            ),
          ],

          const SizedBox(height: 24),
          Text(
            'Privacy',
            style: typography.sm.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Your API key is stored encrypted via Android Keystore. On '
            'rooted devices the key file name is visible but the value '
            'is not. When cloud is on, voice transcripts are sent '
            'directly to your provider — Hark never sees them.',
            style: typography.xs.copyWith(color: colors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: context.theme.typography.sm.copyWith(color: color),
      ),
    );
  }
}
