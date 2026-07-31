import 'package:flutter/material.dart';

import 'i18n.dart';
import 'models.dart';
import 'ui_helpers.dart';

/// Small labeled text block used for AI output fields.
Widget aiField(String k, String v) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        SelectableText(v, style: const TextStyle(fontSize: 13)),
      ],
    );

/// Small labeled metadata cell (events / users / level / dates).
Widget metaCell(String k, String v) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(k, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );

Widget _spinnerIcon(bool busy, IconData idle) => busy
    ? const SizedBox(
        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
    : Icon(idle, size: 16);

/// AI analysis panel for bugs: severity / root cause / recommended action.
class AiSection extends StatelessWidget {
  final Issue issue;
  final bool analyzing;
  final VoidCallback onAnalyze;
  const AiSection(
      {required this.issue,
      required this.analyzing,
      required this.onAnalyze,
      super.key});

  @override
  Widget build(BuildContext context) {
    final i = issue;
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
              onPressed: analyzing ? null : onAnalyze,
              icon: _spinnerIcon(analyzing, Icons.auto_awesome),
              label: Text(analyzing
                  ? t('aiAnalyzing')
                  : (analyzed ? t('aiReanalyze') : t('aiAnalyze'))),
            ),
          ]),
          if (analyzing)
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
              sevBadge(i.severityScore!, i.isAppFixable),
              const SizedBox(width: 8),
              if (i.confidence != null)
                Text(tp('confidence', {'p': (i.confidence! * 100).round()}),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
            if (i.rootCauseSummary != null &&
                i.rootCauseSummary!.isNotEmpty) ...[
              const SizedBox(height: 8),
              aiField(t('rootCause'), i.rootCauseSummary!),
            ],
            if (i.recommendedAction != null &&
                i.recommendedAction!.isNotEmpty) ...[
              const SizedBox(height: 6),
              aiField(t('recommended'), i.recommendedAction!),
            ],
          ],
        ],
      ),
    );
  }
}

/// Feasibility panel for feature items (AI reads the app repo).
class FeatureSection extends StatelessWidget {
  final Issue issue;
  final bool analyzing;
  final VoidCallback onAnalyze;
  const FeatureSection(
      {required this.issue,
      required this.analyzing,
      required this.onAnalyze,
      super.key});

  @override
  Widget build(BuildContext context) {
    final i = issue;
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
              onPressed: analyzing ? null : onAnalyze,
              icon: _spinnerIcon(analyzing, Icons.auto_awesome),
              label: Text(analyzing
                  ? t('aiAnalyzing')
                  : (analyzed ? t('aiReanalyze') : t('featureAnalyze'))),
            ),
          ]),
          if (analyzing)
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
              feasBadge(i.feasibility!, i.effort),
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
              aiField(t('summaryField'), i.rootCauseSummary!),
            ],
            if ((i.affectedAreas ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              aiField(t('affected'), i.affectedAreas!),
            ],
            if ((i.recommendedAction ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              aiField(t('approach'), i.recommendedAction!),
            ],
            if ((i.risks ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              aiField(t('risks'), i.risks!),
            ],
          ],
        ],
      ),
    );
  }
}

/// Ticket button: entry to the GitHub issue once opened, disabled until the
/// item is analyzed, otherwise triggers ticket creation.
class TicketButton extends StatelessWidget {
  final Issue issue;
  final bool ticketing;
  final VoidCallback onOpenTicket;
  const TicketButton(
      {required this.issue,
      required this.ticketing,
      required this.onOpenTicket,
      super.key});

  @override
  Widget build(BuildContext context) {
    final i = issue;
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
          onPressed: deleted ? null : () => openUrl(i.ticketUrl!),
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
        onPressed: ticketing ? null : onOpenTicket,
        icon: _spinnerIcon(ticketing, Icons.add_task),
        label: Text(t('ticketCreate')),
      ),
    );
  }
}

/// Per-release frequency bars (pure Flutter, no packages).
class ReleaseBars extends StatelessWidget {
  final List<ReleaseStat> stats;
  const ReleaseBars({required this.stats, super.key});

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
                child: Text(fmt(s.eventCount),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
          ),
      ],
    );
  }
}
