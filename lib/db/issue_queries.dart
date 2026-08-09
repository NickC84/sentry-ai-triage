part of '../db.dart';

/// Read queries and manual triage updates backing the web UI.
extension IssueQueries on TriageDb {
  /// List issues for the UI (with latest snapshot count and trend: delta vs.
  /// the previous snapshot). [includeNoise]=false excludes known_noise/hidden.
  List<Map<String, Object?>> listIssues({bool includeNoise = false}) {
    final where = includeNoise
        ? ''
        : "WHERE i.triage_state NOT IN ('known_noise','hidden')";
    final rs = _db.select('''
      SELECT
        i.sentry_issue_id, i.short_id, i.title, i.culprit, i.level,
        i.category, i.triage_state, i.triage_note,
        i.source, i.detail, i.selected_for_dev,
        i.first_seen, i.last_seen, i.permalink,
        (SELECT total_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1) AS total_count,
        (SELECT user_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1) AS user_count,
        (SELECT total_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1 OFFSET 1) AS prev_total_count,
        a.severity_score, a.is_app_fixable, a.analyzed_at,
        a.root_cause_summary, a.recommended_action, a.confidence,
        a.feasibility, a.effort, a.priority_score, a.affected_areas, a.risks,
        a.ticket_url, a.pr_url, a.ticket_state, a.pr_state
      FROM issues i
      LEFT JOIN ai_analysis a ON a.sentry_issue_id = i.sentry_issue_id
      $where
      ORDER BY total_count DESC;
    ''');
    return rs.map(_rowToMap).toList();
  }

  /// Issues above the AI analysis threshold (cost guardrail):
  /// triage_state ∈ {new, keep} and latest count ≥ [minEvents], top [limit]
  /// by count. Also returns the existing analysis' input_context_hash so the
  /// caller can decide whether a re-run is needed.
  List<Map<String, Object?>> issuesToAnalyze(
      {required int minEvents, required int limit}) {
    final rs = _db.select('''
      SELECT * FROM (
        SELECT i.sentry_issue_id, i.short_id, i.title, i.culprit, i.level,
          i.first_seen, i.last_seen,
          (SELECT total_count FROM issue_snapshots s
            WHERE s.sentry_issue_id = i.sentry_issue_id
            ORDER BY s.captured_at DESC LIMIT 1) AS total_count,
          (SELECT user_count FROM issue_snapshots s
            WHERE s.sentry_issue_id = i.sentry_issue_id
            ORDER BY s.captured_at DESC LIMIT 1) AS user_count,
          a.input_context_hash AS prev_hash
        FROM issues i
        LEFT JOIN ai_analysis a ON a.sentry_issue_id = i.sentry_issue_id
        WHERE i.triage_state IN ('new','keep')
      )
      WHERE total_count >= ?
      ORDER BY total_count DESC
      LIMIT ?;
    ''', [minEvents, limit]);
    return rs.map(_rowToMap).toList();
  }

  /// Fetch one issue's base fields (with latest count), regardless of triage
  /// state. Used for on-demand analysis.
  Map<String, Object?>? issueById(String id) {
    final rs = _db.select('''
      SELECT i.sentry_issue_id, i.short_id, i.title, i.culprit, i.level,
        i.category, i.triage_state, i.source, i.detail,
        i.first_seen, i.last_seen,
        (SELECT total_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1) AS total_count,
        (SELECT user_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1) AS user_count
      FROM issues i WHERE i.sentry_issue_id = ?;
    ''', [id]);
    return rs.isEmpty ? null : _rowToMap(rs.first);
  }

  /// Per-release frequency for one issue (highest count first).
  List<Map<String, Object?>> releaseStatsFor(String issueId) {
    final rs = _db.select('''
      SELECT release, event_count, first_seen_in_release, last_seen_in_release
      FROM issue_release_stats
      WHERE sentry_issue_id = ?
      ORDER BY event_count DESC;
    ''', [issueId]);
    return rs.map(_rowToMap).toList();
  }

  /// Manual triage update: state / category / note are all optional; only
  /// provided fields are updated. Returns whether the issue was found.
  bool updateTriage(String issueId,
      {String? state, String? category, String? note}) {
    final sets = <String>[];
    final params = <Object?>[];
    if (state != null) {
      sets.add('triage_state=?');
      params.add(state);
    }
    if (category != null) {
      sets.add('category=?');
      params.add(category);
    }
    if (note != null) {
      sets.add('triage_note=?');
      params.add(note);
    }
    if (sets.isEmpty) return false;
    sets.add('updated_at=?');
    params.add(DateTime.now().toUtc().toIso8601String());
    params.add(issueId);
    _db.execute(
      'UPDATE issues SET ${sets.join(', ')} WHERE sentry_issue_id=?',
      params,
    );
    return _db.updatedRows > 0;
  }

  /// Category distribution (for the UI header stats).
  Map<String, int> categoryCounts() {
    final rs = _db
        .select('SELECT category, COUNT(*) AS c FROM issues GROUP BY category');
    return {for (final r in rs) (r['category'] as String? ?? 'unknown'): r['c'] as int};
  }
}
