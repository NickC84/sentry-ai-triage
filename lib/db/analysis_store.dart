part of '../db.dart';

/// AI analysis results and manual feature items (Phase 2 / 2.5).
extension AnalysisStore on TriageDb {
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
}
