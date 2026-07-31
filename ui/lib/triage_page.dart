import 'package:flutter/material.dart';

import 'api.dart';
import 'dialogs.dart';
import 'i18n.dart';
import 'issue_detail.dart';
import 'issue_list_pane.dart';
import 'models.dart';
import 'page_chrome.dart';
import 'settings_page.dart';
import 'ui_helpers.dart';

/// Main screen: bug/feature tabs, issue list on the left, detail panel on
/// the right, and all the toolbar actions.
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
  bool _syncing = false;
  bool _ingesting = false;

  bool get _featureTab => _tab == 1;
  int get _bugCount => _issues.where((i) => !i.isFeature).length;
  int get _featureCount => _issues.where((i) => i.isFeature).length;

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
        final label =
            state != null ? stateLabel(state) : categoryLabel(category ?? '');
        _snack('${issue.shortId} → $label', seconds: 1);
      }
      await _load();
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    }
  }

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
    if (!await confirmDelete(context, issue.title)) return;
    try {
      await _api.deleteIssue(issue.id);
      setState(() => _selected = null);
      await _load(silent: true);
      if (mounted) _snack(t('deleted'));
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    }
  }

  Future<void> _newFeature() async {
    final draft = await promptNewFeature(context);
    if (draft == null) return;
    try {
      final id = await _api.createFeature(draft.title, draft.detail);
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
        actions: _appBarActions(),
      ),
      body: Column(children: [
        TriageTabBar(
          current: _tab,
          bugCount: _bugCount,
          featureCount: _featureCount,
          onChanged: (i) => setState(() {
            _tab = i;
            _selected = null; // clear so the other tab's detail hides
          }),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody()),
      ]),
    );
  }

  List<Widget> _appBarActions() {
    Widget spinner() => const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2));
    return [
      if (_summary != null) SummaryPills(summary: _summary!),
      const SizedBox(width: 12),
      FilledButton.tonalIcon(
        onPressed: _newFeature,
        icon: const Icon(Icons.add, size: 18),
        label: Text(t('newFeature')),
      ),
      const SizedBox(width: 8),
      TextButton.icon(
        onPressed: _ingesting ? null : _runIngest,
        icon: _ingesting
            ? spinner()
            : const Icon(Icons.cloud_download_outlined, size: 18),
        label: Text(_ingesting ? t('ingesting') : t('syncFromSentry')),
      ),
      TextButton.icon(
        onPressed: _syncing ? null : _syncGithub,
        icon: _syncing ? spinner() : const Icon(Icons.sync, size: 18),
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
    ];
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return BackendErrorView(error: _error!, onRetry: _load);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: IssueListPane(
            issues: _filteredIssues,
            showFirstRunHint: _issues.isEmpty,
            selectedId: _selected?.id,
            categoryFilter: _categoryFilter,
            sortByPriority: _sortByPriority,
            onSearch: (v) => setState(() => _search = v),
            onCategoryFilter: (v) => setState(() => _categoryFilter = v),
            onSortByPriority: (v) => setState(() => _sortByPriority = v),
            onSelect: (issue) => setState(() => _selected = issue),
            onSetIssueState: (issue, s) => _updateTriage(issue, state: s),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(flex: 5, child: _detailPanel()),
      ],
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
