import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'ui_helpers.dart';

/// One row in the issue list.
class IssueTile extends StatelessWidget {
  final Issue issue;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String> onSetState;

  const IssueTile({
    required this.issue,
    required this.selected,
    required this.onTap,
    required this.onSetState,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final delta = issue.delta;
    return Material(
      color: selected
          ? Theme.of(context)
              .colorScheme
              .primaryContainer
              .withOpacity(0.4)
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 74, child: _leadingStats(delta)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      badge(categoryLabel(issue.category),
                          categoryColor(issue.category)),
                      const SizedBox(width: 6),
                      Text(issue.shortId,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                      if (issue.selectedForDev) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                      ],
                      const Spacer(),
                      StatePicker(
                          value: issue.triageState, onChanged: onSetState),
                    ]),
                    const SizedBox(height: 4),
                    Text(issue.title,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (!issue.isFeature && issue.severityScore != null) ...[
                      const SizedBox(height: 4),
                      sevBadge(issue.severityScore!, issue.isAppFixable),
                    ],
                    if (issue.isFeature && issue.feasibility != null) ...[
                      const SizedBox(height: 4),
                      feasBadge(issue.feasibility!, issue.effort),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Left column: event counts for bugs, priority for features.
  Widget _leadingStats(int? delta) {
    if (issue.isFeature) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline, size: 16, color: Colors.indigo),
          if (issue.priorityScore != null)
            Text(tp('priorityShort', {'p': issue.priorityScore}),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(fmt(issue.totalCount),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        if (delta != null && delta != 0)
          Text(
            '${delta > 0 ? '▲' : '▼'}${fmt(delta.abs())}',
            style: TextStyle(
                fontSize: 11, color: delta > 0 ? Colors.red : Colors.green),
          ),
        Text(tp('usersSuffix', {'n': fmt(issue.userCount)}),
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

/// State dropdown: quickly move an issue to keep / hidden / known-noise etc.
class StatePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const StatePicker({required this.value, required this.onChanged, super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: t('setStateTip'),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => kStates
          .map((s) => PopupMenuItem(value: s, child: Text(stateLabel(s))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(stateLabel(value), style: const TextStyle(fontSize: 12)),
          const Icon(Icons.arrow_drop_down, size: 16),
        ]),
      ),
    );
  }
}

/// Category dropdown: reclassify an issue (network noise / log event / app
/// bug…), persisted straight to the DB.
class CategoryPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const CategoryPicker(
      {required this.value, required this.onChanged, super.key});

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(value);
    return PopupMenuButton<String>(
      tooltip: t('setCategoryTip'),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => kCategories
          .map((c) => PopupMenuItem(value: c, child: Text(categoryLabel(c))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(12),
          color: color.withOpacity(0.10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(categoryLabel(value),
              style: TextStyle(fontSize: 12, color: color)),
          Icon(Icons.arrow_drop_down, size: 16, color: color),
        ]),
      ),
    );
  }
}
