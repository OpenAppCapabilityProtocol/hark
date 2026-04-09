import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../models/assistant_action.dart';
import '../state/app_icon_provider.dart';
import '../state/registry_provider.dart';

/// "What you can say" — a grouped scrollable list of OACP capabilities.
///
/// Apps are section headers; actions are rows inside each section. Each
/// row's primary label is the first example utterance ("play next song"),
/// with the humanized action id ("Next Song") as the secondary hint. Tap a
/// row to open a bottom sheet with the full description, alt examples, and
/// parameter chips.
class AvailableActionsScreen extends ConsumerStatefulWidget {
  const AvailableActionsScreen({super.key});

  @override
  ConsumerState<AvailableActionsScreen> createState() =>
      _AvailableActionsScreenState();
}

class _AvailableActionsScreenState
    extends ConsumerState<AvailableActionsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
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
                    child: FCircularProgress(
                        size: FCircularProgressSizeVariant.sm),
                  )
                : const Icon(FIcons.refreshCw),
          ),
        ],
      ),
      child: registryAsync.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        data: (registry) => _ActionsBody(
          actions: registry.actions,
          searchController: _searchController,
          query: _query,
          onQueryChanged: (value) {
            setState(() {
              _query = value.trim().toLowerCase();
            });
          },
        ),
        loading: () => const Center(child: FCircularProgress()),
        error: (error, _) => _ErrorState(message: error.toString()),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _ActionsBody extends StatelessWidget {
  const _ActionsBody({
    required this.actions,
    required this.searchController,
    required this.query,
    required this.onQueryChanged,
  });

  final List<AssistantAction> actions;
  final TextEditingController searchController;
  final String query;
  final ValueChanged<String> onQueryChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    if (actions.isEmpty) {
      return const _EmptyState();
    }

    final groups = _groupByApp(actions, query);
    final totalActions = actions
        .where((a) => a.sourceType == AssistantActionSourceType.oacp)
        .length;
    final totalApps = _uniqueAppCount(actions);

    // Header (search + summary) + per-app sections in a single lazy list.
    const headerItemCount = 1;
    final groupCount = groups.isEmpty ? 1 : groups.length;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: headerItemCount + groupCount,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FTextField(
                  control: FTextFieldControl.managed(
                    controller: searchController,
                    onChange: (value) => onQueryChanged(value.text),
                  ),
                  hint: 'Search apps and actions',
                  prefixBuilder: (context, style, variants) => Padding(
                    padding: const EdgeInsetsDirectional.only(
                        start: 10, end: 8),
                    child: Icon(FIcons.search,
                        size: 18, color: colors.mutedForeground),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '$totalActions things · $totalApps apps',
                    style: typography.xs.copyWith(
                      color: colors.mutedForeground,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        if (groups.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                'No matches for "${searchController.text}".',
                style:
                    typography.sm.copyWith(color: colors.mutedForeground),
              ),
            ),
          );
        }
        final group = groups[index - headerItemCount];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _AppSection(group: group),
        );
      },
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

  List<_AppGroup> _groupByApp(List<AssistantAction> actions, String query) {
    final grouped = <String, List<AssistantAction>>{};
    for (final action in actions) {
      if (action.sourceType != AssistantActionSourceType.oacp) continue;
      if (!_matchesQuery(action, query)) continue;
      grouped.putIfAbsent(action.sourceId, () => []).add(action);
    }

    final groups = grouped.entries.map((entry) {
      final sorted = [...entry.value]
        ..sort((a, b) => a.actionId.compareTo(b.actionId));
      return _AppGroup(
        sourceId: entry.key,
        appName: sorted.first.displayName,
        domain: sorted.first.domain,
        actions: sorted,
      );
    }).toList(growable: false);

    groups.sort((a, b) => a.appName.compareTo(b.appName));
    return groups;
  }

  bool _matchesQuery(AssistantAction action, String query) {
    if (query.isEmpty) return true;
    final haystack = [
      action.displayName,
      action.sourceId,
      action.actionId,
      action.description,
      ...action.examples,
      ...action.parameters.map((p) => p.name),
    ].join(' ').toLowerCase();
    return haystack.contains(query);
  }
}

