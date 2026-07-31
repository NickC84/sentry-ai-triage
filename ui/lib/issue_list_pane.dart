import 'package:flutter/material.dart';

import 'i18n.dart';
import 'issue_tile.dart';
import 'models.dart';
import 'ui_helpers.dart';

/// Left pane: search / filter / sort header plus the issue list itself.
/// Pure presentation — filtering and sorting happen in the parent.
class IssueListPane extends StatelessWidget {
  final List<Issue> issues;
  final bool showFirstRunHint;
  final String? selectedId;
  final String? categoryFilter;
  final bool sortByPriority;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onCategoryFilter;
  final ValueChanged<bool> onSortByPriority;
  final ValueChanged<Issue> onSelect;
  final void Function(Issue issue, String state) onSetIssueState;

  const IssueListPane({
    required this.issues,
    required this.showFirstRunHint,
    required this.selectedId,
    required this.categoryFilter,
    required this.sortByPriority,
    required this.onSearch,
    required this.onCategoryFilter,
    required this.onSortByPriority,
    required this.onSelect,
    required this.onSetIssueState,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _header(context),
      const Divider(height: 1),
      Expanded(
        child: issues.isEmpty
            ? Center(
                child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    showFirstRunHint ? t('emptyListFirstRun') : t('emptyList'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ))
            : ListView.separated(
                itemCount: issues.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final issue = issues[i];
                  return IssueTile(
                    issue: issue,
                    selected: selectedId == issue.id,
                    onTap: () => onSelect(issue),
                    onSetState: (s) => onSetIssueState(issue, s),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 38,
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: t('searchHint'),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: onSearch,
            ),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String?>(
          value: categoryFilter,
          hint: Text(t('allCategories')),
          underline: const SizedBox.shrink(),
          items: [
            DropdownMenuItem(value: null, child: Text(t('allCategories'))),
            ...kCategories.map((c) =>
                DropdownMenuItem(value: c, child: Text(categoryLabel(c)))),
          ],
          onChanged: onCategoryFilter,
        ),
        const SizedBox(width: 8),
        Text(t('sort'),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 4),
        _sortChip(context, t('sortCount'), !sortByPriority,
            () => onSortByPriority(false)),
        const SizedBox(width: 4),
        _sortChip(context, t('sortPriority'), sortByPriority,
            () => onSortByPriority(true)),
        const SizedBox(width: 8),
        Text(tp('itemsCount', {'n': issues.length}),
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ]),
    );
  }

  // Custom toggle pill — Material's ChoiceChip mis-measures CJK text on
  // Flutter Web and clips the label.
  Widget _sortChip(
      BuildContext context, String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? cs.secondaryContainer : null,
          border: Border.all(
              color: selected ? cs.secondaryContainer : Colors.grey.shade400),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected) ...[
            Icon(Icons.check, size: 14, color: cs.onSecondaryContainer),
            const SizedBox(width: 4),
          ],
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}
