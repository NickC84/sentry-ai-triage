import 'dart:io';

import 'package:sentry_triage/ai_analyzer.dart';
import 'package:sentry_triage/config.dart';
import 'package:sentry_triage/db.dart';
import 'package:sentry_triage/version.dart';

/// Phase 2: batch AI analysis for new/keep issues above the threshold.
///
/// Cost guardrails:
/// - Only analyzes triage_state ∈ {new, keep} with event count ≥ AI_MIN_EVENTS.
/// - At most AI_MAX_ISSUES per run.
/// - input_context_hash cache: skip when the input hasn't changed meaningfully.
/// - known_noise / hidden are never sent.
Future<void> main(List<String> args) async {
  if (handledVersionFlag(args)) return;

  final cfg = Config.load();

  final dbFile = File(cfg.dbPath);
  if (!dbFile.existsSync()) {
    stderr.writeln('❌ DB not found: ${cfg.dbPath} — run dart run bin/ingest.dart first.');
    exit(1);
  }

  final db = TriageDb.open(cfg.dbPath);
  final analyzer = AiAnalyzer(
    mode: cfg.aiMode,
    model: cfg.aiModel,
    apiKey: cfg.anthropicApiKey,
    cliCommand: cfg.cliCommand,
    appContext: cfg.appContext,
    outputLanguage: cfg.outputLanguage,
  );

  final targets =
      db.issuesToAnalyze(minEvents: cfg.aiMinEvents, limit: cfg.aiMaxIssues);

  stdout.writeln('🤖 AI analysis (mode=${cfg.aiMode}, model=${cfg.aiModel}, '
      'threshold ≥${cfg.aiMinEvents} events, cap ${cfg.aiMaxIssues})');
  stdout.writeln('   Eligible: ${targets.length}\n');

  var analyzed = 0, skipped = 0, failed = 0;
  var totalCost = 0.0;

  for (final t in targets) {
    final id = t['sentry_issue_id'] as String;
    final shortId = (t['short_id'] ?? '') as String;
    final title = (t['title'] ?? '') as String;
    final culprit = (t['culprit'] ?? '') as String;
    final level = (t['level'] ?? '') as String;
    final total = (t['total_count'] as num?)?.toInt() ?? 0;
    final users = (t['user_count'] as num?)?.toInt() ?? 0;
    final prevHash = t['prev_hash'] as String?;

    final releases = db.releaseStatsFor(id);
    final releaseNames =
        releases.map((r) => (r['release'] ?? '').toString()).toList();
    final releaseLines = releases
        .map((r) => '${r['release']} → ${r['event_count']}')
        .toList();

    final hash = AiAnalyzer.fingerprint(
      title: title,
      culprit: culprit,
      level: level,
      releases: releaseNames,
      totalCount: total,
    );

    if (prevHash == hash) {
      skipped++;
      stdout.writeln('  ⏭️  $shortId unchanged, using cached analysis');
      continue;
    }

    stdout.write('  🔍 analyzing $shortId…');
    try {
      final r = await analyzer.analyze(
        shortId: shortId,
        title: title,
        culprit: culprit,
        level: level,
        totalCount: total,
        userCount: users,
        firstSeen: t['first_seen'] as String?,
        lastSeen: t['last_seen'] as String?,
        releaseLines: releaseLines,
      );
      db.upsertAnalysis(
        id,
        severityScore: r.severityScore,
        isAppFixable: r.isAppFixable,
        rootCauseSummary: r.rootCauseSummary,
        recommendedAction: r.recommendedAction,
        confidence: r.confidence,
        model: r.model,
        costUsd: r.costUsd,
        inputContextHash: hash,
      );
      analyzed++;
      totalCost += r.costUsd;
      stdout.writeln(
          ' severity ${r.severityScore} / ${r.isAppFixable} '
          '(confidence ${(r.confidence * 100).round()}%, \$${r.costUsd.toStringAsFixed(3)})');
    } catch (e) {
      failed++;
      stdout.writeln(' ❌ $e');
    }
  }

  analyzer.dispose();
  db.close();

  stdout.writeln('\n=== Done ===');
  stdout.writeln('  analyzed $analyzed · cache-skipped $skipped · failed $failed');
  stdout.writeln('  total cost: ~\$${totalCost.toStringAsFixed(3)}');
}
