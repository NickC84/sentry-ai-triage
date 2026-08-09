import 'dart:io';

import 'package:sentry_triage/config.dart';
import 'package:sentry_triage/db.dart';
import 'package:sentry_triage/ingest.dart';
import 'package:sentry_triage/version.dart';

/// Fetch Sentry issues → SQLite → apply triage rules → print a summary.
/// (The web UI's "Sync from Sentry" button runs the same flow.)
Future<void> main(List<String> args) async {
  if (handledVersionFlag(args)) return;

  final cfg = Config.load();

  final missing = cfg.missingForIngest;
  if (missing.isNotEmpty) {
    stderr.writeln('❌ Missing settings: ${missing.join(', ')}');
    stderr.writeln(
        '   Configure them in the web UI (Settings), in data/config.json, or in .env.');
    exit(1);
  }

  File(cfg.dbPath).parent.createSync(recursive: true);
  final db = TriageDb.open(cfg.dbPath);

  try {
    final s = await runIngest(cfg, db, log: (m) => stdout.writeln('📥 $m'));

    stdout.writeln('\n=== Triage states ===');
    s.stateCounts.forEach((k, v) => stdout.writeln('  $k: $v'));
    stdout.writeln('  (rules auto-classified this run: ${s.rulesApplied})');
    stdout.writeln('  (release stats written: ${s.releaseStatsWritten})');
    if (s.closedFromSentry > 0 || s.reopenedFromSentry > 0) {
      stdout.writeln('  (from Sentry: ${s.closedFromSentry} closed, '
          '${s.reopenedFromSentry} reopened)');
    }
    for (final w in s.warnings) {
      stdout.writeln('  ⚠️ $w');
    }

    stdout.writeln(
        '\n=== Issues worth a look (noise/hidden excluded, by event count) ===');
    final rows = db.summaryRows(limit: 20);
    if (rows.isEmpty) {
      stdout.writeln('  (none)');
    } else {
      for (final r in rows) {
        final count = r['total_count'] ?? 0;
        stdout.writeln(
            '  [$count] ${r['short_id']}  ${_truncate(r['title'], 60)}  <${r['category']}/${r['triage_state']}>');
      }
    }
    stdout.writeln('\n✅ Done. DB: ${cfg.dbPath}');
  } catch (e) {
    stderr.writeln('❌ $e');
    exitCode = 1;
  } finally {
    db.close();
  }
}

String _truncate(Object? s, int n) {
  final str = (s ?? '').toString();
  return str.length <= n ? str : '${str.substring(0, n)}…';
}
