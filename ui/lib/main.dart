// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';

import 'api.dart';
import 'i18n.dart';
import 'models.dart';

void main() => runApp(const TriageApp());

/// Flutter Web only: open a link in a new tab (Sentry / GitHub).
void _openUrl(String url) => html.window.open(url, '_blank');

class TriageApp extends StatelessWidget {
  const TriageApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole tree when the locale toggles. TriagePage must NOT be
    // const here — a const child is skipped on rebuild, which would freeze
    // the language.
    return ValueListenableBuilder<String>(
      valueListenable: I18n.locale,
      builder: (_, __, ___) => MaterialApp(
        title: t('appTitle'),
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          visualDensity: VisualDensity.compact,
        ),
        // ignore: prefer_const_constructors
        home: TriagePage(),
      ),
    );
  }
}

// ── Display helpers for category / state / severity ───────────────

const _categories = [
  'app_bug',
  'device_layer',
  'network_noise',
  'log_event',
  'feature',
  'unknown',
];
const _states = ['new', 'keep', 'hidden', 'known_noise', 'resolved'];

/// Localized label with graceful fallback for values outside the known set.
String _lookup(String prefix, String value) {
  final s = t('$prefix$value');
  return s == '$prefix$value' ? value : s;
}

String _categoryLabel(String c) => _lookup('cat_', c);
String _stateLabel(String s) => _lookup('st_', s);
String _fixLabel(String? f) => f == null ? '—' : _lookup('fix_', f);
String _feasLabel(String f) => _lookup('feas_', f);

Color _categoryColor(String c) => switch (c) {
      'device_layer' => Colors.brown,
      'network_noise' => Colors.blueGrey,
      'log_event' => Colors.teal,
      'app_bug' => Colors.red,
      'feature' => Colors.indigo,
      _ => Colors.grey,
    };

Color _feasColor(String? f) => switch (f) {
      'feasible' => Colors.green,
      'hard' => Colors.orange,
      'blocked' => Colors.red,
      _ => Colors.grey,
    };

Color _sevColor(int s) =>
    s >= 70 ? Colors.red : (s >= 40 ? Colors.orange : Colors.green);

/// Small severity badge used in the list and detail panel.
Widget _sevBadge(int score, String? fixable) {
  final c = _sevColor(score);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: c.withOpacity(0.14),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text('${tp('sevPrefix', {'s': score})} · ${_fixLabel(fixable)}',
        style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
  );
}

/// Feasibility badge for feature items.
Widget _feasBadge(String feasibility, String? effort) {
  final c = _feasColor(feasibility);
  final e = effort == null ? '' : tp('effortPrefix', {'e': effort});
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: c.withOpacity(0.14),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text('${_feasLabel(feasibility)}$e',
        style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
  );
}

class TriagePage extends StatefulWidget {
  const TriagePage({super.key});
  @override
  State<TriagePage> createState() => _TriagePageState();
}

class _TriagePageState extends State<TriagePage> {
  final _api = TriageApi();
  bool _includeNoise = false;
  bool _loading = true;
  String? _error;
  List<Issue> _issues = [];
  Summary? _summary;
  Issue? _selected;
  String _search = '';
  String? _categoryFilter; // null = all categories
  bool _sortByPriority = false; // false = by count (backend order)
  int _tab = 0; // 0 = bugs (Sentry), 1 = features

  bool get _featureTab => _tab == 1;

  @override
  void initState() {
    super.initState();
    _load();
    _syncOutputLanguage();
  }

  /// Keep the backend's AI output language (analysis, ticket bodies, PR
  /// text) in lockstep with the UI language — no separate setting to forget.
  void _syncOutputLanguage() {
    _api
        .saveConfig({'OUTPUT_LANGUAGE': I18n.isZh ? 'zh-Hant' : 'en'})
        .catchError((_) {}); // backend may be down; the UI still works
  }

  int get _bugCount => _issues.where((i) => !i.isFeature).length;
  int get _featureCount => _issues.where((i) => i.isFeature).length;

