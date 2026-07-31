import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'sentry_client.dart';

/// SQLite access layer: schema + upserts + triage rules + summary queries.
class TriageDb {
  final Database _db;
  TriageDb._(this._db);

  factory TriageDb.open(String path) {
    final db = sqlite3.open(path);
    final t = TriageDb._(db);
    t._migrate();
    return t;
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS issues (
        sentry_issue_id TEXT PRIMARY KEY,
        short_id        TEXT,
        title           TEXT,
        culprit         TEXT,
        level           TEXT,
        category        TEXT DEFAULT 'unknown',   -- app_bug | device_layer | network_noise | log_event | unknown
        triage_state    TEXT DEFAULT 'new',       -- new | keep | hidden | known_noise | resolved
        triage_note     TEXT,
        first_seen      TEXT,
        last_seen       TEXT,
        permalink       TEXT,
        updated_at      TEXT
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS issue_release_stats (
        sentry_issue_id       TEXT,
        release               TEXT,
        event_count           INTEGER,
        first_seen_in_release TEXT,
        last_seen_in_release  TEXT,
        PRIMARY KEY (sentry_issue_id, release)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS issue_snapshots (
        sentry_issue_id TEXT,
        captured_at     TEXT,
        total_count     INTEGER,
        user_count      INTEGER
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS triage_rules (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        match_type   TEXT,   -- title | culprit
        pattern      TEXT,
        set_category TEXT,
        set_state    TEXT,
        note         TEXT
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS ai_analysis (
        sentry_issue_id    TEXT PRIMARY KEY,
        analyzed_at        TEXT,
        severity_score     INTEGER,       -- 0–100
        is_app_fixable     TEXT,          -- app_fixable | not_fixable | needs_more_data
        root_cause_summary TEXT,
        recommended_action TEXT,
        confidence         REAL,          -- 0–1
        ticket_url         TEXT,          -- Phase 3
        pr_url             TEXT,          -- Phase 4
        model              TEXT,
        cost_usd           REAL,
        input_context_hash TEXT           -- re-run detection (cost guardrail)
      );
    ''');

    // Phase 2.5: generalize issues into a unified backlog and let
    // ai_analysis store feature analyses too. Existing DBs get the columns
    // via ALTER (CREATE IF NOT EXISTS won't add columns).
    _addColumn('issues', 'source', "TEXT DEFAULT 'sentry'"); // sentry | feature
    _addColumn('issues', 'detail', 'TEXT'); // feature description
    _addColumn('issues', 'selected_for_dev', 'INTEGER DEFAULT 0'); // manually selected for dev
    _addColumn('ai_analysis', 'feasibility', 'TEXT');
    _addColumn('ai_analysis', 'effort', 'TEXT');
    _addColumn('ai_analysis', 'priority_score', 'INTEGER');
    _addColumn('ai_analysis', 'affected_areas', 'TEXT');
    _addColumn('ai_analysis', 'risks', 'TEXT');
    // Phase 3/4 two-way sync: GitHub ticket/PR state (open|closed|merged|deleted)
    _addColumn('ai_analysis', 'ticket_state', 'TEXT');
    _addColumn('ai_analysis', 'pr_state', 'TEXT');
  }

  /// ALTER TABLE to add the column if missing (idempotent migration).
  void _addColumn(String table, String column, String typeDef) {
    final cols = _db
        .select('PRAGMA table_info($table)')
        .map((r) => r['name'] as String)
        .toSet();
    if (cols.contains(column)) return;
    _db.execute('ALTER TABLE $table ADD COLUMN $column $typeDef');
  }

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

  // ── Below: used by the Phase 1 triage UI backend ─────────────────

  /// Valid triage_state values (for API input validation).
  static const triageStates = {
    'new',
    'keep',
    'hidden',
    'known_noise',
    'resolved',
  };

  /// Valid category values (for API input validation).
  static const categories = {
    'app_bug',
    'device_layer',
    'network_noise',
    'log_event',
    'feature', // Phase 2.5: manual feature items
    'unknown',
  };

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

  /// Insert / overwrite one AI analysis result.
  void upsertAnalysis(
    String issueId, {
    required int severityScore,
    required String isAppFixable,
    required String rootCauseSummary,
    required String recommendedAction,
    required double confidence,
    required String model,
    required double costUsd,
    required String inputContextHash,
  }) {
    _db.execute('''
      INSERT INTO ai_analysis
        (sentry_issue_id, analyzed_at, severity_score, is_app_fixable,
         root_cause_summary, recommended_action, confidence, model, cost_usd,
         input_context_hash)
      VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(sentry_issue_id) DO UPDATE SET
        analyzed_at        = excluded.analyzed_at,
        severity_score     = excluded.severity_score,
        is_app_fixable     = excluded.is_app_fixable,
        root_cause_summary = excluded.root_cause_summary,
        recommended_action = excluded.recommended_action,
        confidence         = excluded.confidence,
        model              = excluded.model,
        cost_usd           = excluded.cost_usd,
        input_context_hash = excluded.input_context_hash;
    ''', [
      issueId,
      DateTime.now().toUtc().toIso8601String(),
      severityScore,
      isAppFixable,
      rootCauseSummary,
      recommendedAction,
      confidence,
      model,
      costUsd,
      inputContextHash,
    ]);
  }

  /// Fetch one issue's base fields (with latest count), regardless of triage
  /// state. Used for on-demand analysis.
  Map<String, Object?>? issueById(String id) {
    final rs = _db.select('''
      SELECT i.sentry_issue_id, i.short_id, i.title, i.culprit, i.level,
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

  // ── Phase 2.5: manual features + dev selection ───────────────────

  /// Create a feature item, returns its id. source='feature',
  /// category='feature', triage_state='new'.
  String createFeature(String title, String detail) {
    final id = 'feat-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute('''
      INSERT INTO issues
        (sentry_issue_id, short_id, title, detail, source, category,
         triage_state, first_seen, last_seen, updated_at)
      VALUES (?,?,?,?, 'feature', 'feature', 'new', ?, ?, ?);
    ''', [id, id.replaceFirst('feat-', 'FEAT-'), title, detail, now, now, now]);
    return id;
  }

  /// Toggle the manual "selected for dev" flag.
  bool setSelectedForDev(String issueId, bool selected) {
    _db.execute(
      'UPDATE issues SET selected_for_dev=?, updated_at=? WHERE sentry_issue_id=?',
      [selected ? 1 : 0, DateTime.now().toUtc().toIso8601String(), issueId],
    );
    return _db.updatedRows > 0;
  }

  /// Insert / overwrite one feature feasibility analysis.
  void upsertFeatureAnalysis(
    String issueId, {
    required String feasibility,
    required String effort,
    required int priorityScore,
    required String summary,
    required String approach,
    required String affectedAreas,
    required String risks,
    required double confidence,
    required String model,
    required double costUsd,
  }) {
    _db.execute('''
      INSERT INTO ai_analysis
        (sentry_issue_id, analyzed_at, feasibility, effort, priority_score,
         root_cause_summary, recommended_action, affected_areas, risks,
         confidence, model, cost_usd)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(sentry_issue_id) DO UPDATE SET
        analyzed_at        = excluded.analyzed_at,
        feasibility        = excluded.feasibility,
        effort             = excluded.effort,
        priority_score     = excluded.priority_score,
        root_cause_summary = excluded.root_cause_summary,
        recommended_action = excluded.recommended_action,
        affected_areas     = excluded.affected_areas,
        risks              = excluded.risks,
        confidence         = excluded.confidence,
        model              = excluded.model,
        cost_usd           = excluded.cost_usd;
    ''', [
      issueId,
      DateTime.now().toUtc().toIso8601String(),
      feasibility,
      effort,
      priorityScore,
      summary,
      approach,
      affectedAreas,
      risks,
      confidence,
      model,
      costUsd,
    ]);
  }

  // ── Phase 3: GitHub ticketing ────────────────────────────────────

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

  Map<String, Object?> _rowToMap(Row r) => {for (final k in r.keys) k: r[k]};

  void close() => _db.dispose();
}
