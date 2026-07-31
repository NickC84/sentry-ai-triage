part of '../db.dart';

/// Sentry ingest writes, triage rules, and CLI summary queries.
extension IngestStore on TriageDb {
  /// Upsert an issue, preserving any manually set triage_state.
  void upsertIssue(SentryIssue i) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute('''
      INSERT INTO issues
        (sentry_issue_id, short_id, title, culprit, level, first_seen, last_seen, permalink, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(sentry_issue_id) DO UPDATE SET
        short_id   = excluded.short_id,
        title      = excluded.title,
        culprit    = excluded.culprit,
        level      = excluded.level,
        last_seen  = excluded.last_seen,
        permalink  = excluded.permalink,
        updated_at = excluded.updated_at;
    ''', [
      i.id,
      i.shortId,
      i.title,
      i.culprit,
      i.level,
      i.firstSeen?.toIso8601String(),
      i.lastSeen?.toIso8601String(),
      i.permalink,
      now,
    ]);
  }

  /// Write one snapshot per ingest for long-term trends (not limited by
  /// Sentry's retention window).
  void insertSnapshot(SentryIssue i) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO issue_snapshots (sentry_issue_id, captured_at, total_count, user_count) VALUES (?,?,?,?)',
      [i.id, now, i.count, i.userCount],
    );
  }

  void upsertReleaseStat(String issueId, ReleaseStat r) {
    _db.execute('''
      INSERT INTO issue_release_stats
        (sentry_issue_id, release, event_count, first_seen_in_release, last_seen_in_release)
      VALUES (?,?,?,?,?)
      ON CONFLICT(sentry_issue_id, release) DO UPDATE SET
        event_count          = excluded.event_count,
        last_seen_in_release = excluded.last_seen_in_release;
    ''', [
      issueId,
      r.release,
      r.count,
      r.firstSeen?.toIso8601String(),
      r.lastSeen?.toIso8601String(),
    ]);
  }

  /// Seed default triage rules from rules/default_rules.json.
  /// Idempotent on (match_type, pattern): existing rules are never overwritten
  /// (manual tweaks survive), new defaults get added on the next run.
  ///
  /// match_type: title | culprit | any (either field matches). Native-stack
  /// signatures (libGLES_mali / MarkCompact / acquireLatestImage) usually live
  /// in culprit rather than title, hence 'any'.
  void seedDefaultRules({String rulesPath = 'rules/default_rules.json'}) {
    List<List<String>> defaults = [];
    final f = File(rulesPath);
    if (f.existsSync()) {
      try {
        final doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final rules = (doc['rules'] as List?) ?? [];
        defaults = rules
            .whereType<Map<String, dynamic>>()
            .map((r) => [
                  (r['match_type'] ?? 'any').toString(),
                  (r['pattern'] ?? '').toString(),
                  (r['set_category'] ?? 'unknown').toString(),
                  (r['set_state'] ?? 'known_noise').toString(),
                  (r['note'] ?? '').toString(),
                ])
            .where((r) => r[1].isNotEmpty)
            .toList();
      } catch (e) {
        stderr.writeln('⚠️ Failed to parse $rulesPath: $e (skipping seed)');
      }
    }
    for (final d in defaults) {
      final exists = _db.select(
        'SELECT 1 FROM triage_rules WHERE match_type=? AND pattern=? LIMIT 1',
        [d[0], d[1]],
      );
      if (exists.isNotEmpty) continue;
      _db.execute(
        'INSERT INTO triage_rules (match_type, pattern, set_category, set_state, note) VALUES (?,?,?,?,?)',
        d,
      );
    }
  }

  /// Apply triage rules. Only touches triage_state='new' (never overrides a
  /// human decision). Returns the number of matches.
  /// match_type supports title | culprit | any; unknown types are skipped
  /// with a warning. Uses instr() for substring matching (not LIKE '%..%')
  /// so `_`/`%` inside patterns aren't treated as LIKE wildcards.
  int applyRules() {
    final rules = _db.select(
        'SELECT match_type, pattern, set_category, set_state FROM triage_rules');
    var applied = 0;
    for (final r in rules) {
      final matchType = (r['match_type'] as String?) ?? 'title';
      final pattern = r['pattern'] as String;
      final setCat = r['set_category'] as String;
      final setState = r['set_state'] as String;

      final String cond;
      final List<Object?> params;
      switch (matchType) {
        case 'title':
        case 'culprit':
          // matchType is one of two literals (not user input) — safe to interpolate.
          cond = 'instr(lower($matchType), lower(?)) > 0';
          params = [pattern];
        case 'any':
          cond =
              '(instr(lower(title), lower(?)) > 0 OR instr(lower(culprit), lower(?)) > 0)';
          params = [pattern, pattern];
        default:
          stderr.writeln('   ⚠️ skipping unknown match_type=$matchType (pattern=$pattern)');
          continue;
      }

      final matched = _db.select(
        "SELECT sentry_issue_id FROM issues WHERE triage_state='new' AND $cond",
        params,
      );
      for (final m in matched) {
        _db.execute(
          'UPDATE issues SET category=?, triage_state=? WHERE sentry_issue_id=?',
          [setCat, setState, m['sentry_issue_id']],
        );
        applied++;
      }
    }
    return applied;
  }

  /// Issues worth per-release stats: only triage_state ∈ {new, keep}
  /// (skipping known_noise/hidden), top [limit] by latest count — so the API
  /// budget isn't spent on device noise.
  List<Map<String, Object?>> issuesForReleaseStats({int limit = 50}) {
    final rs = _db.select('''
      SELECT i.sentry_issue_id, i.short_id,
        (SELECT total_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY captured_at DESC LIMIT 1) AS total_count
      FROM issues i
      WHERE i.triage_state IN ('new','keep')
      ORDER BY total_count DESC
      LIMIT ?;
    ''', [limit]);
    return rs.map((r) => {for (final k in r.keys) k: r[k]}).toList();
  }

  Map<String, int> stateCounts() {
    final rs = _db
        .select('SELECT triage_state, COUNT(*) AS c FROM issues GROUP BY triage_state');
    return {for (final r in rs) r['triage_state'] as String: r['c'] as int};
  }

  /// Issues worth looking at (excludes known_noise / hidden by default),
  /// ordered by latest count.
  List<Map<String, Object?>> summaryRows({int limit = 20, bool includeNoise = false}) {
    final where = includeNoise
        ? ''
        : "WHERE triage_state NOT IN ('known_noise','hidden')";
    final rs = _db.select('''
      SELECT i.sentry_issue_id, i.short_id, i.title, i.category, i.triage_state, i.last_seen,
        (SELECT total_count FROM issue_snapshots s
          WHERE s.sentry_issue_id = i.sentry_issue_id
          ORDER BY captured_at DESC LIMIT 1) AS total_count
      FROM issues i
      $where
      ORDER BY total_count DESC
      LIMIT ?;
    ''', [limit]);
    return rs
        .map((r) => {for (final k in r.keys) k: r[k]})
        .toList();
  }
}
