import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../state/embedding_notifier.dart';
import '../state/init_notifier.dart';
import '../state/slot_filling_notifier.dart';

/// Branded first-run splash. Held on screen until [InitState.isReady].
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(initProvider);
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    return FScaffold(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(32),
                    child: Image.asset(
                      'assets/hark_logo.png',
                      width: 128,
                      height: 128,
                      fit: BoxFit.cover,
                      cacheWidth: 256,
                      cacheHeight: 256,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Title
                Text(
                  'Hark',
                  textAlign: TextAlign.center,
                  style: typography.xl3.copyWith(
                    color: colors.foreground,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Voice assistant for your apps',
                  textAlign: TextAlign.center,
                  style: typography.sm.copyWith(color: colors.mutedForeground),
                ),
                const SizedBox(height: 40),
                // Aggregate progress bar
                if (!init.isReady && !init.hasFailure) ...[
                  _ProgressBar(
                    progress: init.aggregateProgress,
                    indeterminate: init.aggregateProgress == null,
                    isFailed: false,
                  ),
                  const SizedBox(height: 20),
                ],
                // Per-model progress
                _ModelRow(
                  label: 'EmbeddingGemma',
                  stage: init.embedding.stage.name,
                  message: init.embedding.message,
                  progress: init.embedding.progress,
                  receivedBytes: init.embedding.receivedBytes,
                  totalBytes: init.embedding.totalBytes,
                  isReady: init.embedding.isReady,
                  isFailed: init.embedding.stage == EmbeddingStage.failed,
                  isBusy: init.embedding.isBusy,
                ),
                const SizedBox(height: 14),
                _ModelRow(
                  label: 'Qwen3 0.6B',
                  stage: init.slotFilling.stage.name,
                  message: init.slotFilling.message,
                  progress: init.slotFilling.progress,
                  isReady: init.slotFilling.isReady,
                  isFailed: init.slotFilling.stage == SlotFillingStage.failed,
                  isBusy: init.slotFilling.isBusy,
                ),
                const SizedBox(height: 14),
                _RegistryRow(
                  ready: init.registryReady,
                  error: init.registryError,
                ),
                const SizedBox(height: 32),
                // First-run explanation: shown when both models are downloading
                // (no cache), so the user understands why hundreds of MB are
                // being fetched before they can use the assistant.
                if (init.embedding.stage == EmbeddingStage.downloading &&
                    init.slotFilling.stage == SlotFillingStage.downloading)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Downloading on-device AI models (~830 MB). '
                      'This happens once — after this, Hark works offline.',
                      textAlign: TextAlign.center,
                      style: typography.xs.copyWith(
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: init.hasFailure
                      ? _FailurePanel(
                          key: const ValueKey('failure'),
                          message: init.failureMessage ?? 'Unknown error',
                          onRetry: () =>
                              ref.read(initProvider.notifier).retryAll(),
                          isDegraded: init.isDegraded,
                          onContinueDegraded: init.isDegraded
                              ? () => ref
                                    .read(initProvider.notifier)
                                    .acceptDegraded()
                              : null,
                        )
                      : Text(
                          init.isReady
                              ? 'Ready.'
                              : 'Preparing on-device models…',
                          key: ValueKey(init.isReady ? 'ready' : 'preparing'),
                          textAlign: TextAlign.center,
                          style: typography.sm.copyWith(
                            color: colors.mutedForeground,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.label,
    required this.stage,
    required this.message,
    required this.progress,
    required this.isReady,
    required this.isFailed,
    required this.isBusy,
    this.receivedBytes,
    this.totalBytes,
  });

  final String label;
  final String stage;
  final String message;
  final double? progress;
  final int? receivedBytes;
  final int? totalBytes;
  final bool isReady;
  final bool isFailed;
  final bool isBusy;

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final accent = isFailed
        ? colors.destructive
        : isReady
        ? colors.primary
        : colors.mutedForeground;

    // Build the sub-label: byte progress when downloading, otherwise message.
    String? subLabel;
    if (receivedBytes != null && totalBytes != null && totalBytes! > 0) {
      subLabel =
          '${_formatBytes(receivedBytes!)} / ${_formatBytes(totalBytes!)}';
    } else if (!isReady && !isFailed && message.isNotEmpty) {
      subLabel = message;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: typography.sm.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                isFailed
                    ? 'Failed'
                    : isReady
                    ? 'Ready'
                    : stage,
                key: ValueKey(
                  isFailed
                      ? 'failed'
                      : isReady
                      ? 'ready'
                      : stage,
                ),
                style: typography.xs.copyWith(color: accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _ProgressBar(
          progress: isReady ? 1.0 : progress,
          indeterminate: isBusy && progress == null,
          isFailed: isFailed,
        ),
        if (subLabel != null) ...[
          const SizedBox(height: 4),
          Text(
            subLabel,
            style: typography.xs.copyWith(color: colors.mutedForeground),
          ),
        ],
      ],
    );
  }
}

class _RegistryRow extends StatelessWidget {
  const _RegistryRow({required this.ready, required this.error});

  final bool ready;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final failed = error != null;
    final accent = failed
        ? colors.destructive
        : ready
        ? colors.primary
        : colors.mutedForeground;

    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Capability registry',
            style: typography.sm.copyWith(
              color: colors.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            failed ? 'Failed' : (ready ? 'Ready' : 'Scanning…'),
            key: ValueKey(
              failed
                  ? 'failed'
                  : ready
                  ? 'ready'
                  : 'scanning',
            ),
            style: typography.xs.copyWith(color: accent),
          ),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.progress,
    required this.indeterminate,
    required this.isFailed,
  });

  final double? progress;
  final bool indeterminate;
  final bool isFailed;

  @override
  Widget build(BuildContext context) {
    if (isFailed) {
      return const SizedBox(height: 4);
    }
    if (indeterminate) {
      return const FProgress();
    }
    final value = (progress ?? 0.0).clamp(0.0, 1.0);
    return FDeterminateProgress(value: value);
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    super.key,
    required this.message,
    required this.onRetry,
    this.isDegraded = false,
    this.onContinueDegraded,
  });

  final String message;
  final VoidCallback onRetry;
  final bool isDegraded;
  final VoidCallback? onContinueDegraded;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Couldn\'t finish warm-up',
          textAlign: TextAlign.center,
          style: typography.sm.copyWith(
            color: colors.destructive,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: typography.xs.copyWith(color: colors.mutedForeground),
        ),
        const SizedBox(height: 16),
        Center(
          child: FButton(onPress: onRetry, child: const Text('Retry')),
        ),
        if (isDegraded && onContinueDegraded != null) ...[
          const SizedBox(height: 8),
          Center(
            child: FButton(
              onPress: onContinueDegraded!,
              variant: FButtonVariant.outline,
              child: const Text('Continue in limited mode'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Simple commands will work. Commands needing '
            'parameter extraction will be unavailable.',
            textAlign: TextAlign.center,
            style: typography.xs.copyWith(color: colors.mutedForeground),
          ),
        ],
      ],
    );
  }
}