  /// List after applying tab (bug/feature), search, category filter and sort.
  List<Issue> get _filteredIssues {
    final q = _search.trim().toLowerCase();
    final list = _issues.where((i) {
      if (i.isFeature != _featureTab) return false;
      if (_categoryFilter != null && i.category != _categoryFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return i.title.toLowerCase().contains(q) ||
          i.shortId.toLowerCase().contains(q) ||
          i.culprit.toLowerCase().contains(q);
    }).toList();

    if (_sortByPriority) {
      // Unified AI priority (bugs and features mixed); unanalyzed items sink
      // to the bottom, ordered by event count.
      list.sort((a, b) {
        final pa = a.priority, pb = b.priority;
        if (pa == null && pb == null) {
          return b.totalCount.compareTo(a.totalCount);
        }
        if (pa == null) return 1;
        if (pb == null) return -1;
        final c = pb.compareTo(pa);
        return c != 0 ? c : b.totalCount.compareTo(a.totalCount);
      });
    }
    // By count: keep backend order (total_count DESC; features have no count
    // and naturally sink).
    return list;
  }

  /// [silent] skips the full-page loading state so the detail panel isn't
  /// destroyed (losing its state); used for background refreshes after
  /// triage/select/analyze/ticket actions.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final summary = await _api.summary();
      final issues = await _api.issues(includeNoise: _includeNoise);
      setState(() {
        _summary = summary;
        _issues = issues;
        _loading = false;
        // Re-point the selection at the freshly loaded object (with the
        // latest analysis/select/ticket state); clear it if it's gone.
        // Keeping the old object would revert just-updated state.
        if (_selected != null) {
          final match = issues.where((i) => i.id == _selected!.id);
          _selected = match.isEmpty ? null : match.first;
        }
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _snack(String msg, {int seconds = 4}) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: Duration(seconds: seconds)));
  }

  Future<void> _updateTriage(Issue issue,
      {String? state, String? category}) async {
    try {
      await _api.updateTriage(issue.id, state: state, category: category);
      if (mounted) {
        final label = state != null
            ? _stateLabel(state)
            : _categoryLabel(category ?? '');
        _snack('${issue.shortId} → $label', seconds: 1);
      }
      await _load();
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    }
  }

  bool _syncing = false;

