import 'package:flutter/material.dart';

import 'api.dart';
import 'detail_widgets.dart';
import 'i18n.dart';
import 'issue_tile.dart';
import 'models.dart';
import 'ui_helpers.dart';

/// Right-hand detail panel: triage controls, AI analysis, ticketing, and
/// per-release frequency.
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
  bool _ticketing = false;

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

  @override
  Widget build(BuildContext context) {
    final i = _issue;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            badge(categoryLabel(i.category), categoryColor(i.category)),
            const SizedBox(width: 8),
            Text(i.shortId, style: const TextStyle(color: Colors.grey)),
            const Spacer(),
            if (i.permalink.isNotEmpty)
              TextButton.icon(
                onPressed: () => openUrl(i.permalink),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Sentry'),
              ),
            TicketButton(
                issue: i, ticketing: _ticketing, onOpenTicket: _runOpenTicket),
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
            CategoryPicker(
                value: i.category, onChanged: widget.onUpdateCategory),
            const SizedBox(width: 16),
            Text(t('stateLabel'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            StatePicker(value: i.triageState, onChanged: widget.onUpdateState),
          ]),
          if (i.triageNote != null && i.triageNote!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(tp('noteLabel', {'n': i.triageNote}),
                style: const TextStyle(fontStyle: FontStyle.italic)),
          ],
          if (i.isFeature) ..._featureBody(i) else ..._bugBody(i),
        ],
      ),
    );
  }

  List<Widget> _featureBody(Issue i) => [
        const SizedBox(height: 8),
        // "Selected for dev" is read-only here; it flips when a ticket is
        // opened (never toggled by hand).
        Row(children: [
          Icon(
            i.selectedForDev ? Icons.check_box : Icons.check_box_outline_blank,
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
        FeatureSection(
            issue: i, analyzing: _analyzing, onAnalyze: _runFeatureAnalyze),
      ];

  List<Widget> _bugBody(Issue i) => [
        const SizedBox(height: 12),
        Wrap(spacing: 16, runSpacing: 4, children: [
          metaCell(t('metaTotal'), fmt(i.totalCount)),
          metaCell(t('metaUsers'), fmt(i.userCount)),
          metaCell(t('metaLevel'), i.level),
          metaCell(t('metaFirst'), fmtDate(i.firstSeen)),
          metaCell(t('metaLast'), fmtDate(i.lastSeen)),
        ]),
        const SizedBox(height: 16),
        AiSection(issue: i, analyzing: _analyzing, onAnalyze: _runAnalyze),
        const Divider(height: 32),
        Text(t('releaseFreq'),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
            return ReleaseBars(stats: rs);
          },
        ),
      ];
}
