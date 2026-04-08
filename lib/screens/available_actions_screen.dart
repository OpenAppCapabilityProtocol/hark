import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../models/assistant_action.dart';
import '../state/app_icon_provider.dart';
import '../state/registry_provider.dart';

/// Browse every capability Hark knows how to execute.
///
/// The data backing this screen is the live `capabilityRegistryProvider`
/// (a [FutureProvider]) — the refresh button re-invalidates the provider
/// which kicks off a fresh OACP scan.
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
        title: const Text('Actions'),
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
                      size: FCircularProgressSizeVariant.sm,
                    ),
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FIcons.sparkles, size: 48, color: colors.mutedForeground),
              const SizedBox(height: 16),
              Text(
                'No OACP actions discovered.',
                textAlign: TextAlign.center,
                style: typography.lg.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Install an app that declares an oacp.json content provider and tap refresh.',
                textAlign: TextAlign.center,
                style:
                    typography.sm.copyWith(color: colors.mutedForeground),
              ),
            ],
          ),
        ),
      );
    }

    final groups = _groupByApp(actions, query);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _SummaryRow(
          actionCount: actions.length,
          integrationCount: _uniqueAppCount(actions),
        ),
        const SizedBox(height: 16),
        FTextField(
          control: FTextFieldControl.managed(
            controller: searchController,
            onChange: (value) => onQueryChanged(value.text),
          ),
          hint: 'Filter by app, action, or description',
          prefixBuilder: (context, style, variants) => Padding(
            padding: const EdgeInsetsDirectional.only(start: 10, end: 8),
            child: Icon(
              FIcons.search,
              size: 18,
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                'No matches for "${searchController.text}".',
                style:
                    typography.sm.copyWith(color: colors.mutedForeground),
              ),
            ),
          )
        else
          ...groups.map(
            (group) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _AppGroupCard(group: group),
            ),
          ),
      ],
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
        // All actions from the same app share the same manifest.displayName
        // (it's the app name, not a per-capability label).
        appName: sorted.first.displayName,
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
    required this.actions,
  });

  final String sourceId;
  final String appName;
  final List<AssistantAction> actions;
}

class _AppGroupCard extends StatelessWidget {
  const _AppGroupCard({required this.group});

  final _AppGroup group;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final count = group.actions.length;

    return FCard.raw(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _AppIcon(packageName: group.sourceId),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        group.appName,
                        style: typography.lg.copyWith(
                          color: colors.foreground,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${group.sourceId} · $count action${count == 1 ? '' : 's'}',
                        style: typography.xs.copyWith(
                          color: colors.mutedForeground,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FAccordion(
              children: [
                for (final action in group.actions)
                  FAccordionItem(
                    title: Text(
                      _humanizeActionId(action.actionId),
                      style: typography.sm.copyWith(
                        color: colors.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: _ActionDetails(action: action),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AppIcon extends ConsumerWidget {
  const _AppIcon({required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(appInfoProvider(packageName));
    final colors = context.theme.colors;
    const double size = 44;
    const radius = BorderRadius.all(Radius.circular(10));

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(
        dimension: size,
        child: info.when(
          data: (appInfo) {
            final iconBytes = appInfo?.icon;
            if (iconBytes == null || iconBytes.isEmpty) {
              return _IconFallback(color: colors.mutedForeground);
            }
            return Image.memory(
              iconBytes,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  _IconFallback(color: colors.mutedForeground),
            );
          },
          loading: () => ColoredBox(color: colors.muted),
          error: (_, _) => _IconFallback(color: colors.mutedForeground),
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

class _ActionDetails extends StatelessWidget {
  const _ActionDetails({required this.action});

  final AssistantAction action;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    final examples = action.examples.take(3).toList();
    final requiredParams =
        action.parameters.where((p) => p.required).toList(growable: false);
    final optionalParams =
        action.parameters.where((p) => !p.required).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (action.description.isNotEmpty)
            Text(
              action.description,
              style: typography.sm.copyWith(color: colors.foreground),
            ),
          if (examples.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SectionLabel('Try saying'),
            const SizedBox(height: 6),
            for (final example in examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• “$example”',
                  style:
                      typography.sm.copyWith(color: colors.mutedForeground),
                ),
              ),
          ],
          if (action.parameters.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SectionLabel('Parameters'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in requiredParams) _ParamChip(parameter: p),
                for (final p in optionalParams) _ParamChip(parameter: p),
              ],
            ),
          ],
          const SizedBox(height: 14),
          _SectionLabel('Result'),
          const SizedBox(height: 6),
          Text(
            _resultHint(action),
            style: typography.sm.copyWith(color: colors.mutedForeground),
          ),
          const SizedBox(height: 10),
          Text(
            action.actionId,
            style: typography.xs.copyWith(
              color: colors.mutedForeground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _resultHint(AssistantAction action) {
    if (action.resultTransportType == 'broadcast') {
      return 'The app replies with a result — Hark will speak it back.';
    }
    final msg = action.confirmationMessage.trim();
    if (msg.isEmpty) {
      return 'Fire-and-forget. Hark dispatches the action and moves on.';
    }
    return 'Fire-and-forget. Hark will say: “$msg”.';
  }
}

// ----------------------------------------------------------------------------

class _ParamChip extends StatelessWidget {
  const _ParamChip({required this.parameter});

  final AssistantActionParameter parameter;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    final isRequired = parameter.required;

    final bg = isRequired
        ? colors.primary.withValues(alpha: 0.18)
        : colors.muted;
    final border = isRequired
        ? colors.primary.withValues(alpha: 0.65)
        : colors.border;
    final fg = isRequired ? colors.primary : colors.foreground;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            parameter.name,
            style: typography.xs.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '  ${parameter.type}${isRequired ? ' · required' : ''}',
            style: typography.xs.copyWith(
              color: colors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Text(
      text.toUpperCase(),
      style: typography.xs2.copyWith(
        color: colors.mutedForeground,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.actionCount,
    required this.integrationCount,
  });

  final int actionCount;
  final int integrationCount;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    return Row(
      children: [
        _Stat(
          count: integrationCount,
          label: integrationCount == 1 ? 'app' : 'apps',
        ),
        const SizedBox(width: 12),
        Container(
          width: 1,
          height: 24,
          color: colors.border,
        ),
        const SizedBox(width: 12),
        _Stat(
          count: actionCount,
          label: actionCount == 1 ? 'action' : 'actions',
        ),
        const Spacer(),
        Text(
          'OACP only',
          style: typography.xs.copyWith(color: colors.mutedForeground),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.count, required this.label});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final colors = context.theme.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$count',
          style: typography.xl.copyWith(
            color: colors.foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: typography.xs.copyWith(color: colors.mutedForeground),
        ),
      ],
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
            Icon(
              FIcons.triangleAlert,
              size: 48,
              color: colors.destructive,
            ),
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