  Future<void> _syncGithub() async {
    setState(() => _syncing = true);
    try {
      final n = await _api.syncGithub();
      await _load(silent: true);
      if (mounted) _snack(tp('syncedN', {'n': n}));
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  bool _ingesting = false;

  Future<void> _runIngest() async {
    setState(() => _ingesting = true);
    try {
      final res = await _api.ingest();
      await _load(silent: true);
      if (mounted) _snack(tp('ingestDone', {'n': res['fetched'] ?? 0}));
    } catch (e) {
      if (mounted) _snack(tp('ingestFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _ingesting = false);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SettingsPage(api: _api)));
    _load(silent: true);
  }

  Future<void> _deleteIssue(Issue issue) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('deleteFeatureTitle')),
        content: Text(tp('deleteFeatureBody', {'t': issue.title})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('cancel'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteIssue(issue.id);
      setState(() => _selected = null);
      await _load(silent: true);
      if (mounted) _snack(t('deleted'));
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    }
  }

  Future<void> _newFeatureDialog() async {
    final titleCtl = TextEditingController();
    final detailCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('newFeatureTitle')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: titleCtl,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t('featureTitleLabel'),
                  hintText: t('featureTitleHint')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: detailCtl,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: t('featureDetailLabel'),
                hintText: t('featureDetailHint'),
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('add'))),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtl.text.trim();
    if (title.isEmpty) return;
    try {
      final id = await _api.createFeature(title, detailCtl.text.trim());
      setState(() => _tab = 1); // switch to the features tab to show it
      await _load();
      final created = _issues.where((i) => i.id == id);
      if (created.isNotEmpty) setState(() => _selected = created.first);
      if (mounted) _snack(t('featureCreated'), seconds: 2);
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('appTitle')),
        actions: [
          if (_summary != null) ..._summaryChips(_summary!),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: _newFeatureDialog,
            icon: const Icon(Icons.add, size: 18),
            label: Text(t('newFeature')),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _ingesting ? null : _runIngest,
            icon: _ingesting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_download_outlined, size: 18),
            label: Text(_ingesting ? t('ingesting') : t('syncFromSentry')),
          ),
          TextButton.icon(
            onPressed: _syncing ? null : _syncGithub,
            icon: _syncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync, size: 18),
            label: Text(_syncing ? t('syncing') : t('syncStatus')),
          ),
          const SizedBox(width: 16),
          Text(t('showNoise')),
          Switch(
            value: _includeNoise,
            onChanged: (v) {
              setState(() => _includeNoise = v);
              _load();
            },
          ),
          IconButton(
            tooltip: t('refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: t('settings'),
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          TextButton(
            onPressed: () {
              I18n.toggle();
              _syncOutputLanguage();
            },
            child: Text(I18n.isZh ? 'EN' : '中'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        _tabBar(),
        const Divider(height: 1),
        Expanded(child: _buildBody()),
      ]),
    );
  }

  Widget _tabBar() {
    Widget tab(int index, IconData icon, String label, int count) {
      final active = _tab == index;
      final color =
          active ? Theme.of(context).colorScheme.primary : Colors.grey;
      return InkWell(
        onTap: () => setState(() {
          _tab = index;
          _selected = null; // clear selection so the other tab's detail hides
        }),
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
      tab(0, Icons.bug_report_outlined, t('tabBugs'), _bugCount),
      tab(1, Icons.lightbulb_outline, t('tabFeatures'), _featureCount),
    ]);
  }

  // Hand-rolled pills instead of Chip — Material's Chip mis-measures CJK
  // text on Flutter Web and clips the label.
  List<Widget> _summaryChips(Summary s) {
    Widget chip(String label, int n, Color c) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: c.withOpacity(0.12),
              border: Border.all(color: c.withOpacity(0.4)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text('$label $n', style: const TextStyle(fontSize: 12)),
          ),
        );
    return [
      chip(t('chipNew'), s.states['new'] ?? 0, Colors.indigo),
      chip(
          t('chipNoise'),
          (s.states['known_noise'] ?? 0) + (s.states['hidden'] ?? 0),
          Colors.blueGrey),
    ];
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(tp('backendDown', {'e': _error}), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(t('backendHint'), style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          FilledButton(onPressed: _load, child: Text(t('retry'))),
        ]),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 6, child: _issueList()),
        const VerticalDivider(width: 1),
        Expanded(flex: 5, child: _detailPanel()),
      ],
    );
  }

  Widget _issueList() {
    final filtered = _filteredIssues;
    return Column(children: [
      _listHeader(filtered.length),
      const Divider(height: 1),
      Expanded(
        child: filtered.isEmpty
            ? Center(
                child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    _issues.isEmpty ? t('emptyListFirstRun') : t('emptyList'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ))
            : ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final issue = filtered[i];
                  return _IssueTile(
                    issue: issue,
                    selected: _selected?.id == issue.id,
                    onTap: () => setState(() => _selected = issue),
                    onSetState: (s) => _updateTriage(issue, state: s),
                  );
                },
              ),
      ),
    ]);
  }

  // Custom toggle pill (see _summaryChips for why this isn't a ChoiceChip).
  Widget _sortChip(String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(onTap),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? cs.secondaryContainer : null,
          border: Border.all(
              color:
                  selected ? cs.secondaryContainer : Colors.grey.shade400),
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

  Widget _listHeader(int shown) {
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
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String?>(
          value: _categoryFilter,
          hint: Text(t('allCategories')),
          underline: const SizedBox.shrink(),
          items: [
            DropdownMenuItem(value: null, child: Text(t('allCategories'))),
            ..._categories.map((c) =>
                DropdownMenuItem(value: c, child: Text(_categoryLabel(c)))),
          ],
          onChanged: (v) => setState(() => _categoryFilter = v),
        ),
        const SizedBox(width: 8),
        Text(t('sort'),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 4),
        _sortChip(t('sortCount'), !_sortByPriority,
            () => _sortByPriority = false),
        const SizedBox(width: 4),
        _sortChip(t('sortPriority'), _sortByPriority,
            () => _sortByPriority = true),
        const SizedBox(width: 8),
        Text(tp('itemsCount', {'n': shown}),
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ]),
    );
  }

  Widget _detailPanel() {
    final issue = _selected;
    if (issue == null) {
      return Center(
          child: Text(t('detailPlaceholder'),
              style: const TextStyle(color: Colors.grey)));
    }
    return IssueDetail(
      api: _api,
      issue: issue,
      key: ValueKey(issue.id),
      onUpdateCategory: (c) => _updateTriage(issue, category: c),
      onUpdateState: (s) => _updateTriage(issue, state: s),
      onAnalyzed: () => _load(silent: true),
      onDelete: () => _deleteIssue(issue),
    );
  }
}

