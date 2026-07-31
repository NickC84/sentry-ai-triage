import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'ai_analyzer.dart';
import 'config.dart';
import 'db.dart';
import 'github.dart';
import 'ingest.dart';
import 'pr_maker.dart';
import 'sentry_client.dart';

/// Local backend for the web UI: exposes triage.db as a JSON API, accepts
/// manual triage writes, on-demand AI analysis, Sentry ingest, GitHub
/// ticketing/draft PRs, and in-app configuration. Local tool — CORS wide open.
class ApiServer {
  final TriageDb db;
  final Config cfg;
  final String? webRoot;

  late AiAnalyzer _analyzer;
  late GithubTicketer _ticketer;
  late PrMaker _prMaker;
  bool _ingestRunning = false;

  ApiServer(this.db, this.cfg, {this.webRoot}) {
    _buildEngines();
  }

  /// (Re)build AI/GitHub engines from current config — called after settings
  /// change so saves take effect without a restart.
  void _buildEngines() {
    _analyzer = AiAnalyzer(
      mode: cfg.aiMode,
      model: cfg.aiModel,
      apiKey: cfg.anthropicApiKey,
      cliCommand: cfg.cliCommand,
      appContext: cfg.appContext,
      outputLanguage: cfg.outputLanguage,
    );
    _ticketer = GithubTicketer(cfg.githubRepo, token: cfg.githubToken);
    _prMaker = PrMaker(
      appRepoPath: cfg.appRepoPath,
      githubRepo: cfg.githubRepo,
      token: cfg.githubToken,
      model: cfg.prModel,
      cliCommand: cfg.cliCommand,
      gitRemote: cfg.gitRemote,
      outputLanguage: cfg.outputLanguage,
    );
  }

  Handler get _router {
    final router = Router()
      ..get('/api/health', (Request r) => _json({'ok': true}))
      ..get('/api/summary', _summary)
      ..get('/api/issues', _listIssues)
      ..get('/api/issues/<id>/releases', _releases)
      ..post('/api/issues/<id>/state', _setState)
      ..post('/api/issues/<id>/analyze', _analyze)
      // Settings (in-app configuration)
      ..get('/api/config', _getConfig)
      ..post('/api/config', _setConfig)
      // Sentry ingest from the UI
      ..post('/api/ingest', _ingest)
      ..post('/api/sentry/discover', _discoverSentry)
      // Features (manual backlog items)
      ..post('/api/features', _createFeature)
      ..post('/api/issues/<id>/analyze-feature', _analyzeFeature)
      ..post('/api/issues/<id>/select', _select)
      // GitHub tickets
      ..post('/api/issues/<id>/ticket', _openTicket)
      ..post('/api/tickets/open-selected', _openSelected)
      ..post('/api/issues/<id>/delete', _delete)
      // AI draft PRs
      ..post('/api/issues/<id>/draft-pr', _draftPr)
      // Sync ticket/PR states back from GitHub
      ..post('/api/sync-github', _syncGithub);
    return router.call;
  }

  // ── Settings ─────────────────────────────────────────────

  static const _mask = '••••••••';

  Response _getConfig(Request r) {
    final map = cfg.toMap();
    for (final k in Config.secretKeys) {
      if ((map[k] ?? '').isNotEmpty) map[k] = _mask;
    }
    return _json({
      'config': map,
      'secret_keys': Config.secretKeys.toList(),
      'missing_for_ingest': cfg.missingForIngest,
    });
  }

