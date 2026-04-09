import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../models/assistant_action.dart';
import '../state/app_icon_provider.dart';
import '../state/registry_provider.dart';

/// "What you can say" — a swipeable deck of example utterances, one card per
/// (action, example) pair, backed by `capabilityRegistryProvider`.
///
/// This screen is intentionally NOT a schema browser. It's a discovery
/// surface: one card = one thing the user can say to Hark. Swipe to browse,
/// tap for details (parameters, alt examples, full description).
class AvailableActionsScreen extends ConsumerStatefulWidget {
  const AvailableActionsScreen({super.key});

  @override
  ConsumerState<AvailableActionsScreen> createState() =>
      _AvailableActionsScreenState();
}

class _AvailableActionsScreenState
    extends ConsumerState<AvailableActionsScreen> {
  final PageController _pageController = PageController(viewportFraction: 0.88);
  int _currentIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(capabilityRegistryProvider);
  }

  @override
  Widget build(BuildContext context) {
    final registryAsync = ref.watch(capabilityRegistryProvider);
    final isRefreshing = registryAsync.isRefreshing || registryAsync.isLoading;

    return FScaffold(
      header: FHeader.nested(
        title: const Text('What you can say'),
        prefixes: [
          FButton.icon(
            onPress: () => context.pop(),
            variant: FButtonVariant.ghost,
            child: const Icon(FIcons.arrowLeft),
          ),
        ],
        suffixes: [
          FButton.icon(
            onPress: isRefreshing ? null : _refresh,
            variant: FButtonVariant.ghost,
            child: isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: FCircularProgress(size: FCircularProgressSizeVariant.sm),
                  )
                : const Icon(FIcons.refreshCw),
          ),
        ],
      ),
      child: registryAsync.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        data: (registry) {
          final cards = _buildCards(registry.actions);
          if (cards.isEmpty) return const _EmptyState();
          return _UtteranceDeck(
            cards: cards,
            pageController: _pageController,
            currentIndex: _currentIndex,
            onPageChanged: (index) => setState(() => _currentIndex = index),
            totalActions: _uniqueActionCount(registry.actions),
            totalApps: _uniqueAppCount(registry.actions),
          );
        },
        loading: () => const Center(child: FCircularProgress()),
        error: (error, _) => _ErrorState(message: error.toString()),
      ),
    );
  }

  int _uniqueAppCount(List<AssistantAction> actions) {
    final ids = <String>{};
    for (final action in actions) {
      if (action.sourceType == AssistantActionSourceType.oacp) {
        ids.add(action.sourceId);
      }
    }
    return ids.length;
  }

  int _uniqueActionCount(List<AssistantAction> actions) {
    return actions
        .where((a) => a.sourceType == AssistantActionSourceType.oacp)
        .length;
  }

  /// Flatten actions into a deck where each (action, example) pair is one
  /// card. Actions with no examples contribute a single card whose utterance
  /// is derived from the humanized action id. Sorted alphabetically by app
  /// name, then by the original example order within the action — stable so
  /// the deck doesn't reshuffle on rebuild.
  List<_UtteranceCard> _buildCards(List<AssistantAction> actions) {
    final oacp = actions
        .where((a) => a.sourceType == AssistantActionSourceType.oacp)
        .toList()
      ..sort((a, b) {
        final byApp = a.displayName.compareTo(b.displayName);
        if (byApp != 0) return byApp;
        return a.actionId.compareTo(b.actionId);
      });

    final cards = <_UtteranceCard>[];
    for (final action in oacp) {
      if (action.examples.isEmpty) {
        cards.add(_UtteranceCard(
          action: action,
          utterance: _humanizeActionId(action.actionId),
          exampleIndex: 0,
          exampleCount: 1,
        ));
      } else {
        for (var i = 0; i < action.examples.length; i++) {
          cards.add(_UtteranceCard(
            action: action,
            utterance: action.examples[i],
            exampleIndex: i,
            exampleCount: action.examples.length,
          ));
        }
      }
    }
    return cards;
  }
}

// ----------------------------------------------------------------------------