// ── One row in the issue list ─────────────────────────────────────
class _IssueTile extends StatelessWidget {
  final Issue issue;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String> onSetState;

  const _IssueTile({
    required this.issue,
    required this.selected,
    required this.onTap,
    required this.onSetState,
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
              SizedBox(
                width: 74,
                child: issue.isFeature
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.lightbulb_outline,
                              size: 16, color: Colors.indigo),
                          if (issue.priorityScore != null)
                            Text(tp('priorityShort', {'p': issue.priorityScore}),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_fmt(issue.totalCount),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          if (delta != null && delta != 0)
                            Text(
                              '${delta > 0 ? '▲' : '▼'}${_fmt(delta.abs())}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      delta > 0 ? Colors.red : Colors.green),
                            ),
                          Text(tp('usersSuffix', {'n': _fmt(issue.userCount)}),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      _badge(_categoryLabel(issue.category),
                          _categoryColor(issue.category)),
                      const SizedBox(width: 6),
                      Text(issue.shortId,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                      if (issue.selectedForDev) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                      ],
                      const Spacer(),
                      _StatePicker(
                          value: issue.triageState, onChanged: onSetState),
                    ]),
                    const SizedBox(height: 4),
                    Text(issue.title,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (!issue.isFeature && issue.severityScore != null) ...[
                      const SizedBox(height: 4),
                      _sevBadge(issue.severityScore!, issue.isAppFixable),
                    ],
                    if (issue.isFeature && issue.feasibility != null) ...[
                      const SizedBox(height: 4),
                      _feasBadge(issue.feasibility!, issue.effort),
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
}

Widget _badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );

/// State dropdown: quickly move an issue to keep / hidden / known-noise etc.
class _StatePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _StatePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: t('setStateTip'),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => _states
          .map((s) => PopupMenuItem(value: s, child: Text(_stateLabel(s))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_stateLabel(value), style: const TextStyle(fontSize: 12)),
          const Icon(Icons.arrow_drop_down, size: 16),
        ]),
      ),
    );
  }
}

/// Category dropdown: reclassify an issue (network noise / log event / app
/// bug…), persisted straight to the DB.
class _CategoryPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _CategoryPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(value);
    return PopupMenuButton<String>(
      tooltip: t('setCategoryTip'),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => _categories
          .map((c) => PopupMenuItem(value: c, child: Text(_categoryLabel(c))))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.6)),
          borderRadius: BorderRadius.circular(12),
          color: color.withOpacity(0.10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_categoryLabel(value),
              style: TextStyle(fontSize: 12, color: color)),
          Icon(Icons.arrow_drop_down, size: 16, color: color),
        ]),
      ),
    );
  }
}

// ── Detail panel + per-release frequency ──────────────────────────
class IssueDetail extends StatefulWidget {
  final TriageApi api;
  final Issue issue;
  final ValueChanged<String> onUpdateCategory;
  final ValueChanged<String> onUpdateState;
  final VoidCallback onAnalyzed;
  final VoidCallback onDelete;
  const IssueDetail({
    required this.api,
    required this.issue,
    required this.onUpdateCategory,
    required this.onUpdateState,
    required this.onAnalyzed,
    required this.onDelete,
    super.key,
  });
  @override
  State<IssueDetail> createState() => _IssueDetailState();
}

class _IssueDetailState extends State<IssueDetail> {
  late Future<List<ReleaseStat>> _releases;
  late Issue _issue;
  bool _analyzing = false;