  Future<Response> _setConfig(Request r) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }
    // Ignore untouched masked secrets so the UI can round-trip safely.
    body.removeWhere((k, v) => v == _mask);

    final lang = (body['OUTPUT_LANGUAGE'] ?? '').toString();
    if (lang.isNotEmpty && lang != 'en' && lang != 'zh-Hant') {
      return _json({'error': 'OUTPUT_LANGUAGE must be en or zh-Hant'},
          status: 400);
    }
    final mode = (body['AI_MODE'] ?? '').toString();
    if (mode.isNotEmpty && mode != 'claude_cli' && mode != 'anthropic_api') {
      return _json({'error': 'AI_MODE must be claude_cli or anthropic_api'},
          status: 400);
    }

    final changed = cfg.applyAndSave(body);
    _buildEngines();
    return _json({'ok': true, 'changed': changed});
  }

  // ── Ingest ───────────────────────────────────────────────

  Future<Response> _ingest(Request r) async {
    if (_ingestRunning) {
      return _json({'error': 'An ingest is already running'}, status: 409);
    }
    final missing = cfg.missingForIngest;
    if (missing.isNotEmpty) {
      return _json({
        'error': 'Missing Sentry settings: ${missing.join(', ')}',
        'missing': missing,
      }, status: 400);
    }
    _ingestRunning = true;
    try {
      final summary = await runIngest(cfg, db);
      return _json({'ok': true, ...summary.toJson()});
    } catch (e) {
      return _json({'error': 'Ingest failed: $e'}, status: 500);
    } finally {
      _ingestRunning = false;
    }
  }

  /// Settings helper: list the orgs/projects a token can reach, so the UI
  /// can offer pickers instead of hand-typed slugs. Accepts a token in the
  /// body (masked/empty falls back to the saved one).
  Future<Response> _discoverSentry(Request r) async {
    Map<String, dynamic> body = {};
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    var token = (body['token'] ?? '').toString().trim();
    var base = (body['base_url'] ?? '').toString().trim();
    if (token.isEmpty || token == _mask) token = cfg.token;
    if (base.isEmpty) base = cfg.baseUrl;
    if (token.isEmpty) {
      return _json({'error': 'No token provided'}, status: 400);
    }
    try {
      final orgs = await SentryClient.discover(baseUrl: base, token: token);
      return _json({'orgs': orgs});
    } catch (e) {
      return _json({'error': '$e'}, status: 502);
    }
  }

  // ── Issues ───────────────────────────────────────────────

  Response _summary(Request r) => _json({
        'states': db.stateCounts(),
        'categories': db.categoryCounts(),
      });

  Response _listIssues(Request r) {
    final includeNoise = r.url.queryParameters['include_noise'] == 'true';
    return _json({'issues': db.listIssues(includeNoise: includeNoise)});
  }

  Response _releases(Request r, String id) =>
      _json({'releases': db.releaseStatsFor(id)});

  Future<Response> _setState(Request r, String id) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }

    final state = body['triage_state']?.toString();
    final category = body['category']?.toString();
    final note = body['triage_note']?.toString();

    if (state == null && category == null && note == null) {
      return _json(
          {'error': 'Provide at least one of triage_state / category / triage_note'},
          status: 400);
    }
    if (state != null && !TriageDb.triageStates.contains(state)) {
      return _json({
        'error': 'Invalid triage_state: $state',
        'allowed': TriageDb.triageStates.toList(),
      }, status: 400);
    }
    if (category != null && !TriageDb.categories.contains(category)) {
      return _json({
        'error': 'Invalid category: $category',
        'allowed': TriageDb.categories.toList(),
      }, status: 400);
    }

    final found =
        db.updateTriage(id, state: state, category: category, note: note);
    if (!found) return _json({'error': 'Issue not found: $id'}, status: 404);
    return _json({
      'ok': true,
      'sentry_issue_id': id,
      if (state != null) 'triage_state': state,
      if (category != null) 'category': category,
    });
  }

  /// On-demand AI analysis for a single issue (bypasses threshold/cache).
  Future<Response> _analyze(Request r, String id) async {
    final issue = db.issueById(id);
    if (issue == null) return _json({'error': 'Issue not found: $id'}, status: 404);

    final releases = db.releaseStatsFor(id);
    final total = (issue['total_count'] as num?)?.toInt() ?? 0;
    try {
      final result = await _analyzer.analyze(
        shortId: (issue['short_id'] ?? '') as String,
        title: (issue['title'] ?? '') as String,
        culprit: (issue['culprit'] ?? '') as String,
        level: (issue['level'] ?? '') as String,
        totalCount: total,
        userCount: (issue['user_count'] as num?)?.toInt() ?? 0,
        firstSeen: issue['first_seen'] as String?,
        lastSeen: issue['last_seen'] as String?,
        releaseLines: releases
            .map((r) => '${r['release']} → ${r['event_count']}')
            .toList(),
      );
      final hash = AiAnalyzer.fingerprint(
        title: (issue['title'] ?? '') as String,
        culprit: (issue['culprit'] ?? '') as String,
        level: (issue['level'] ?? '') as String,
        releases:
            releases.map((r) => (r['release'] ?? '').toString()).toList(),
        totalCount: total,
      );
      db.upsertAnalysis(
        id,
        severityScore: result.severityScore,
        isAppFixable: result.isAppFixable,
        rootCauseSummary: result.rootCauseSummary,
        recommendedAction: result.recommendedAction,
        confidence: result.confidence,
        model: result.model,
        costUsd: result.costUsd,
        inputContextHash: hash,
      );
      return _json({
        'ok': true,
        'severity_score': result.severityScore,
        'is_app_fixable': result.isAppFixable,
        'root_cause_summary': result.rootCauseSummary,
        'recommended_action': result.recommendedAction,
        'confidence': result.confidence,
        'model': result.model,
        'cost_usd': result.costUsd,
      });
    } catch (e) {
      return _json({'error': 'AI analysis failed: $e'}, status: 500);
    }
  }

  /// Create a manual feature/backlog item. body: {title, detail?}
  Future<Response> _createFeature(Request r) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }
    final title = (body['title'] ?? '').toString().trim();
    if (title.isEmpty) return _json({'error': 'Title is required'}, status: 400);
    final detail = (body['detail'] ?? '').toString();
    final id = db.createFeature(title, detail);
    return _json({'ok': true, 'sentry_issue_id': id});
  }

  /// Repo-reading feasibility analysis for a feature.
  Future<Response> _analyzeFeature(Request r, String id) async {
    final issue = db.issueById(id);
    if (issue == null) return _json({'error': 'Item not found: $id'}, status: 404);
    final title = (issue['title'] ?? '') as String;
    final detail = (issue['detail'] ?? '') as String;
    try {
      final f = await _analyzer.analyzeFeature(
          title: title, detail: detail, repoPath: cfg.appRepoPath);
      db.upsertFeatureAnalysis(
        id,
        feasibility: f.feasibility,
        effort: f.effort,
        priorityScore: f.priorityScore,
        summary: f.summary,
        approach: f.approach,
        affectedAreas: f.affectedAreas,
        risks: f.risks,
        confidence: f.confidence,
        model: f.model,
        costUsd: f.costUsd,
      );
      return _json({
        'ok': true,
        'feasibility': f.feasibility,
        'effort': f.effort,
        'priority_score': f.priorityScore,
        'summary': f.summary,
        'approach': f.approach,
        'affected_areas': f.affectedAreas,
        'risks': f.risks,
        'confidence': f.confidence,
        'model': f.model,
        'cost_usd': f.costUsd,
      });
    } catch (e) {
      return _json({'error': 'Feature analysis failed: $e'}, status: 500);
    }
  }

  /// Toggle "selected for development". body: {selected: bool}
  Future<Response> _select(Request r, String id) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }
    final selected = body['selected'] == true;
    final found = db.setSelectedForDev(id, selected);
    if (!found) return _json({'error': 'Item not found: $id'}, status: 404);
    return _json({'ok': true, 'selected_for_dev': selected});
  }

  /// Open a GitHub issue for one item (idempotent: returns existing URL).
  Future<Response> _openTicket(Request r, String id) async {
    final row = db.issueWithAnalysis(id);
    if (row == null) return _json({'error': 'Item not found: $id'}, status: 404);
    final existing = (row['ticket_url'] ?? '').toString();
    if (existing.isNotEmpty) {
      db.setSelectedForDev(id, true);
      return _json({'ok': true, 'ticket_url': existing, 'already': true});
    }

    // Require analysis first (avoid opening empty tickets).
    final isFeature = (row['source'] ?? 'sentry') == 'feature';
    final analyzed =
        isFeature ? row['feasibility'] != null : row['severity_score'] != null;
    if (!analyzed) {
      return _json(
          {'error': 'Analyze the item first so the ticket has real content'},
          status: 400);
    }

    try {
      final t = GithubTicketer.compose(row, lang: cfg.outputLanguage);
      final url = await _ticketer.createIssue(title: t.title, body: t.body);
      db.setTicketUrl(id, url);
      db.setSelectedForDev(id, true);

      // Auto-@claude to open the discussion on the GitHub issue.
      final zh = cfg.outputLanguage == 'zh-Hant';
      final starter = isFeature
          ? (zh
              ? '@claude 這是一則新需求(見上方分析)。請先幫我把**規格與可行性討論清楚**(待澄清點、影響範圍、建議做法),**先不要改 code**;我們討論確認後,我會再留言請你依規格實作。'
              : '@claude This is a new feature request (see analysis above). Please first help clarify the **spec and feasibility** (open questions, affected areas, suggested approach) — **do not change code yet**. Once we confirm the spec, I will comment again to ask for implementation.')
          : (zh
              ? '@claude 這是一個崩潰(見上方分析)。請幫我釐清**根因與修法方向**,**先不要改 code**;討論確認後我再請你實作修復。'
              : '@claude This is a crash (see analysis above). Please help pin down the **root cause and fix direction** — **do not change code yet**. Once we agree, I will ask you to implement the fix.');
      var commentPosted = true;
      try {
        await _ticketer.addComment(url, starter);
      } catch (_) {
        commentPosted = false;
      }

      return _json({
        'ok': true,
        'ticket_url': url,
        'selected_for_dev': true,
        'claude_started': commentPosted,
      });
    } catch (e) {
      return _json({'error': 'Ticket creation failed: $e'}, status: 500);
    }
  }

  /// Open tickets for everything selected-for-dev without one.
  Future<Response> _openSelected(Request r) async {
    final ids = db.selectedWithoutTicket();
    final opened = <Map<String, Object?>>[];
    final failed = <Map<String, Object?>>[];
    for (final id in ids) {
      final row = db.issueWithAnalysis(id);
      if (row == null) continue;
      try {
        final t = GithubTicketer.compose(row, lang: cfg.outputLanguage);
        final url = await _ticketer.createIssue(title: t.title, body: t.body);
        db.setTicketUrl(id, url);
        opened.add({'sentry_issue_id': id, 'ticket_url': url});
      } catch (e) {
        failed.add({'sentry_issue_id': id, 'error': '$e'});
      }
    }
    return _json({
      'ok': true,
      'opened': opened,
      'failed': failed,
      'candidates': ids.length,
    });
  }

  /// AI draft PR for a selected-for-dev item (branch + draft PR, never merged).
  Future<Response> _draftPr(Request r, String id) async {
    final row = db.issueWithAnalysis(id);
    if (row == null) return _json({'error': 'Item not found: $id'}, status: 404);
    if ((row['selected_for_dev'] as num?)?.toInt() != 1) {
      return _json({'error': 'Select the item for development first'},
          status: 400);
    }
    final existing = (row['pr_url'] ?? '').toString();
    if (existing.isNotEmpty) {
      return _json({'ok': true, 'pr_url': existing, 'already': true});
    }
    try {
      final result = await _prMaker.makeDraftPr(
        shortId: (row['short_id'] ?? '') as String,
        title: (row['title'] ?? '') as String,
        isFeature: (row['source'] ?? 'sentry') == 'feature',
        detail: (row['detail'] ?? '') as String,
        rootCause: (row['root_cause_summary'] ?? '') as String,
        approach: (row['recommended_action'] ?? '') as String,
        affectedAreas: (row['affected_areas'] ?? '') as String,
      );
      db.setPrUrl(id, result.prUrl);
      return _json({
        'ok': true,
        'pr_url': result.prUrl,
        'branch': result.branch,
        'changed_files': result.changedFiles,
      });
    } catch (e) {
      return _json({'error': 'Draft PR failed: $e'}, status: 500);
    }
  }

  /// Sync GitHub ticket/PR states back into the DB.
  Future<Response> _syncGithub(Request r) async {
    final items = db.itemsWithGithubLinks();
    var synced = 0;
    for (final it in items) {
      final id = it['sentry_issue_id'] as String;
      final ticketUrl = (it['ticket_url'] ?? '').toString();
      final prUrl = (it['pr_url'] ?? '').toString();
      String? ticketState, prState;
      if (ticketUrl.isNotEmpty) ticketState = await _ticketer.stateOf(ticketUrl);
      if (prUrl.isNotEmpty) prState = await _ticketer.stateOf(prUrl);
      db.setGithubStates(id, ticketState: ticketState, prState: prState);
      synced++;
    }
    return _json({'ok': true, 'synced': synced});
  }

  /// Delete an item (mainly for manual features; Sentry issues come back on
  /// the next ingest).
  Response _delete(Request r, String id) {
    final ok = db.deleteIssue(id);
    if (!ok) return _json({'error': 'Item not found: $id'}, status: 404);
    return _json({'ok': true});
  }

  /// Start the server. Returns the HttpServer for shutdown.
  Future<HttpServer> start({String host = 'localhost', int port = 8787}) async {
    var pipeline =
        const Pipeline().addMiddleware(_cors).addMiddleware(logRequests());

    Handler handler;
    if (webRoot != null && Directory(webRoot!).existsSync()) {
      final static = createStaticHandler(webRoot!,
          defaultDocument: 'index.html', listDirectories: false);
      handler = Cascade().add(_router).add(static).handler;
    } else {
      handler = _router;
    }

    final server =
        await shelf_io.serve(pipeline.addHandler(handler), host, port);
    return server;
  }

  // ── helpers ───────────────────────────────────────────────

  static Response _json(Object? data, {int status = 200}) => Response(
        status,
        body: jsonEncode(data),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  /// CORS: local tool, wide open (incl. preflight).
  static Handler Function(Handler) get _cors => (Handler inner) {
        return (Request req) async {
          if (req.method == 'OPTIONS') {
            return Response.ok('', headers: _corsHeaders);
          }
          final res = await inner(req);
          return res.change(headers: _corsHeaders);
        };
      };

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept',
  };
}
