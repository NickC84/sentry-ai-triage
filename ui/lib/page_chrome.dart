import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';

/// New / noise counters shown in the app bar.
/// Hand-rolled pills instead of Chip — Material's Chip mis-measures CJK
/// text on Flutter Web and clips the label.
class SummaryPills extends StatelessWidget {
  final Summary summary;
  const SummaryPills({required this.summary, super.key});

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, int n, Color c) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: c.withOpacity(0.12),
              border: Border.all(color: c.withOpacity(0.4)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text('$label $n', style: const TextStyle(fontSize: 12)),
          ),
        );
    final s = summary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      pill(t('chipNew'), s.states['new'] ?? 0, Colors.indigo),
      pill(
          t('chipNoise'),
          (s.states['known_noise'] ?? 0) + (s.states['hidden'] ?? 0),
          Colors.blueGrey),
    ]);
  }
}

/// Bugs / features tab strip under the app bar.
class TriageTabBar extends StatelessWidget {
  final int current;
  final int bugCount;
  final int featureCount;
  final ValueChanged<int> onChanged;
  const TriageTabBar({
    required this.current,
    required this.bugCount,
    required this.featureCount,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    Widget tab(int index, IconData icon, String label, int count) {
      final active = current == index;
      final color =
          active ? Theme.of(context).colorScheme.primary : Colors.grey;
      return InkWell(
        onTap: () => onChanged(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: active ? color : Colors.transparent, width: 2.5),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text('$label　$count',
                style: TextStyle(
                    color: color,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal)),
          ]),
        ),
      );
    }

    return Row(children: [
      tab(0, Icons.bug_report_outlined, t('tabBugs'), bugCount),
      tab(1, Icons.lightbulb_outline, t('tabFeatures'), featureCount),
    ]);
  }
}

/// Full-body error view when the backend can't be reached.
class BackendErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const BackendErrorView(
      {required this.error, required this.onRetry, super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
        const SizedBox(height: 12),
        Text(tp('backendDown', {'e': error}), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(t('backendHint'), style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        FilledButton(onPressed: onRetry, child: Text(t('retry'))),
      ]),
    );
  }
}
