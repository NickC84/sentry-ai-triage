import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'sentry_client.dart';

part 'db/ingest_store.dart';
part 'db/issue_queries.dart';
part 'db/analysis_store.dart';
part 'db/github_store.dart';

/// SQLite access layer. The schema and connection live here; the query and
/// write methods are grouped by domain in `lib/db/`:
///
/// - ingest_store.dart   — Sentry ingest writes + triage rules + summaries
/// - issue_queries.dart  — UI reads and manual triage updates
/// - analysis_store.dart — AI analysis + feature items
/// - github_store.dart   — ticket / PR links and state sync
class TriageDb {
  final Database _db;
  TriageDb._(this._db);

  factory TriageDb.open(String path) {
    final db = sqlite3.open(path);
    final t = TriageDb._(db);
    t._migrate();
    return t;
  }

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

  Map<String, Object?> _rowToMap(Row r) => {for (final k in r.keys) k: r[k]};

  void close() => _db.dispose();
}
