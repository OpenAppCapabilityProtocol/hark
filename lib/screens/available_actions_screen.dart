import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/assistant_action.dart';
import '../state/registry_provider.dart';

class AvailableActionsScreen extends ConsumerStatefulWidget {
  const AvailableActionsScreen({super.key});

  @override
  ConsumerState<AvailableActionsScreen> createState() =>
      _AvailableActionsScreenState();
}

class _AvailableActionsScreenState
    extends ConsumerState<AvailableActionsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(capabilityRegistryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Available Actions')),
      body: registry.when(
        data: (registry) => _buildBody(context, registry.actions),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load capabilities:\n$error'),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<AssistantAction> actions) {
    final groups = _buildOacpGroups(actions, _searchQuery);

    if (actions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No OACP actions are currently available.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _IntroCard(
          actionCount: actions.length,
          integrationCount: groups.length,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            hintText: 'Filter by app, package, action, or description...',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (value) {
            setState(() {
              _searchQuery = value.trim().toLowerCase();
            });
          },
        ),
        const SizedBox(height: 16),
        const _SectionTitle(
          title: 'OACP Integrations',
          subtitle:
              'This is Hark’s executable OACP catalog. The dedicated diagnostics screen has been removed — this view is authoritative.',
        ),
        const SizedBox(height: 12),
        if (groups.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No OACP actions match the current filter.'),
            ),
          )
        else
          ...groups.map((group) => _ActionGroupCard(group: group)),
      ],
    );
  }

  List<_ActionGroup> _buildOacpGroups(
    List<AssistantAction> actions,
    String query,
  ) {
    final grouped = <String, List<AssistantAction>>{};

    for (final action in actions) {
      if (action.sourceType != AssistantActionSourceType.oacp) {
        continue;
      }
      if (!_matchesQuery(action, query)) {
        continue;
      }
      grouped.putIfAbsent(action.sourceId, () => []).add(action);
    }

    final groups = grouped.entries
        .map((entry) {
          final groupActions = entry.value
            ..sort((left, right) => left.actionId.compareTo(right.actionId));
          final first = groupActions.first;
          return _ActionGroup(
            title: first.displayName,
            subtitle:
                '${groupActions.length} executable action'
                '${groupActions.length == 1 ? '' : 's'}',
            sourceId: entry.key,
            actions: groupActions,
          );
        })
        .toList(growable: false);

    groups.sort((left, right) => left.title.compareTo(right.title));
    return groups;
  }

  bool _matchesQuery(AssistantAction action, String query) {
    if (query.isEmpty) {
      return true;
    }

    final haystack = [
      action.displayName,
      action.sourceId,
      action.actionId,
      action.description,
      ...action.parameters.map((parameter) => parameter.name),
    ].join(' ').toLowerCase();

    return haystack.contains(query);
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.actionCount, required this.integrationCount});

  final int actionCount;
  final int integrationCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What Hark Can Do',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CountChip(
                  label:
                      '$actionCount OACP action'
                      '${actionCount == 1 ? '' : 's'}',
                ),
                _CountChip(
                  label:
                      '$integrationCount integrated app'
                      '${integrationCount == 1 ? '' : 's'}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Hark only lists third-party OACP integrations here. Generic phone actions and app launching are intentionally out of scope.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text(label), visualDensity: VisualDensity.compact);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ActionGroupCard extends StatelessWidget {
  const _ActionGroupCard({required this.group});

  final _ActionGroup group;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(group.title),
        subtitle: Text(group.subtitle),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              group.sourceId,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 12),
          ...group.actions.map((action) => _ActionTile(action: action)),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action});

  final AssistantAction action;

  @override
  Widget build(BuildContext context) {
    final parameterSummary = action.parameters.isEmpty
        ? 'No parameters'
        : action.parameters
              .map(
                (parameter) => parameter.required
                    ? '${parameter.name} (${parameter.type}, required)'
                    : '${parameter.name} (${parameter.type})',
              )
              .join(', ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(action.actionId, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(action.description),
          const SizedBox(height: 6),
          Text(
            'Parameters: $parameterSummary',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ActionGroup {
  const _ActionGroup({
    required this.title,
    required this.subtitle,
    required this.sourceId,
    required this.actions,
  });

  final String title;
  final String subtitle;
  final String sourceId;
  final List<AssistantAction> actions;
}
