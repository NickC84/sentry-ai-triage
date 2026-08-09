part of '../api_server.dart';

/// Settings endpoints plus Sentry ingest / discovery.
extension ConfigRoutes on ApiServer {
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
    rescheduleIngest();
    return _json({'ok': true, 'changed': changed});
  }

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
}
