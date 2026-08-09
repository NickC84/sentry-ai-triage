import 'dart:io';

import 'package:sentry_triage/ai_analyzer.dart';
import 'package:sentry_triage/config.dart';
import 'package:sentry_triage/version.dart';

/// Feed a feature description to the AI and let it **read your app repo** to
/// assess feasibility.
///
///   dart run bin/feature.dart "show a waiting-count badge in the top bar"
Future<void> main(List<String> args) async {
  if (handledVersionFlag(args)) return;

  if (args.isEmpty) {
    stderr.writeln('Usage: dart run bin/feature.dart "<feature description>"');
    exit(1);
  }
  final cfg = Config.load();
  final detail = args.join(' ');
  final title = detail.length > 40 ? '${detail.substring(0, 40)}…' : detail;

  final analyzer = AiAnalyzer(
    mode: cfg.aiMode,
    model: cfg.aiModel,
    apiKey: cfg.anthropicApiKey,
    cliCommand: cfg.cliCommand,
    appContext: cfg.appContext,
    outputLanguage: cfg.outputLanguage,
  );
  stdout.writeln('🔍 Reading ${cfg.appRepoPath} to assess feasibility (30–60s+)…\n');
  try {
    final r = await analyzer.analyzeFeature(
        title: title, detail: detail, repoPath: cfg.appRepoPath);
    stdout.writeln('feasibility: ${r.feasibility}   effort: ${r.effort}   '
        'priority: ${r.priorityScore}   confidence: ${(r.confidence * 100).round()}%');
    stdout.writeln('\nSummary: ${r.summary}');
    stdout.writeln('\nAffected areas: ${r.affectedAreas}');
    stdout.writeln('\nApproach: ${r.approach}');
    stdout.writeln('\nRisks: ${r.risks}');
    stdout.writeln('\n(model=${r.model}, cost \$${r.costUsd.toStringAsFixed(3)})');
  } catch (e) {
    stderr.writeln('❌ $e');
    exitCode = 1;
  } finally {
    analyzer.dispose();
  }
}
