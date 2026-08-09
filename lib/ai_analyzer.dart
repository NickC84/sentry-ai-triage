import 'dart:convert';
import 'dart:io';

import 'process_runner.dart';

part 'ai/models.dart';
part 'ai/prompts.dart';
part 'ai/engines.dart';

/// AI engine with two modes:
///
/// - **claude_cli** (default): shells out to the `claude` CLI (Claude Code).
///   Runs on your existing Claude subscription — no metered API cost. Also
///   powers repo-reading feature analysis. Point [cliCommand] at a compatible
///   wrapper to use a different agentic CLI.
/// - **anthropic_api**: calls the Anthropic Messages API directly with an API
///   key. Crash analysis only (feature analysis needs an agentic CLI that can
///   read your repo).
///
/// Split across `lib/ai/`:
/// - models.dart  — result value types
/// - prompts.dart — prompt builders and JSON schemas
/// - engines.dart — CLI / API invocation and pricing
class AiAnalyzer {
  final String mode; // claude_cli | anthropic_api
  final String model; // sonnet | haiku | opus | full model id
  final String apiKey;
  final String cliCommand;
  final String appContext;
  final String outputLanguage; // en | zh-Hant
  final Duration timeout;
  final Duration featureTimeout;

  /// Clean temp working dir (no CLAUDE.md) to keep CLI context overhead low.
  final Directory _workDir =
      Directory.systemTemp.createTempSync('triage_ai_work');

  AiAnalyzer({
    this.mode = 'claude_cli',
    this.model = 'sonnet',
    this.apiKey = '',
    this.cliCommand = 'claude',
    this.appContext = '',
    this.outputLanguage = 'en',
    this.timeout = const Duration(seconds: 120),
    this.featureTimeout = const Duration(minutes: 8),
  });

  /// Content fingerprint used to decide whether an issue changed enough to
  /// re-analyze (cost guardrail). Event counts are bucketed by order of
  /// magnitude so small increments don't bust the cache.
  static String fingerprint({
    required String title,
    required String culprit,
    required String level,
    required List<String> releases,
    required int totalCount,
  }) {
    final bucket = totalCount <= 0 ? 0 : totalCount.toString().length;
    final sorted = [...releases]..sort();
    final raw =
        [title, culprit, level, bucket.toString(), sorted.join(',')].join('');
    return _fnv1a(raw);
  }

  /// Analyze a single crash issue.
  Future<AnalysisResult> analyze({
    required String shortId,
    required String title,
    required String culprit,
    required String level,
    required int totalCount,
    required int userCount,
    required String? firstSeen,
    required String? lastSeen,
    required List<String> releaseLines,
  }) async {
    final prompt = _buildPrompt(
      shortId: shortId,
      title: title,
      culprit: culprit,
      level: level,
      totalCount: totalCount,
      userCount: userCount,
      firstSeen: firstSeen,
      lastSeen: lastSeen,
      releaseLines: releaseLines,
    );

    final Map<String, dynamic> out;
    final String usedModel;
    final double cost;

    if (mode == 'anthropic_api') {
      final r = await _callApi(prompt, _schema);
      out = r.output;
      usedModel = r.model;
      cost = r.costUsd;
    } else {
      final r = await _callCli(prompt, _schema, _workDir.path, timeout);
      out = r.output;
      usedModel = r.model.isEmpty ? model : r.model;
      cost = r.costUsd;
    }

    return AnalysisResult(
      severityScore:
          ((out['severity_score'] as num?) ?? 0).toInt().clamp(0, 100),
      isAppFixable: (out['is_app_fixable'] ?? 'needs_more_data').toString(),
      rootCauseSummary: (out['root_cause_summary'] ?? '').toString(),
      recommendedAction: (out['recommended_action'] ?? '').toString(),
      confidence: ((out['confidence'] as num?) ?? 0).toDouble().clamp(0, 1),
      model: usedModel,
      costUsd: cost,
    );
  }

  /// Feature feasibility analysis: runs the CLI **inside your app repo** so
  /// the AI can read real code. claude_cli mode only.
  Future<FeatureAnalysis> analyzeFeature({
    required String title,
    required String detail,
    required String repoPath,
  }) async {
    if (mode == 'anthropic_api') {
      throw Exception(
          'Feature analysis needs an agentic CLI that can read your repo. '
          'Switch AI mode to claude_cli in Settings.');
    }
    if (repoPath.trim().isEmpty) {
      throw Exception(
          'APP_REPO_PATH is not set. Point it at your app repo in Settings.');
    }
    final dir = Directory(repoPath);
    if (!dir.existsSync()) {
      throw Exception('App repo not found: $repoPath (set APP_REPO_PATH)');
    }

    final prompt = _buildFeaturePrompt(title: title, detail: detail);
    final r =
        await _callCli(prompt, _featureSchema, dir.absolute.path, featureTimeout);
    final out = r.output;

    return FeatureAnalysis(
      feasibility: (out['feasibility'] ?? 'needs_info').toString(),
      effort: (out['effort'] ?? 'M').toString(),
      priorityScore:
          ((out['priority_score'] as num?) ?? 0).toInt().clamp(0, 100),
      summary: (out['summary'] ?? '').toString(),
      approach: (out['approach'] ?? '').toString(),
      affectedAreas: (out['affected_areas'] ?? '').toString(),
      risks: (out['risks'] ?? '').toString(),
      confidence: ((out['confidence'] as num?) ?? 0).toDouble().clamp(0, 1),
      model: r.model.isEmpty ? model : r.model,
      costUsd: r.costUsd,
    );
  }

  void dispose() {
    try {
      _workDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
