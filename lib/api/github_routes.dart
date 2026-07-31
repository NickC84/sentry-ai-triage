part of '../api_server.dart';

/// GitHub ticketing, AI draft PRs, and state sync.
extension GithubRoutes on ApiServer {
  /// Open a GitHub issue for one item (idempotent: returns existing URL).
  Future<Response> _openTicket(Request r, String id) async {
    final row = db.issueWithAnalysis(id);
    if (row == null) return _json({'error': 'Item not found: $id'}, status: 404);
    final existing = (row['ticket_url'] ?? '').toString();
    if (existing.isNotEmpty) {
      db.setSelectedForDev(id, true);
      return _json({'ok': true, 'ticket_url': existing, 'already': true});
    }

    // Require analysis first (avoid opening empty tickets).
    final isFeature = (row['source'] ?? 'sentry') == 'feature';
    final analyzed =
        isFeature ? row['feasibility'] != null : row['severity_score'] != null;
    if (!analyzed) {
      return _json(
          {'error': 'Analyze the item first so the ticket has real content'},
          status: 400);
    }

    try {
      final t = GithubTicketer.compose(row, lang: cfg.outputLanguage);
      final url = await _ticketer.createIssue(title: t.title, body: t.body);
      db.setTicketUrl(id, url);
      db.setSelectedForDev(id, true);

      // Auto-@claude to open the discussion on the GitHub issue.
      final zh = cfg.outputLanguage == 'zh-Hant';
      final starter = isFeature
          ? (zh
              ? '@claude 這是一則新需求(見上方分析)。請先幫我把**規格與可行性討論清楚**(待澄清點、影響範圍、建議做法),**先不要改 code**;我們討論確認後,我會再留言請你依規格實作。'
              : '@claude This is a new feature request (see analysis above). Please first help clarify the **spec and feasibility** (open questions, affected areas, suggested approach) — **do not change code yet**. Once we confirm the spec, I will comment again to ask for implementation.')
          : (zh
              ? '@claude 這是一個崩潰(見上方分析)。請幫我釐清**根因與修法方向**,**先不要改 code**;討論確認後我再請你實作修復。'
              : '@claude This is a crash (see analysis above). Please help pin down the **root cause and fix direction** — **do not change code yet**. Once we agree, I will ask you to implement the fix.');
      var commentPosted = true;
      try {
        await _ticketer.addComment(url, starter);
      } catch (_) {
        commentPosted = false;
      }

      return _json({
        'ok': true,
        'ticket_url': url,
        'selected_for_dev': true,
        'claude_started': commentPosted,
      });
    } catch (e) {
      return _json({'error': 'Ticket creation failed: $e'}, status: 500);
    }
  }

  /// Open tickets for everything selected-for-dev without one.
  Future<Response> _openSelected(Request r) async {
    final ids = db.selectedWithoutTicket();
    final opened = <Map<String, Object?>>[];
    final failed = <Map<String, Object?>>[];
    for (final id in ids) {
      final row = db.issueWithAnalysis(id);
      if (row == null) continue;
      try {
        final t = GithubTicketer.compose(row, lang: cfg.outputLanguage);
        final url = await _ticketer.createIssue(title: t.title, body: t.body);
        db.setTicketUrl(id, url);
        opened.add({'sentry_issue_id': id, 'ticket_url': url});
      } catch (e) {
        failed.add({'sentry_issue_id': id, 'error': '$e'});
      }
    }
    return _json({
      'ok': true,
      'opened': opened,
      'failed': failed,
      'candidates': ids.length,
    });
  }

  /// AI draft PR for a selected-for-dev item (branch + draft PR, never merged).
  Future<Response> _draftPr(Request r, String id) async {
    final row = db.issueWithAnalysis(id);
    if (row == null) return _json({'error': 'Item not found: $id'}, status: 404);
    if ((row['selected_for_dev'] as num?)?.toInt() != 1) {
      return _json({'error': 'Select the item for development first'},
          status: 400);
    }
    final existing = (row['pr_url'] ?? '').toString();
    if (existing.isNotEmpty) {
      return _json({'ok': true, 'pr_url': existing, 'already': true});
    }
    try {
      final result = await _prMaker.makeDraftPr(
        shortId: (row['short_id'] ?? '') as String,
        title: (row['title'] ?? '') as String,
        isFeature: (row['source'] ?? 'sentry') == 'feature',
        detail: (row['detail'] ?? '') as String,
        rootCause: (row['root_cause_summary'] ?? '') as String,
        approach: (row['recommended_action'] ?? '') as String,
        affectedAreas: (row['affected_areas'] ?? '') as String,
      );
      db.setPrUrl(id, result.prUrl);
      return _json({
        'ok': true,
        'pr_url': result.prUrl,
        'branch': result.branch,
        'changed_files': result.changedFiles,
      });
    } catch (e) {
      return _json({'error': 'Draft PR failed: $e'}, status: 500);
    }
  }

  /// Sync GitHub ticket/PR states back into the DB.
  Future<Response> _syncGithub(Request r) async {
    final items = db.itemsWithGithubLinks();
    var synced = 0;
    for (final it in items) {
      final id = it['sentry_issue_id'] as String;
      final ticketUrl = (it['ticket_url'] ?? '').toString();
      final prUrl = (it['pr_url'] ?? '').toString();
      String? ticketState, prState;
      if (ticketUrl.isNotEmpty) ticketState = await _ticketer.stateOf(ticketUrl);
      if (prUrl.isNotEmpty) prState = await _ticketer.stateOf(prUrl);
      db.setGithubStates(id, ticketState: ticketState, prState: prState);
      synced++;
    }
    return _json({'ok': true, 'synced': synced});
  }
}
