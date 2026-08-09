import 'dart:io';

import 'package:sentry_triage/api_server.dart';
import 'package:sentry_triage/app_paths.dart';
import 'package:sentry_triage/config.dart';
import 'package:sentry_triage/db.dart';
import 'package:sentry_triage/version.dart';

/// Backend entry point: serves the local API (and the built web UI).
///
///   dart run bin/serve.dart            # http://localhost:8787
///   PORT=9000 dart run bin/serve.dart  # custom port (or --port 9000)
///
/// Boots with zero configuration — open the UI and fill in Settings, then hit
/// "Sync from Sentry". No .env editing required.
Future<void> main(List<String> args) async {
  if (handledVersionFlag(args)) return;

  final cfg = Config.load();

  // Create the data dir / empty DB on first run.
  File(cfg.dbPath).parent.createSync(recursive: true);
  final db = TriageDb.open(cfg.dbPath);
  db.seedDefaultRules();

  final requestedPort = _portFrom(args);
  // Bind to localhost by default (a local tool, not a server); the Docker
  // image sets HOST=0.0.0.0 so the port can be published.
  final host = Platform.environment['HOST']?.trim().isNotEmpty == true
      ? Platform.environment['HOST']!.trim()
      : 'localhost';

  final webRoot = AppPaths.webRoot;
  final apiServer = ApiServer(db, cfg, webRoot: webRoot);

  final HttpServer server;
  try {
    server = await _listen(apiServer, host, requestedPort);
  } on SocketException catch (e) {
    stderr.writeln('❌ Could not start on $host:$requestedPort — ${e.osError?.message ?? e.message}.');
    stderr.writeln('   Free the port, or pick another: --port 9000');
    exit(1);
  }

  final base = 'http://${host == '0.0.0.0' ? 'localhost' : host}:${server.port}';
  stdout.writeln('🚀 sentry-ai-triage $appVersion is running: $base');
  if (server.port != requestedPort) {
    stdout.writeln(
        '   ℹ️ Port $requestedPort was busy — using ${server.port} instead.');
  }
  final missing = cfg.missingForIngest;
  if (missing.isNotEmpty) {
    stdout.writeln(
        '   ⚙️  Not configured yet (${missing.join(', ')}) — open Settings in the UI to get started.');
  }
  final hasUi = Directory(webRoot).existsSync();
  if (hasUi) {
    stdout.writeln('   🌐 UI: $base');
  } else {
    stdout.writeln(
        '   ℹ️ Web UI not built yet. Run: cd ui && flutter build web --no-web-resources-cdn');
  }
  stdout.writeln('   Ctrl-C to stop.');

  // After the banner so the schedule notice reads as part of it.
  apiServer.rescheduleIngest();

  // Auto-open the browser when the UI is available (disable with NO_OPEN=1).
  if (hasUi && Platform.environment['NO_OPEN'] != '1') {
    _openBrowser(base);
  }

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n👋 Shutting down…');
    await server.close(force: true);
    db.close();
    exit(0);
  });
}

/// Requested port: `--port N` (or `-p N`) > `PORT` env > 8787.
int _portFrom(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if ((a == '--port' || a == '-p') && i + 1 < args.length) {
      final v = int.tryParse(args[i + 1]);
      if (v != null) return v;
    }
    if (a.startsWith('--port=')) {
      final v = int.tryParse(a.substring('--port='.length));
      if (v != null) return v;
    }
  }
  return int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
}

/// Start on [port], stepping up to the next free one when it is taken — a
/// second copy of the tool (or any other :8787 process) shouldn't be a dead end.
Future<HttpServer> _listen(ApiServer apiServer, String host, int port) async {
  const maxAttempts = 20;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await apiServer.start(host: host, port: port + attempt);
    } on SocketException {
      if (attempt == maxAttempts - 1) rethrow;
    }
  }
  throw StateError('unreachable');
}

/// Best-effort cross-platform browser open; failure never affects the server.
void _openBrowser(String url) {
  try {
    if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [url]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', url]);
    }
  } catch (_) {}
}
