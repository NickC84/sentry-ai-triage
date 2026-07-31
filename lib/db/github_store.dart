part of '../db.dart';

/// GitHub ticket / PR links and their synced states (Phase 3 / 4).
extension GithubStore on TriageDb {
  /// Fetch one issue/feature plus its AI analysis (for building the ticket
  /// body), regardless of triage state.
  Map<String, Object?>? issueWithAnalysis(String id) {
    final rs = _db.select('''
      SELECT i.sentry_issue_id, i.short_id, i.title, i.culprit, i.level,
        i.category, i.source, i.detail, i.permalink, i.selected_for_dev,
        (SELECT total_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1) AS total_count,
        (SELECT user_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY s.captured_at DESC LIMIT 1) AS user_count,
        a.severity_score, a.is_app_fixable, a.root_cause_summary,
        a.recommended_action, a.confidence, a.feasibility, a.effort,
        a.priority_score, a.affected_areas, a.risks, a.ticket_url, a.pr_url
      FROM issues i
      LEFT JOIN ai_analysis a ON a.sentry_issue_id = i.sentry_issue_id
      WHERE i.sentry_issue_id = ?;
    ''', [id]);
    return rs.isEmpty ? null : _rowToMap(rs.first);
  }

  /// Store the ticket URL (for dedupe). Creates the ai_analysis row first if
  /// it doesn't exist yet.
  void setTicketUrl(String issueId, String url) {
    _db.execute('''
      INSERT INTO ai_analysis (sentry_issue_id, ticket_url)
      VALUES (?, ?)
      ON CONFLICT(sentry_issue_id) DO UPDATE SET ticket_url = excluded.ticket_url;
    ''', [issueId, url]);
  }

  /// Store the draft PR URL (Phase 4).
  void setPrUrl(String issueId, String url) {
    _db.execute('''
      INSERT INTO ai_analysis (sentry_issue_id, pr_url)
      VALUES (?, ?)
      ON CONFLICT(sentry_issue_id) DO UPDATE SET pr_url = excluded.pr_url;
    ''', [issueId, url]);
  }

  /// Items that have a ticket or PR (for syncing GitHub state).
  List<Map<String, Object?>> itemsWithGithubLinks() {
    final rs = _db.select('''
      SELECT sentry_issue_id, ticket_url, pr_url
      FROM ai_analysis
      WHERE (ticket_url IS NOT NULL AND ticket_url != '')
         OR (pr_url IS NOT NULL AND pr_url != '');
    ''');
    return rs.map(_rowToMap).toList();
  }

  /// Store current GitHub ticket/PR state (only fields provided).
  void setGithubStates(String issueId, {String? ticketState, String? prState}) {
    final sets = <String>[];
    final params = <Object?>[];
    if (ticketState != null) {
      sets.add('ticket_state=?');
      params.add(ticketState);
    }
    if (prState != null) {
      sets.add('pr_state=?');
      params.add(prState);
    }
    if (sets.isEmpty) return;
    params.add(issueId);
    _db.execute(
      'UPDATE ai_analysis SET ${sets.join(', ')} WHERE sentry_issue_id=?',
      params,
    );
  }

  /// Delete an item (cascading its analysis/snapshots/release stats).
  /// Returns whether anything was deleted. Note: Sentry-sourced issues come
  /// back on the next ingest; this mainly serves manual feature items.
  bool deleteIssue(String id) {
    _db.execute('DELETE FROM ai_analysis WHERE sentry_issue_id = ?', [id]);
    _db.execute('DELETE FROM issue_release_stats WHERE sentry_issue_id = ?', [id]);
    _db.execute('DELETE FROM issue_snapshots WHERE sentry_issue_id = ?', [id]);
    _db.execute('DELETE FROM issues WHERE sentry_issue_id = ?', [id]);
    return _db.updatedRows > 0;
  }

  /// Ids of items selected for dev that don't have a ticket yet.
  List<String> selectedWithoutTicket() {
    final rs = _db.select('''
      SELECT i.sentry_issue_id
      FROM issues i
      LEFT JOIN ai_analysis a ON a.sentry_issue_id = i.sentry_issue_id
      WHERE i.selected_for_dev = 1
        AND (a.ticket_url IS NULL OR a.ticket_url = '');
    ''');
    return rs.map((r) => r['sentry_issue_id'] as String).toList();
  }
}