// ----------------------------------------------------------------------------

class _AppGroup {
  const _AppGroup({
    required this.sourceId,
    required this.appName,
    required this.domain,
    required this.actions,
  });

  final String sourceId;
  final String appName;
  final String? domain;
  final List<AssistantAction> actions;
}

/// One collapsible card per app. Collapsed state (default) shows just the
/// app icon, name, and an action-count pill. Tap the header to expand and
/// reveal the list of [_ActionRow]s for that app.
class _AppSection extends StatefulWidget {
  const _AppSection({required this.group});

  final _AppGroup group;

  @override
  State<_AppSection> createState() => _AppSectionState();
}

class _AppSectionState extends State<_AppSection>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final group = widget.group;
    final accent = _accentFor(group.domain, group.sourceId);
    final count = group.actions.length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.border.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tappable header — always visible
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _AppIconTile(packageName: group.sourceId, accent: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      group.appName,
                      style: typography.md.copyWith(
                        color: colors.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.45),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '$count',
                      style: typography.xs.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    turns: _expanded ? 0.25 : 0,
                    child: Icon(
                      FIcons.chevronRight,
                      size: 18,
                      color: colors.mutedForeground.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Action rows — only when expanded
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 14),
                        color: colors.border.withValues(alpha: 0.5),
                      ),
                      for (var i = 0; i < group.actions.length; i++) ...[
                        _ActionRow(
                          action: group.actions[i],
                          accent: accent,
                          onTap: () =>
                              _showDetailsSheet(context, group.actions[i]),
                        ),
                        if (i != group.actions.length - 1)
                          Container(
                            height: 1,
                            margin: const EdgeInsets.only(left: 14, right: 14),
                            color: colors.border.withValues(alpha: 0.25),
                          ),
                      ],
                      const SizedBox(height: 4),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.accent,
    required this.onTap,
  });

  final AssistantAction action;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    final primary = action.examples.isNotEmpty
        ? '\u201c${action.examples.first}\u201d'
        : _humanizeActionId(action.actionId);
    final secondary = action.examples.isNotEmpty
        ? _humanizeActionId(action.actionId)
        : action.description;
    final secondaryTrimmed = secondary.trim();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 6, right: 12),
              decoration: BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    primary,
                    style: typography.sm.copyWith(
                      color: colors.foreground,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (secondaryTrimmed.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      secondaryTrimmed,
                      style: typography.xs.copyWith(
                        color: colors.mutedForeground,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              FIcons.chevronRight,
              size: 16,
              color: colors.mutedForeground.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _AppIconTile extends ConsumerWidget {
  const _AppIconTile({required this.packageName, required this.accent});

  final String packageName;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appInfoProvider(packageName));
    final colors = context.theme.colors;
    const double size = 40;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: size,
        child: info.when(
          data: (appInfo) {
            final iconBytes = appInfo?.icon;
            if (iconBytes == null || iconBytes.isEmpty) {
              return _IconFallback(color: accent);
            }
            return Image.memory(
              iconBytes,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              cacheWidth: 96,
              cacheHeight: 96,
              errorBuilder: (_, _, _) => _IconFallback(color: accent),
            );
          },
          loading: () => ColoredBox(color: colors.muted),
          error: (_, _) => _IconFallback(color: accent),
        ),
      ),
    );
  }
}

