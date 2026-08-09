import 'config.dart';
import 'db.dart';
import 'sentry_client.dart';

/// Summary of one ingest run.
class IngestSummary {
  final int fetched;
  final int rulesApplied;
  final int releaseStatsWritten;

  /// Items closed here because Sentry has them resolved or archived.
  final int closedFromSentry;

  /// Items brought back because Sentry has them open again.
  final int reopenedFromSentry;

  final Map<String, int> stateCounts;
  final List<String> warnings;

  IngestSummary({
    required this.fetched,
    required this.rulesApplied,
    required this.releaseStatsWritten,
    required this.closedFromSentry,
    required this.reopenedFromSentry,
    required this.stateCounts,
    required this.warnings,
  });

  Map<String, Object?> toJson() => {
        'fetched': fetched,
        'rules_applied': rulesApplied,
        'release_stats_written': releaseStatsWritten,
        'closed_from_sentry': closedFromSentry,
        'reopened_from_sentry': reopenedFromSentry,
        'state_counts': stateCounts,
        'warnings': warnings,
      };
}

/// Fetch Sentry issues → upsert into SQLite → apply triage rules →
/// fetch per-release stats for the issues worth watching.
/// Shared by the CLI (bin/ingest.dart) and the web UI (POST /api/ingest).
Future<IngestSummary> runIngest(Config cfg, TriageDb db,
    {void Function(String)? log}) async {
  void say(String s) => log?.call(s);

  final missing = cfg.missingForIngest;
  if (missing.isNotEmpty) {
    throw Exception(
        'Missing Sentry settings: ${missing.join(', ')} — fill them in Settings first.');
  }

  db.seedDefaultRules();

  final client = SentryClient(
    baseUrl: cfg.baseUrl,
    org: cfg.org,
    project: cfg.project,
    token: cfg.token,
  );

  final warnings = <String>[];
  try {
    say('Fetching Sentry issues (org=${cfg.org}, project=${cfg.project}, '
        'period=${cfg.statsPeriodDays}d)…');
    final issues = await client.listIssues(statsPeriodDays: cfg.statsPeriodDays);
    say('Got ${issues.length} issues, writing to DB…');
    for (final i in issues) {
      db.upsertIssue(i);
      db.insertSnapshot(i);
    }

    // Ask Sentry which issues it considers closed, then line the local
    // backlog up with it. Without this the list slowly fills with items
    // someone already dealt with in Sentry.
    say('Reconciling with resolved/archived issues in Sentry…');
    var moved = (closed: 0, reopened: 0);
    try {
      final closed = await client.closedIssues(statsPeriodDays: cfg.statsPeriodDays);
      if (closed.truncated) {
        warnings.add('Sentry has more resolved/archived issues than one run '
            'reads; some may still show as open here.');
      }
      moved = db.reconcileWithSentry(
        unresolvedIds: [for (final i in issues) i.id],
        closedStatuses: closed.statuses,
      );
      say('Closed ${moved.closed}, reopened ${moved.reopened} from Sentry.');
    } catch (e) {
      // A failed reconciliation must not lose the issues just fetched.
      warnings.add('Could not read resolved/archived issues from Sentry: $e');
    }

    // Triage first, then only fetch per-release stats for new/keep issues —
    // no API budget wasted on known device noise.
    final applied = db.applyRules();

    var relCount = 0;
    final targets = db.issuesForReleaseStats(limit: cfg.maxReleaseLookups);
    for (final t in targets) {
      final id = t['sentry_issue_id'] as String;
      try {
        for (final r in await client.releaseStats(id)) {
          db.upsertReleaseStat(id, r);
          relCount++;
        }
      } catch (e) {
        warnings.add('${t['short_id']}: release stats failed: $e');
      }
    }

    return IngestSummary(
      fetched: issues.length,
      rulesApplied: applied,
      releaseStatsWritten: relCount,
      closedFromSentry: moved.closed,
      reopenedFromSentry: moved.reopened,
      stateCounts: db.stateCounts(),
      warnings: warnings,
    );
  } finally {
    client.close();
  }
}