  @override
  void initState() {
    super.initState();
    _issue = widget.issue;
    _releases = widget.api.releases(widget.issue.id);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _runAnalyze() async {
    setState(() => _analyzing = true);
    try {
      final a = await widget.api.analyze(_issue.id);
      setState(() => _issue = _issue.withAnalysis(a));
      widget.onAnalyzed(); // refresh badges in the list on the left
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _issue;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _badge(_categoryLabel(i.category), _categoryColor(i.category)),
            const SizedBox(width: 8),
            Text(i.shortId, style: const TextStyle(color: Colors.grey)),
            const Spacer(),
            if (i.permalink.isNotEmpty)
              TextButton.icon(
                onPressed: () => _openUrl(i.permalink),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Sentry'),
              ),
            _ticketButton(i),
            if (i.isFeature)
              IconButton(
                tooltip: t('delete'),
                onPressed: widget.onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                color: Colors.red,
              ),
          ]),
          const SizedBox(height: 8),
          SelectableText(i.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          if (!i.isFeature && i.culprit.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(i.culprit,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontFamily: 'monospace')),
          ],
          if (i.isFeature && (i.detail ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(i.detail!, style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 12),
          // Manual triage: change category / state, written straight to DB.
          Row(children: [
            Text(t('categoryLabel'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            _CategoryPicker(
                value: i.category, onChanged: widget.onUpdateCategory),
            const SizedBox(width: 16),
            Text(t('stateLabel'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            _StatePicker(value: i.triageState, onChanged: widget.onUpdateState),
          ]),
          if (i.triageNote != null && i.triageNote!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(tp('noteLabel', {'n': i.triageNote}),
                style: const TextStyle(fontStyle: FontStyle.italic)),
          ],
          if (i.isFeature) ...[
            const SizedBox(height: 8),
            // "Selected for dev" is read-only here; it flips when a ticket
            // is opened (never toggled by hand).
            Row(children: [
              Icon(
                i.selectedForDev
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                size: 20,
                color: i.selectedForDev ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  i.selectedForDev ? t('selectedDevYes') : t('selectedDevNo'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            _featureSection(i),
          ] else ...[
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 4, children: [
              _meta(t('metaTotal'), _fmt(i.totalCount)),
              _meta(t('metaUsers'), _fmt(i.userCount)),
              _meta(t('metaLevel'), i.level),
              _meta(t('metaFirst'), _date(i.firstSeen)),
              _meta(t('metaLast'), _date(i.lastSeen)),
            ]),
            const SizedBox(height: 16),
            _aiSection(i),
            const Divider(height: 32),
            Text(t('releaseFreq'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            FutureBuilder<List<ReleaseStat>>(
              future: _releases,
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()));
                }
                if (snap.hasError) {
                  return Text(tp('releaseError', {'e': snap.error}));
                }
                final rs = snap.data ?? [];
                if (rs.isEmpty) {
                  return Text(t('releaseEmpty'),
                      style: const TextStyle(color: Colors.grey));
                }
                return _ReleaseBars(stats: rs);
              },
            ),
          ],
        ],
      ),
    );
  }

  bool _ticketing = false;

  Widget _ticketButton(Issue i) {
    if (i.ticketUrl != null) {
      final s = i.ticketState;
      final deleted = s == 'deleted';
      // Once ticketed, this button is the entry point to the GitHub issue:
      // discuss with @claude, confirm the spec, then have it implement.
      final label = switch (s) {
        'closed' => t('ticketClosed'),
        'deleted' => t('ticketDeleted'),
        _ => t('ticketGo'),
      };
      final icon = switch (s) {
        'deleted' => Icons.error_outline,
        'closed' => Icons.check_circle,
        _ => Icons.forum_outlined,
      };
      final color = switch (s) {
        'deleted' => Colors.red,
        'closed' => Colors.grey,
        _ => Colors.indigo,
      };
      return Tooltip(
        message: deleted ? t('ticketDeleted') : t('ticketGoTip'),
        child: TextButton.icon(
          onPressed: deleted ? null : () => _openUrl(i.ticketUrl!),
          icon: Icon(icon, size: 16, color: color),
          label: Text(label),
        ),
      );
    }
    // No ticket before analysis — avoids opening half-empty tickets.
    if (!i.analyzed) {
      return Tooltip(
        message: i.isFeature ? t('ticketNeedFeature') : t('ticketNeedBug'),
        child: TextButton.icon(
          onPressed: null,
          icon: const Icon(Icons.add_task, size: 16),
          label: Text(t('ticketCreate')),
        ),
      );
    }
    return Tooltip(
      message: t('ticketCreateTip'),
      child: TextButton.icon(
        onPressed: _ticketing ? null : _runOpenTicket,
        icon: _ticketing
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_task, size: 16),
        label: Text(t('ticketCreate')),
      ),
    );
  }

  Future<void> _runOpenTicket() async {
    setState(() => _ticketing = true);
    try {
      final res = await widget.api.openTicket(_issue.id);
      final url = res['ticket_url']?.toString();
      if (url != null) {
        // Opening a ticket auto-selects the item for dev.
        setState(() => _issue = _issue.withTicket(url).withSelected(true));
      }
      widget.onAnalyzed();
      if (mounted) {
        final msg = res['already'] == true
            ? t('ticketAlready')
            : (res['claude_started'] == true
                ? t('ticketOpened')
                : t('ticketOpenedNoComment'));
        _snack(msg);
      }
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _ticketing = false);
    }
  }

  Future<void> _runFeatureAnalyze() async {
    setState(() => _analyzing = true);
    try {
      final a = await widget.api.analyzeFeature(_issue.id);
      setState(() => _issue = _issue.withFeatureAnalysis(a));
      widget.onAnalyzed();
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Widget _featureSection(Issue i) {
    final analyzed = i.feasibility != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(t('featureSection'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _analyzing ? null : _runFeatureAnalyze,
              icon: _analyzing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome, size: 16),
              label: Text(_analyzing
                  ? t('aiAnalyzing')
                  : (analyzed ? t('aiReanalyze') : t('featureAnalyze'))),
            ),
          ]),
          if (_analyzing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('featureWait'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else if (!analyzed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('featureNotYet'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else ...[
            const SizedBox(height: 10),
            Row(children: [
              _feasBadge(i.feasibility!, i.effort),
              const SizedBox(width: 8),
              if (i.priorityScore != null)
                Text(tp('suggestedPriority', {'p': i.priorityScore}),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(width: 8),
              if (i.confidence != null)
                Text(tp('confidence', {'p': (i.confidence! * 100).round()}),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
            if ((i.rootCauseSummary ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              _aiField(t('summaryField'), i.rootCauseSummary!),
            ],
            if ((i.affectedAreas ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              _aiField(t('affected'), i.affectedAreas!),
            ],
            if ((i.recommendedAction ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              _aiField(t('approach'), i.recommendedAction!),
            ],
            if ((i.risks ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              _aiField(t('risks'), i.risks!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _meta(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(k, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      );

  Widget _aiSection(Issue i) {
    final analyzed = i.severityScore != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(t('aiSection'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            const Spacer(),
            FilledButton.tonalIcon(
              onPressed: _analyzing ? null : _runAnalyze,
              icon: _analyzing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome, size: 16),
              label: Text(_analyzing
                  ? t('aiAnalyzing')
                  : (analyzed ? t('aiReanalyze') : t('aiAnalyze'))),
            ),
          ]),
          if (_analyzing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('aiWaitBug'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else if (!analyzed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('aiNotYetBug'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else ...[
            const SizedBox(height: 10),
            Row(children: [
              _sevBadge(i.severityScore!, i.isAppFixable),
              const SizedBox(width: 8),
              if (i.confidence != null)
                Text(tp('confidence', {'p': (i.confidence! * 100).round()}),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
            if (i.rootCauseSummary != null &&
                i.rootCauseSummary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              _aiField(t('rootCause'), i.rootCauseSummary!),
            ],
            if (i.recommendedAction != null &&
                i.recommendedAction!.isNotEmpty) ...[
              const SizedBox(height: 6),
              _aiField(t('recommended'), i.recommendedAction!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _aiField(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          SelectableText(v, style: const TextStyle(fontSize: 13)),
        ],
      );
}

// ── Help / user guide page ────────────────────────────────────────
/// Explains what every feature and button does, in the UI language.
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const _sections = [
    ['helpFlowTitle', 'helpFlowBody'],
    ['helpIngestTitle', 'helpIngestBody'],
    ['helpNoiseTitle', 'helpNoiseBody'],
    ['helpAnalyzeTitle', 'helpAnalyzeBody'],
    ['helpFeatureTitle', 'helpFeatureBody'],
    ['helpTicketTitle', 'helpTicketBody'],
    ['helpPrTitle', 'helpPrBody'],
    ['helpSyncTitle', 'helpSyncBody'],
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('helpTitle'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: _sections.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(_sections[i][0]),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 6),
                  Text(t(_sections[i][1]),
                      style: const TextStyle(fontSize: 13, height: 1.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Settings page ─────────────────────────────────────────────────
/// Edits everything in [Config.editableKeys] via /api/config. Secrets come
/// back masked; leaving them masked keeps the stored value.
class SettingsPage extends StatefulWidget {
  final TriageApi api;
  const SettingsPage({required this.api, super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _ctls = <String, TextEditingController>{};
  String _aiMode = 'claude_cli';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // Sentry org/project discovery state.
  bool _detecting = false;
  List<dynamic>? _discovered;

  static const _textKeys = [
    'SENTRY_BASE_URL',
    'SENTRY_ORG',
    'SENTRY_PROJECT',
    'SENTRY_TOKEN',
    'STATS_PERIOD_DAYS',
    'AI_MODEL',
    'ANTHROPIC_API_KEY',
    'CLI_COMMAND',
    'APP_CONTEXT',
    'AI_MIN_EVENTS',
    'AI_MAX_ISSUES',
    'APP_REPO_PATH',
    'GITHUB_REPO',
    'GITHUB_TOKEN',
    'PR_MODEL',
    'GIT_REMOTE',
  ];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.getConfig();
      final cfg = (res['config'] as Map<String, dynamic>? ?? {});
      for (final k in _textKeys) {
        _ctls[k] = TextEditingController(text: (cfg[k] ?? '').toString());
      }
      _aiMode = (cfg['AI_MODE'] ?? 'claude_cli').toString();
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = tp('settingsLoadFail', {'e': e});
        _loading = false;
      });
    }
  }

  /// Fill the slug fields from discovery and persist right away — no extra
  /// "save" step for the common path.
  Future<void> _fillAndSave(String org, String project) async {
    setState(() {
      _ctls['SENTRY_ORG']!.text = org;
      _ctls['SENTRY_PROJECT']!.text = project;
    });
    await _save(successMsg: tp('settingsAutoFilled', {'p': '$org / $project'}));
  }

  Future<void> _save({String? successMsg}) async {
    setState(() => _saving = true);
    try {
      final values = <String, String>{
        for (final k in _textKeys) k: _ctls[k]!.text.trim(),
        'AI_MODE': _aiMode,
      };
      await widget.api.saveConfig(values);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(successMsg ?? t('settingsSaved'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tp('settingsSaveFail', {'e': e}))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Call the backend to list orgs/projects for the pasted token, then let
  /// the user tap to fill the slug fields.
  Future<void> _detect() async {
    final token = _ctls['SENTRY_TOKEN']!.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('settingsDetectHint'))));
      return;
    }
    setState(() {
      _detecting = true;
      _discovered = null;
    });
    try {
      final orgs = await widget.api.discoverSentry(
        token: token,
        sentryBaseUrl: _ctls['SENTRY_BASE_URL']!.text.trim(),
      );
      setState(() => _discovered = orgs);
      // Exactly one org/project pair → no choice to make, fill & save it.
      final pairs = <List<String>>[
        for (final o in orgs)
          for (final p
              in ((o as Map<String, dynamic>)['projects'] as List<dynamic>? ??
                  []))
            [o['org'].toString(), p.toString()]
      ];
      if (pairs.length == 1) {
        await _fillAndSave(pairs.first[0], pairs.first[1]);
      } else if (orgs.isEmpty && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t('settingsDetectEmpty'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tp('genericFail', {'e': e}))));
      }
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  /// Tap-to-fill chips for every discovered org/project pair.
  Widget _discoveredPicker() {
    final orgs = _discovered;
    if (orgs == null || orgs.isEmpty) return const SizedBox.shrink();
    final chips = <Widget>[];
    for (final o in orgs) {
      final org = (o as Map<String, dynamic>)['org'].toString();
      final projects = (o['projects'] as List<dynamic>? ?? []);
      if (projects.isEmpty) {
        chips.add(OutlinedButton(
          onPressed: () =>
              setState(() => _ctls['SENTRY_ORG']!.text = org),
          child: Text(org),
        ));
      }
      for (final p in projects) {
        chips.add(OutlinedButton.icon(
          icon: const Icon(Icons.bolt, size: 16),
          label: Text('$org / $p'),
          onPressed: () => _fillAndSave(org, p.toString()),
        ));
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('settingsDetectPick'),
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }

  Widget _field(String key, String label,
      {bool secret = false, int maxLines = 1, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _ctls[key],
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: secret ? t('settingsSecretHint') : null,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 10),
            child: Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          ...children,
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('settingsTitle')),
        actions: [
          FilledButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(t('settingsSave')),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: _loadConfig, child: Text(t('retry'))),
                ]))
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.menu_book_outlined),
                            title: Text(t('settingsHelp')),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const HelpPage())),
                          ),
                        ),
                        _section(t('settingsSentry'), [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () {
                                  final base = _ctls['SENTRY_BASE_URL']!
                                      .text
                                      .trim();
                                  _openUrl(
                                      '${base.isEmpty ? 'https://sentry.io' : base}/settings/account/api/auth-tokens/');
                                },
                                icon: const Icon(Icons.open_in_new, size: 16),
                                label: Text(t('settingsGetToken')),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text(t('settingsTokenSteps'),
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                          ),
                          _field('SENTRY_TOKEN', t('settingsToken'),
                              secret: true),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _detecting ? null : _detect,
                                icon: _detecting
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.travel_explore,
                                        size: 16),
                                label: Text(_detecting
                                    ? t('settingsDetecting')
                                    : t('settingsDetect')),
                              ),
                            ),
                          ),
                          _discoveredPicker(),
                          _field('SENTRY_ORG', t('settingsOrg')),
                          _field('SENTRY_PROJECT', t('settingsProject')),
                          _field('SENTRY_BASE_URL', t('settingsSentryBase')),
                          _field('STATS_PERIOD_DAYS', t('settingsPeriod')),
                        ]),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(t('settingsAdvanced'),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          childrenPadding: EdgeInsets.zero,
                          expandedCrossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                        _section(t('settingsAi'), [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: DropdownButtonFormField<String>(
                              value: _aiMode,
                              decoration: InputDecoration(
                                labelText: t('settingsAiMode'),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                DropdownMenuItem(
                                    value: 'claude_cli',
                                    child: Text(t('settingsAiModeCli'))),
                                DropdownMenuItem(
                                    value: 'anthropic_api',
                                    child: Text(t('settingsAiModeApi'))),
                              ],
                              onChanged: (v) =>
                                  setState(() => _aiMode = v ?? 'claude_cli'),
                            ),
                          ),
                          _field('AI_MODEL', t('settingsAiModel')),
                          _field('ANTHROPIC_API_KEY', t('settingsApiKey'),
                              secret: true),
                          _field('CLI_COMMAND', t('settingsCliCmd')),
                          _field('APP_CONTEXT', t('settingsAppContext'),
                              maxLines: 4,
                              hint: t('settingsAppContextHint')),
                          _field('AI_MIN_EVENTS', t('settingsMinEvents')),
                          _field('AI_MAX_ISSUES', t('settingsMaxIssues')),
                        ]),
                        _section(t('settingsGithub'), [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(t('settingsGithubHint'),
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                          ),
                          _field('GITHUB_REPO', t('settingsRepo')),
                          _field('GITHUB_TOKEN', t('settingsGhToken'),
                              secret: true),
                          _field('PR_MODEL', t('settingsPrModel')),
                          _field('GIT_REMOTE', t('settingsGitRemote')),
                          _field('APP_REPO_PATH', t('settingsAppRepo')),
                        ]),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}

// ── Per-release frequency bars (pure Flutter, no packages) ────────
class _ReleaseBars extends StatelessWidget {
  final List<ReleaseStat> stats;
  const _ReleaseBars({required this.stats});

  @override
  Widget build(BuildContext context) {
    final max = stats.map((s) => s.eventCount).fold(1, (a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in stats)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(
                width: 110,
                child: Text(s.shortRelease,
                    style:
                        const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
              ),
              Expanded(
                child: LayoutBuilder(builder: (_, c) {
                  final w = c.maxWidth * (s.eventCount / max);
                  return Stack(children: [
                    Container(
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Container(
                      height: 18,
                      width: w.clamp(2, c.maxWidth),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ]);
                }),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                child: Text(_fmt(s.eventCount),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
          ),
      ],
    );
  }
}

// ── Tiny helpers ──────────────────────────────────────────────────
String _fmt(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

String _date(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  final l = d.toLocal();
  return '${l.year}/${l.month.toString().padLeft(2, '0')}/${l.day.toString().padLeft(2, '0')}';
}
