import 'package:flutter/material.dart';

import '../models/discovered_app_status.dart';

class DiscoveredAppsScreen extends StatefulWidget {
  final Future<List<DiscoveredAppStatus>> Function() onRefresh;

  const DiscoveredAppsScreen({required this.onRefresh, super.key});

  @override
  State<DiscoveredAppsScreen> createState() => _DiscoveredAppsScreenState();
}

class _DiscoveredAppsScreenState extends State<DiscoveredAppsScreen> {
  List<DiscoveredAppStatus> _apps = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
    });

    final apps = await widget.onRefresh();
    if (!mounted) {
      return;
    }

    setState(() {
      _apps = apps;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discovery Diagnostics'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _apps.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No OACP apps discovered. Install an app that exposes an exported .oacp provider and refresh.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _apps.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final app = _apps[index];
                return Column(
                  children: [
                    if (index == 0)
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'This screen is only for OACP provider diagnostics: package, authority, version, and capability metadata. Use Available Actions to see what Hark can actually execute.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              app.displayName ?? app.appLabel,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              app.packageName,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Authority: ${app.authority}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Version: ${app.versionName.isEmpty ? 'unknown' : app.versionName}'
                              '${app.oacpVersion == null ? '' : ' • OACP ${app.oacpVersion}'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            if (app.isValid) ...[
                              Text(
                                app.capabilities.isEmpty
                                    ? 'No capabilities declared.'
                                    : 'Capabilities: ${app.capabilities.join(', ')}',
                              ),
                            ] else ...[
                              Text(
                                app.error ?? 'Unknown discovery error',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
