import 'dart:io';

import 'package:sentry_triage/api_server.dart';
import 'package:sentry_triage/config.dart';
import 'package:sentry_triage/db.dart';

/// Backend entry point: serves the local API (and the built web UI).
///
///   dart run bin/serve.dart            # http://localhost:8787
///   PORT=9000 dart run bin/serve.dart  # custom port
///
/// Boots with zero configuration — open the UI and fill in Settings, then hit
/// "Sync from Sentry". No .env editing required.
Future<void> main(List<String> args) async {
  final cfg = Config.load();

  // Create the data dir / empty DB on first run.
  File(cfg.dbPath).parent.createSync(recursive: true);
  final db = TriageDb.open(cfg.dbPath);
  db.seedDefaultRules();

  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;

  const webRoot = 'ui/build/web';
  final server = await ApiServer(db, cfg, webRoot: webRoot).start(port: port);

  final base = 'http://${server.address.host}:${server.port}';
  stdout.writeln('🚀 sentry-ai-triage is running: $base');
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
