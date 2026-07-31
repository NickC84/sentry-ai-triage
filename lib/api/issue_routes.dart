part of '../api_server.dart';

/// Issue reads, manual triage writes, AI analysis, and feature items.
extension IssueRoutes on ApiServer {
  Response _summary(Request r) => _json({
        'states': db.stateCounts(),
        'categories': db.categoryCounts(),
      });

  Response _listIssues(Request r) {
    final includeNoise = r.url.queryParameters['include_noise'] == 'true';
    return _json({'issues': db.listIssues(includeNoise: includeNoise)});
  }

  Response _releases(Request r, String id) =>
      _json({'releases': db.releaseStatsFor(id)});

  Future<Response> _setState(Request r, String id) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }

    final state = body['triage_state']?.toString();
    final category = body['category']?.toString();
    final note = body['triage_note']?.toString();

    if (state == null && category == null && note == null) {
      return _json(
          {'error': 'Provide at least one of triage_state / category / triage_note'},
          status: 400);
    }
    if (state != null && !TriageDb.triageStates.contains(state)) {
      return _json({
        'error': 'Invalid triage_state: $state',
        'allowed': TriageDb.triageStates.toList(),
      }, status: 400);
    }
    if (category != null && !TriageDb.categories.contains(category)) {
      return _json({
        'error': 'Invalid category: $category',
        'allowed': TriageDb.categories.toList(),
      }, status: 400);
    }

    final found =
        db.updateTriage(id, state: state, category: category, note: note);
    if (!found) return _json({'error': 'Issue not found: $id'}, status: 404);
    return _json({
      'ok': true,
      'sentry_issue_id': id,
      if (state != null) 'triage_state': state,
      if (category != null) 'category': category,
    });
  }

  /// On-demand AI analysis for a single issue (bypasses threshold/cache).
  Future<Response> _analyze(Request r, String id) async {
    final issue = db.issueById(id);
    if (issue == null) return _json({'error': 'Issue not found: $id'}, status: 404);

    final releases = db.releaseStatsFor(id);
    final total = (issue['total_count'] as num?)?.toInt() ?? 0;
    try {
      final result = await _analyzer.analyze(
        shortId: (issue['short_id'] ?? '') as String,
        title: (issue['title'] ?? '') as String,
        culprit: (issue['culprit'] ?? '') as String,
        level: (issue['level'] ?? '') as String,
        totalCount: total,
        userCount: (issue['user_count'] as num?)?.toInt() ?? 0,
        firstSeen: issue['first_seen'] as String?,
        lastSeen: issue['last_seen'] as String?,
        releaseLines: releases
            .map((r) => '${r['release']} → ${r['event_count']}')
            .toList(),
      );
      final hash = AiAnalyzer.fingerprint(
        title: (issue['title'] ?? '') as String,
        culprit: (issue['culprit'] ?? '') as String,
        level: (issue['level'] ?? '') as String,
        releases:
            releases.map((r) => (r['release'] ?? '').toString()).toList(),
        totalCount: total,
      );
      db.upsertAnalysis(
        id,
        severityScore: result.severityScore,
        isAppFixable: result.isAppFixable,
        rootCauseSummary: result.rootCauseSummary,
        recommendedAction: result.recommendedAction,
        confidence: result.confidence,
        model: result.model,
        costUsd: result.costUsd,
        inputContextHash: hash,
      );
      return _json({
        'ok': true,
        'severity_score': result.severityScore,
        'is_app_fixable': result.isAppFixable,
        'root_cause_summary': result.rootCauseSummary,
        'recommended_action': result.recommendedAction,
        'confidence': result.confidence,
        'model': result.model,
        'cost_usd': result.costUsd,
      });
    } catch (e) {
      return _json({'error': 'AI analysis failed: $e'}, status: 500);
    }
  }

  /// Create a manual feature/backlog item. body: {title, detail?}
  Future<Response> _createFeature(Request r) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }
    final title = (body['title'] ?? '').toString().trim();
    if (title.isEmpty) return _json({'error': 'Title is required'}, status: 400);
    final detail = (body['detail'] ?? '').toString();
    final id = db.createFeature(title, detail);
    return _json({'ok': true, 'sentry_issue_id': id});
  }

  /// Repo-reading feasibility analysis for a feature.
  Future<Response> _analyzeFeature(Request r, String id) async {
    final issue = db.issueById(id);
    if (issue == null) return _json({'error': 'Item not found: $id'}, status: 404);
    final title = (issue['title'] ?? '') as String;
    final detail = (issue['detail'] ?? '') as String;
    try {
      final f = await _analyzer.analyzeFeature(
          title: title, detail: detail, repoPath: cfg.appRepoPath);
      db.upsertFeatureAnalysis(
        id,
        feasibility: f.feasibility,
        effort: f.effort,
        priorityScore: f.priorityScore,
        summary: f.summary,
        approach: f.approach,
        affectedAreas: f.affectedAreas,
        risks: f.risks,
        confidence: f.confidence,
        model: f.model,
        costUsd: f.costUsd,
      );
      return _json({
        'ok': true,
        'feasibility': f.feasibility,
        'effort': f.effort,
        'priority_score': f.priorityScore,
        'summary': f.summary,
        'approach': f.approach,
        'affected_areas': f.affectedAreas,
        'risks': f.risks,
        'confidence': f.confidence,
        'model': f.model,
        'cost_usd': f.costUsd,
      });
    } catch (e) {
      return _json({'error': 'Feature analysis failed: $e'}, status: 500);
    }
  }

  /// Toggle "selected for development". body: {selected: bool}
  Future<Response> _select(Request r, String id) async {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _json({'error': 'Invalid JSON'}, status: 400);
    }
    final selected = body['selected'] == true;
    final found = db.setSelectedForDev(id, selected);
    if (!found) return _json({'error': 'Item not found: $id'}, status: 404);
    return _json({'ok': true, 'selected_for_dev': selected});
  }

  /// Delete an item (mainly for manual features; Sentry issues come back on
  /// the next ingest).
  Response _delete(Request r, String id) {
    final ok = db.deleteIssue(id);
    if (!ok) return _json({'error': 'Item not found: $id'}, status: 404);
    return _json({'ok': true});
  }
}
