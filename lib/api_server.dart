import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'ai_analyzer.dart';
import 'config.dart';
import 'db.dart';
import 'env_check.dart';
import 'github.dart';
import 'ingest.dart';
import 'pr_maker.dart';
import 'sentry_client.dart';
import 'version.dart';

part 'api/config_routes.dart';
part 'api/issue_routes.dart';
part 'api/github_routes.dart';
part 'api/health_routes.dart';
part 'api/scheduler.dart';

/// Local backend for the web UI: exposes triage.db as a JSON API, accepts
/// manual triage writes, on-demand AI analysis, Sentry ingest, GitHub
/// ticketing/draft PRs, and in-app configuration. Local tool — CORS wide open.
///
/// The server core (engines, router, static hosting) lives here; the route
/// handlers are grouped by domain in `lib/api/`:
///
/// - config_routes.dart — settings, Sentry ingest + discovery
/// - issue_routes.dart  — issue reads, triage writes, AI analysis, features
/// - github_routes.dart — tickets, draft PRs, state sync
class ApiServer {
  final TriageDb db;
  final Config cfg;
  final String? webRoot;

  late AiAnalyzer _analyzer;
  late GithubTicketer _ticketer;
  late PrMaker _prMaker;
  bool _ingestRunning = false;
  Timer? _ingestTimer;

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
      ..get('/api/health', (Request r) => _json({'ok': true, 'version': appVersion}))
      ..get('/api/health/tools', _toolsHealth)
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

    return shelf_io.serve(pipeline.addHandler(handler), host, port);
  }
}

// ── shared helpers (library-private) ────────────────────────────────

const _mask = '••••••••';

Response _json(Object? data, {int status = 200}) => Response(
      status,
      body: jsonEncode(data),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// CORS: local tool, wide open (incl. preflight).
Handler Function(Handler) get _cors => (Handler inner) {
      return (Request req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final res = await inner(req);
        return res.change(headers: _corsHeaders);
      };
    };

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept',
};
