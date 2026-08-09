part of '../api_server.dart';

/// Environment self-diagnosis for the Settings page.
///
/// The only hard prerequisite left is a logged-in Claude CLI, so "is it
/// installed, is it logged in, can it reach my repo" is exactly where new
/// installs get stuck — and the one thing a user cannot debug from inside a
/// browser tab.
extension HealthRoutes on ApiServer {
  Future<Response> _toolsHealth(Request r) async {
    final checks = await runEnvChecks(cfg);
    return _json({
      'version': appVersion,
      'checks': [for (final c in checks) c.toJson()],
    });
  }
}
