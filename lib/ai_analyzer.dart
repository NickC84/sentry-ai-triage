import 'dart:convert';
import 'dart:io';

/// One AI analysis result for a crash issue.
class AnalysisResult {
  final int severityScore; // 0–100
  final String isAppFixable; // app_fixable | not_fixable | needs_more_data
  final String rootCauseSummary;
  final String recommendedAction;
  final double confidence; // 0–1
  final String model;
  final double costUsd;

  AnalysisResult({
    required this.severityScore,
    required this.isAppFixable,
    required this.rootCauseSummary,
    required this.recommendedAction,
    required this.confidence,
    required this.model,
    required this.costUsd,
  });
}

/// Feature feasibility analysis result.
class FeatureAnalysis {
  final String feasibility; // feasible | hard | blocked | needs_info
  final String effort; // S | M | L | XL
  final int priorityScore; // 0–100
  final String summary;
  final String approach;
  final String affectedAreas;
  final String risks;
  final double confidence;
  final String model;
  final double costUsd;

  FeatureAnalysis({
    required this.feasibility,
    required this.effort,
    required this.priorityScore,
    required this.summary,
    required this.approach,
    required this.affectedAreas,
    required this.risks,
    required this.confidence,
    required this.model,
    required this.costUsd,
  });
}

/// AI engine with two modes:
///
/// - **claude_cli** (default): shells out to the `claude` CLI (Claude Code).
///   Runs on your existing Claude subscription — no metered API cost. Also
///   powers repo-reading feature analysis. Point [cliCommand] at a compatible
///   wrapper to use a different agentic CLI.
/// - **anthropic_api**: calls the Anthropic Messages API directly with an API
///   key. Crash analysis only (feature analysis needs an agentic CLI that can
///   read your repo).
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

  String get _langInstruction => outputLanguage == 'zh-Hant'
      ? 'Write root_cause_summary and recommended_action in Traditional Chinese (繁體中文).'
      : 'Write root_cause_summary and recommended_action in English.';

  String get _appContextSection => appContext.trim().isEmpty
      ? '(No app context provided — judge from the issue itself. '
          'You can describe your app in Settings → App context to improve accuracy.)'
      : appContext.trim();

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

    final lang = outputLanguage == 'zh-Hant'
        ? 'Write summary / approach / risks in Traditional Chinese (繁體中文).'
        : 'Write summary / approach / risks in English.';

    final prompt = '''
You are a senior engineer on this project. A user proposed a new feature. **Actually read the project code** (use file/search tools), then assess feasibility and give a pragmatic plan.

## Feature request
Title: $title
Detail: ${detail.isEmpty ? '(none provided)' : detail}

## Your job
1. Read the relevant existing implementation and judge how this fits the current architecture.
2. feasibility: feasible (straightforward) / hard (doable, large change) / blocked (hard blocker) / needs_info (unclear requirements).
3. effort: S / M / L / XL (relative).
4. priority_score (0–100): suggested priority weighing user value vs. implementation cost (advisory only — a human decides).
5. affected_areas: the real files/modules you found that would change.
6. approach: recommended, actionable steps.
7. risks: risks or watch-outs.
$lang

Output only JSON matching the schema. Base everything on real code — do not guess.''';

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

  // ── engines ─────────────────────────────────────────────

  Future<_EngineResult> _callCli(String prompt, Map<String, dynamic> schema,
      String workingDir, Duration t) async {
    final result = await Process.run(
      cliCommand,
      [
        '-p', prompt,
        '--output-format', 'json',
        '--json-schema', jsonEncode(schema),
        '--model', model,
      ],
      workingDirectory: workingDir,
    ).timeout(t);

    if (result.exitCode != 0) {
      throw Exception(
          '$cliCommand failed (exit ${result.exitCode}): ${result.stderr}');
    }
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Cannot parse $cliCommand output: $e\n${result.stdout}');
    }
    if (envelope['is_error'] == true) {
      throw Exception('$cliCommand reported an error: ${envelope['result']}');
    }
    final out = envelope['structured_output'] as Map<String, dynamic>?;
    if (out == null) {
      throw Exception('Missing structured_output in: ${result.stdout}');
    }
    return _EngineResult(
      output: out,
      model: _firstModelUsed(envelope) ?? '',
      costUsd: (envelope['total_cost_usd'] as num?)?.toDouble() ?? 0,
    );
  }

  static const _apiModelAliases = {
    'opus': 'claude-opus-5',
    'sonnet': 'claude-sonnet-5',
    'haiku': 'claude-haiku-4-5',
  };

  // USD per 1M tokens (input, output) — for cost display only.
  static const _apiPrices = {
    'claude-opus-5': [5.0, 25.0],
    'claude-sonnet-5': [3.0, 15.0],
    'claude-haiku-4-5': [1.0, 5.0],
  };

  Future<_EngineResult> _callApi(
      String prompt, Map<String, dynamic> schema) async {
    if (apiKey.isEmpty) {
      throw Exception(
          'AI mode is anthropic_api but ANTHROPIC_API_KEY is empty — set it in Settings.');
    }
    final apiModel = _apiModelAliases[model] ?? model;

    final client = HttpClient();
    try {
      final req =
          await client.postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
      req.headers.set('x-api-key', apiKey);
      req.headers.set('anthropic-version', '2023-06-01');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': apiModel,
        'max_tokens': 2048,
        'output_config': {
          'format': {'type': 'json_schema', 'schema': schema},
        },
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }));
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('Anthropic API ${res.statusCode}: $body');
      }
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      if (envelope['stop_reason'] == 'refusal') {
        throw Exception('The model declined to analyze this issue.');
      }
      final content = (envelope['content'] as List?) ?? [];
      final text = content
          .whereType<Map<String, dynamic>>()
          .where((b) => b['type'] == 'text')
          .map((b) => (b['text'] ?? '').toString())
          .join();
      final out = jsonDecode(text) as Map<String, dynamic>;

      final usage = envelope['usage'] as Map<String, dynamic>? ?? {};
      final inTok = (usage['input_tokens'] as num?)?.toDouble() ?? 0;
      final outTok = (usage['output_tokens'] as num?)?.toDouble() ?? 0;
      final price = _apiPrices[apiModel];
      final cost = price == null
          ? 0.0
          : (inTok * price[0] + outTok * price[1]) / 1000000;

      return _EngineResult(
        output: out,
        model: (envelope['model'] ?? apiModel).toString(),
        costUsd: cost,
      );
    } finally {
      client.close(force: true);
    }
  }

  // ── prompt & schemas ─────────────────────────────────────

  static const _schema = {
    'type': 'object',
    'properties': {
      'severity_score': {
        'type': 'integer',
        'description':
            'Severity 0–100 (frequency, users affected, whether core features are blocked)',
      },
      'is_app_fixable': {
        'type': 'string',
        'enum': ['app_fixable', 'not_fixable', 'needs_more_data'],
        'description':
            'Fixable in app code / device-layer or external (not fixable) / not enough data',
      },
      'root_cause_summary': {
        'type': 'string',
        'description': '1–3 sentence root cause',
      },
      'recommended_action': {'type': 'string', 'description': 'Suggested action'},
      'confidence': {'type': 'number', 'description': '0–1 confidence'},
    },
    'required': [
      'severity_score',
      'is_app_fixable',
      'root_cause_summary',
      'recommended_action',
      'confidence',
    ],
  };

  static const _featureSchema = {
    'type': 'object',
    'properties': {
      'feasibility': {
        'type': 'string',
        'enum': ['feasible', 'hard', 'blocked', 'needs_info'],
      },
      'effort': {
        'type': 'string',
        'enum': ['S', 'M', 'L', 'XL'],
      },
      'priority_score': {'type': 'integer'},
      'summary': {'type': 'string', 'description': 'Feasibility summary'},
      'approach': {'type': 'string', 'description': 'Recommended approach/steps'},
      'affected_areas': {
        'type': 'string',
        'description': 'Real files/modules that would change',
      },
      'risks': {'type': 'string', 'description': 'Risks or watch-outs'},
      'confidence': {'type': 'number'},
    },
    'required': [
      'feasibility',
      'effort',
      'priority_score',
      'summary',
      'approach',
      'affected_areas',
      'risks',
      'confidence',
    ],
  };

  String _buildPrompt({
    required String shortId,
    required String title,
    required String culprit,
    required String level,
    required int totalCount,
    required int userCount,
    required String? firstSeen,
    required String? lastSeen,
    required List<String> releaseLines,
  }) {
    final rel = releaseLines.isEmpty
        ? '(no per-release data)'
        : releaseLines.map((l) => '  - $l').join('\n');
    return '''
You are an expert at triaging application crashes. Below is a Sentry issue. Judge its severity and whether it is a bug fixable in the app's own code.

## App context
$_appContextSection

## Issue ($shortId)
- Title: $title
- Culprit: ${culprit.isEmpty ? '(none)' : culprit}
- Level: $level
- Events (stats period): $totalCount, users affected: $userCount
- First seen: ${firstSeen ?? '—'}, last seen: ${lastSeen ?? '—'}
- Per-release frequency (release → events):
$rel

## Criteria
- severity_score (0–100): weigh frequency, users affected, and whether core functionality is blocked.
- is_app_fixable:
  - app_fixable = fixable in the app's own code (logic, state, null-safety, API integration…).
  - not_fixable = device driver/firmware, OS, or transient external network issues.
  - needs_more_data = missing stack trace / event details.
- root_cause_summary / recommended_action: concise and actionable. $_langInstruction

Output only JSON matching the schema.''';
  }

  String? _firstModelUsed(Map<String, dynamic> envelope) {
    final mu = envelope['modelUsage'];
    if (mu is Map && mu.isNotEmpty) return mu.keys.first.toString();
    return null;
  }
}

class _EngineResult {
  final Map<String, dynamic> output;
  final String model;
  final double costUsd;
  _EngineResult({required this.output, required this.model, required this.costUsd});
}

/// 32-bit FNV-1a — stable across runs (change detection only, not crypto).
String _fnv1a(String s) {
  var hash = 0x811c9dc5;
  for (final c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