class _IconFallback extends StatelessWidget {
  const _IconFallback({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return ColoredBox(
      color: colors.muted,
      child: Icon(FIcons.package, size: 20, color: color),
    );
  }
}

// ----------------------------------------------------------------------------

/// Hand-tuned accent per OACP `domain`. Used for the app-icon border, the
/// action-row bullet, and the action-count pill. The same palette the
/// earlier swipe-deck variant used for its gradients, but applied as a
/// single solid accent colour per app instead of a full-screen gradient.
const Map<String, Color> _domainAccents = {
  'music':         Color(0xFFA855F7),
  'audio':         Color(0xFFA855F7),
  'media':         Color(0xFFF59E0B),
  'knowledge':     Color(0xFF0EA5E9),
  'reference':     Color(0xFF14B8A6),
  'encyclopedia':  Color(0xFF0EA5E9),
  'search':        Color(0xFF0EA5E9),
  'navigation':    Color(0xFF22C55E),
  'maps':          Color(0xFF22C55E),
  'camera':        Color(0xFFF97316),
  'photo':         Color(0xFFF97316),
  'communication': Color(0xFF3B82F6),
  'messaging':     Color(0xFF3B82F6),
  'productivity':  Color(0xFF8B5CF6),
  'tasks':         Color(0xFF8B5CF6),
  'calendar':      Color(0xFF8B5CF6),
  'utility':       Color(0xFF94A3B8),
  'tools':         Color(0xFF94A3B8),
  'file':          Color(0xFF94A3B8),
  'files':         Color(0xFF94A3B8),
  'health':        Color(0xFFEF4444),
  'fitness':       Color(0xFFEF4444),
  'weather':       Color(0xFF38BDF8),
  'reading':       Color(0xFFF59E0B),
  'scanner':       Color(0xFFF97316),
  'barcode':       Color(0xFFF97316),
  'recording':     Color(0xFFEC4899),
  'voice':         Color(0xFFEC4899),
};

const List<Color> _fallbackAccents = [
  Color(0xFFA855F7),
  Color(0xFF3B82F6),
  Color(0xFF14B8A6),
  Color(0xFFF59E0B),
  Color(0xFF22C55E),
  Color(0xFFEC4899),
];

Color _accentFor(String? domain, String sourceId) {
  if (domain != null) {
    final key = domain.toLowerCase().trim();
    final hit = _domainAccents[key];
    if (hit != null) return hit;
  }
  final hash = sourceId.hashCode.abs();
  return _fallbackAccents[hash % _fallbackAccents.length];
}

// ----------------------------------------------------------------------------

Future<void> _showDetailsSheet(BuildContext context, AssistantAction action) {
  return showFSheet<void>(
    context: context,
    side: FLayout.btt,
    // Let the sheet shrink to its content instead of filling a fixed
    // fraction of the screen. 0.85 is the hard ceiling for very long
    // descriptions + many examples.
    mainAxisMaxRatio: 0.85,
    builder: (sheetContext) => _ActionDetailsSheet(action: action),
  );
}

class _ActionDetailsSheet extends StatelessWidget {
  const _ActionDetailsSheet({required this.action});

  final AssistantAction action;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final accent = _accentFor(action.domain, action.sourceId);
    final requiredParams =
        action.parameters.where((p) => p.required).toList(growable: false);
    final optionalParams =
        action.parameters.where((p) => !p.required).toList(growable: false);

    // Required by forui: the sheet builder must return a widget with an
    // explicit background colour. We intentionally do NOT set
    // height: infinity — letting the column shrink-wrap keeps the sheet
    // tight to its content instead of filling mainAxisMaxRatio.
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 2),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.mutedForeground.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header: icon + action title + app name
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _AppIconTile(
                          packageName: action.sourceId,
                          accent: accent,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _humanizeActionId(action.actionId),
                                style: typography.lg.copyWith(
                                  color: colors.foreground,
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'in ${action.displayName}',
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
                      const SizedBox(height: 16),
                      Text(
                        action.description,
                        style: typography.sm.copyWith(
                          color: colors.foreground.withValues(alpha: 0.88),
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (action.examples.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _SectionHeading(label: 'Try saying', accent: accent),
                      const SizedBox(height: 10),
                      for (final example in action.examples)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Container(
                            padding:
                                const EdgeInsets.fromLTRB(12, 9, 12, 9),
                            decoration: BoxDecoration(
                              color: colors.muted.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(10),
                              border: Border(
                                left: BorderSide(color: accent, width: 2.5),
                              ),
                            ),
                            child: Text(
                              '\u201c$example\u201d',
                              style: typography.sm.copyWith(
                                color: colors.foreground,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ),
                    ],
                    if (action.parameters.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _SectionHeading(label: 'Parameters', accent: accent),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final p in requiredParams)
                            _ParamChip(parameter: p),
                          for (final p in optionalParams)
                            _ParamChip(parameter: p),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: typography.xs.copyWith(
            color: colors.foreground,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ],
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