class _UtteranceCard {
  const _UtteranceCard({
    required this.action,
    required this.utterance,
    required this.exampleIndex,
    required this.exampleCount,
  });

  final AssistantAction action;
  final String utterance;
  final int exampleIndex;
  final int exampleCount;
}

// ----------------------------------------------------------------------------

class _UtteranceDeck extends StatelessWidget {
  const _UtteranceDeck({
    required this.cards,
    required this.pageController,
    required this.currentIndex,
    required this.onPageChanged,
    required this.totalActions,
    required this.totalApps,
  });

  final List<_UtteranceCard> cards;
  final PageController pageController;
  final int currentIndex;
  final ValueChanged<int> onPageChanged;
  final int totalActions;
  final int totalApps;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: pageController,
            itemCount: cards.length,
            onPageChanged: onPageChanged,
            itemBuilder: (context, index) {
              final card = cards[index];
              final isActive = index == currentIndex;
              return _UtteranceCardView(card: card, isActive: isActive);
            },
          ),
        ),
        const SizedBox(height: 12),
        _PageCounter(
          current: currentIndex + 1,
          total: cards.length,
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(
            '$totalActions things · $totalApps apps',
            style: typography.xs.copyWith(
              color: colors.mutedForeground,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------------------

class _UtteranceCardView extends StatelessWidget {
  const _UtteranceCardView({required this.card, required this.isActive});

  final _UtteranceCard card;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final gradient = _gradientFor(card.action.domain, card.action.sourceId);

    return AnimatedScale(
      scale: isActive ? 1.0 : 0.94,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showDetailsSheet(context, card),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: gradient.first.withValues(alpha: 0.35),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _AppIconLarge(packageName: card.action.sourceId),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              card.action.displayName,
                              style: typography.md.copyWith(
                                color: _onGradient.withValues(alpha: 0.95),
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (card.action.domain != null &&
                                card.action.domain!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  card.action.domain!.toLowerCase(),
                                  style: typography.xs.copyWith(
                                    color: _onGradient.withValues(alpha: 0.7),
                                    letterSpacing: 0.4,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '\u201c${card.utterance}\u201d',
                            textAlign: TextAlign.center,
                            style: typography.xl2.copyWith(
                              color: _onGradient,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    height: 1,
                    color: _onGradient.withValues(alpha: 0.18),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        FIcons.chevronUp,
                        size: 14,
                        color: _onGradient.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'tap for details',
                        style: typography.xs.copyWith(
                          color: _onGradient.withValues(alpha: 0.7),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

/// Solid white foreground used on every gradient card. All gradient pairs in
/// [_domainGradients] are chosen so white text at ≥0.7 alpha remains legible.
const Color _onGradient = Color(0xFFFFFFFF);

/// Hand-tuned gradient pairs per OACP `domain`. Falls back to
/// [_fallbackGradients] indexed by a hash of the source package name so
/// unknown domains still get a stable, distinct colour per app.
const Map<String, List<Color>> _domainGradients = {
  'music':         [Color(0xFF7C3AED), Color(0xFFEC4899)],
  'audio':         [Color(0xFF7C3AED), Color(0xFFEC4899)],
  'media':         [Color(0xFFD97706), Color(0xFFF59E0B)],
  'knowledge':     [Color(0xFF2563EB), Color(0xFF06B6D4)],
  'reference':     [Color(0xFF0891B2), Color(0xFF14B8A6)],
  'encyclopedia':  [Color(0xFF2563EB), Color(0xFF06B6D4)],
  'search':        [Color(0xFF2563EB), Color(0xFF06B6D4)],
  'navigation':    [Color(0xFF059669), Color(0xFF84CC16)],
  'maps':          [Color(0xFF059669), Color(0xFF84CC16)],
  'camera':        [Color(0xFFF97316), Color(0xFFEF4444)],
  'photo':         [Color(0xFFF97316), Color(0xFFEF4444)],
  'communication': [Color(0xFF10B981), Color(0xFF3B82F6)],
  'messaging':     [Color(0xFF10B981), Color(0xFF3B82F6)],
  'productivity':  [Color(0xFF6366F1), Color(0xFF8B5CF6)],
  'tasks':         [Color(0xFF6366F1), Color(0xFF8B5CF6)],
  'calendar':      [Color(0xFF6366F1), Color(0xFF8B5CF6)],
  'utility':       [Color(0xFF64748B), Color(0xFF334155)],
  'tools':         [Color(0xFF64748B), Color(0xFF334155)],
  'file':          [Color(0xFF64748B), Color(0xFF334155)],
  'files':         [Color(0xFF64748B), Color(0xFF334155)],
  'health':        [Color(0xFFE11D48), Color(0xFFBE185D)],
  'fitness':       [Color(0xFFE11D48), Color(0xFFBE185D)],
  'weather':       [Color(0xFF0EA5E9), Color(0xFF6366F1)],
  'reading':       [Color(0xFF92400E), Color(0xFFF59E0B)],
  'scanner':       [Color(0xFFF97316), Color(0xFFEF4444)],
  'barcode':       [Color(0xFFF97316), Color(0xFFEF4444)],
  'recording':     [Color(0xFFDB2777), Color(0xFF9333EA)],
  'voice':         [Color(0xFFDB2777), Color(0xFF9333EA)],
};

const List<List<Color>> _fallbackGradients = [
  [Color(0xFF8B5CF6), Color(0xFFEC4899)],
  [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
  [Color(0xFF14B8A6), Color(0xFF3B82F6)],
  [Color(0xFFF59E0B), Color(0xFFEF4444)],
  [Color(0xFF22C55E), Color(0xFF14B8A6)],
  [Color(0xFFEC4899) ,Color(0xFFF97316)],
];

List<Color> _gradientFor(String? domain, String sourceId) {
  if (domain != null) {
    final key = domain.toLowerCase().trim();
    final hit = _domainGradients[key];
    if (hit != null) return hit;
  }
  final hash = sourceId.hashCode.abs();
  return _fallbackGradients[hash % _fallbackGradients.length];
}

// ----------------------------------------------------------------------------

class _AppIconLarge extends ConsumerWidget {
  const _AppIconLarge({required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appInfoProvider(packageName));
    const double size = 52;
    const radius = BorderRadius.all(Radius.circular(14));

    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: _onGradient.withValues(alpha: 0.14),
        border: Border.all(
          color: _onGradient.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: size,
          child: info.when(
            data: (appInfo) {
              final iconBytes = appInfo?.icon;
              if (iconBytes == null || iconBytes.isEmpty) {
                return const Icon(
                  FIcons.package,
                  size: 22,
                  color: _onGradient,
                );
              }
              return Image.memory(
                iconBytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                cacheWidth: 120,
                cacheHeight: 120,
                errorBuilder: (_, _, _) => const Icon(
                  FIcons.package,
                  size: 22,
                  color: _onGradient,
                ),
              );
            },
            loading: () => const SizedBox(),
            error: (_, _) => const Icon(
              FIcons.package,
              size: 22,
              color: _onGradient,
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _PageCounter extends StatelessWidget {
  const _PageCounter({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    // Dots for small decks, "n / total" text for bigger ones.
    if (total <= 10) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < total; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == current - 1 ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == current - 1
                    ? colors.primary
                    : colors.mutedForeground.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      );
    }
    return Text(
      '$current / $total',
      style: typography.xs.copyWith(
        color: colors.mutedForeground,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

// ----------------------------------------------------------------------------

Future<void> _showDetailsSheet(BuildContext context, _UtteranceCard card) {
  return showFSheet<void>(
    context: context,
    side: FLayout.btt,
    mainAxisMaxRatio: 0.75,
    builder: (sheetContext) => _ActionDetailsSheet(card: card),
  );
}

class _ActionDetailsSheet extends StatelessWidget {
  const _ActionDetailsSheet({required this.card});

  final _UtteranceCard card;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final action = card.action;
    final requiredParams =
        action.parameters.where((p) => p.required).toList(growable: false);
    final optionalParams =
        action.parameters.where((p) => !p.required).toList(growable: false);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.mutedForeground.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _SheetAppIcon(packageName: action.sourceId),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          action.displayName,
                          style: typography.md.copyWith(
                            color: colors.foreground,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _humanizeActionId(action.actionId),
                          style: typography.sm.copyWith(
                            color: colors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (action.description.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  action.description,
                  style: typography.sm.copyWith(color: colors.foreground),
                ),
              ],
              if (action.examples.length > 1) ...[
                const SizedBox(height: 20),
                Text(
                  'Also try',
                  style: typography.xs.copyWith(
                    color: colors.mutedForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < action.examples.length; i++)
                  if (i != card.exampleIndex)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '\u201c${action.examples[i]}\u201d',
                        style: typography.sm.copyWith(
                          color: colors.mutedForeground,
                        ),
                      ),
                    ),
              ],
              if (action.parameters.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Parameters',
                  style: typography.xs.copyWith(
                    color: colors.mutedForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in requiredParams) _ParamChip(parameter: p),
                    for (final p in optionalParams) _ParamChip(parameter: p),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetAppIcon extends ConsumerWidget {
  const _SheetAppIcon({required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appInfoProvider(packageName));
    final colors = context.theme.colors;
    const double size = 40;
    const radius = BorderRadius.all(Radius.circular(10));

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(
        dimension: size,
        child: info.when(
          data: (appInfo) {
            final iconBytes = appInfo?.icon;
            if (iconBytes == null || iconBytes.isEmpty) {
              return ColoredBox(
                color: colors.muted,
                child: Icon(FIcons.package,
                    size: 18, color: colors.mutedForeground),
              );
            }
            return Image.memory(
              iconBytes,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              cacheWidth: 96,
              cacheHeight: 96,
              errorBuilder: (_, _, _) => ColoredBox(
                color: colors.muted,
                child: Icon(FIcons.package,
                    size: 18, color: colors.mutedForeground),
              ),
            );
          },
          loading: () => ColoredBox(color: colors.muted),
          error: (_, _) => ColoredBox(
            color: colors.muted,
            child: Icon(FIcons.package,
                size: 18, color: colors.mutedForeground),
          ),
        ),
      ),
    );
  }
}

class _ParamChip extends StatelessWidget {
  const _ParamChip({required this.parameter});

  final AssistantActionParameter parameter;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final isRequired = parameter.required;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isRequired
            ? colors.primary.withValues(alpha: 0.18)
            : colors.muted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isRequired
              ? colors.primary.withValues(alpha: 0.65)
              : colors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            parameter.name,
            style: typography.xs.copyWith(
              color: isRequired ? colors.primary : colors.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '  ${parameter.type}${isRequired ? ' · required' : ''}',
            style: typography.xs.copyWith(color: colors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FIcons.sparkles, size: 48, color: colors.mutedForeground),
            const SizedBox(height: 16),
            Text(
              'No apps integrated yet.',
              textAlign: TextAlign.center,
              style: typography.lg.copyWith(
                color: colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Install an app that speaks OACP and tap refresh.',
              textAlign: TextAlign.center,
              style: typography.sm.copyWith(color: colors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FIcons.triangleAlert, size: 48, color: colors.destructive),
            const SizedBox(height: 16),
            Text(
              'Could not load capabilities.',
              textAlign: TextAlign.center,
              style: typography.lg.copyWith(
                color: colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: typography.xs.copyWith(color: colors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

/// Turn `increment_counter` into `Increment Counter`.
///
/// OACP doesn't ship a per-capability human-readable title — `displayName`
/// on [AssistantAction] is populated with the *app* name from the manifest.
/// We derive the capability label by splitting the `actionId` on `_` or `-`
/// and title-casing each word, which works on every test app in the harness
/// and is non-breaking for the OACP spec.
String _humanizeActionId(String actionId) {
  if (actionId.isEmpty) return actionId;
  return actionId
      .split(RegExp(r'[_\-]'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => word[0].toUpperCase() + word.substring(1).toLowerCase(),
      )
      .join(' ');
}
