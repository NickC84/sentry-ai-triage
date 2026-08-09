part of '../api_server.dart';

/// Unattended re-ingest, for installs that live on a server rather than a
/// laptop. Off by default (`INGEST_INTERVAL_HOURS=0`).
///
/// Only ingest is automated. Analysis stays a deliberate act because it
/// spends AI budget; ingest is free and is what goes stale.
extension IngestScheduler on ApiServer {
  /// Apply the current interval — called once the server is up and again
  /// whenever settings are saved, so changing the interval takes effect
  /// without a restart.
  void rescheduleIngest() {
    _ingestTimer?.cancel();
    _ingestTimer = null;

    final hours = cfg.ingestIntervalHours;
    if (hours <= 0) return;

    _ingestTimer =
        Timer.periodic(Duration(hours: hours), (_) => _scheduledIngest());
    stdout.writeln('   ⏱️  Auto-sync from Sentry every ${hours}h.');
  }

  Future<void> _scheduledIngest() async {
    // A manual sync from the UI wins; skipping is better than queueing.
    if (_ingestRunning) return;
    if (cfg.missingForIngest.isNotEmpty) return;

    _ingestRunning = true;
    try {
      final summary = await runIngest(cfg, db);
      stdout.writeln(
          '⏱️  Auto-sync: ${summary.fetched} issues, ${summary.rulesApplied} rule hits.');
    } catch (e) {
      stderr.writeln('⏱️  Auto-sync failed: $e');
    } finally {
      _ingestRunning = false;
    }
  }
}
