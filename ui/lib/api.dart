import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Client for the local triage backend.
///
/// - When the UI is served by the backend itself (dart run bin/serve.dart,
///   then open http://localhost:8787), leave baseUrl empty (same origin).
/// - During development with `flutter run -d chrome` the frontend runs on a
///   different port, so point it at the backend:
///   flutter run -d chrome --dart-define=API_BASE=http://localhost:8787
class TriageApi {
  final String baseUrl;

  TriageApi({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment('API_BASE', defaultValue: '');

  Future<Summary> summary() async {
    final j = await _getJson('/api/summary');
    return Summary.fromJson(j);
  }

  Future<List<Issue>> issues({bool includeNoise = false}) async {
    final j = await _getJson('/api/issues?include_noise=$includeNoise');
    final list = (j['issues'] as List<dynamic>);
    return list
        .map((e) => Issue.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ReleaseStat>> releases(String issueId) async {
    final j = await _getJson('/api/issues/$issueId/releases');
    final list = (j['releases'] as List<dynamic>);
    return list
        .map((e) => ReleaseStat.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Update triage: pass at least one of state / category / note.
  Future<void> updateTriage(String issueId,
      {String? state, String? category, String? note}) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/state'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        if (state != null) 'triage_state': state,
        if (category != null) 'category': category,
        if (note != null) 'triage_note': note,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('Update failed ${resp.statusCode}: ${resp.body}');
    }
  }

  /// Run on-demand AI analysis for one issue (takes ~15–30s). Returns the result.
  Future<Map<String, dynamic>> analyze(String issueId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/analyze'),
    );
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Analysis failed ${resp.statusCode}');
    }
    return body;
  }

  /// Phase 2.5: create a feature item, returns its id.
  Future<String> createFeature(String title, String detail) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/features'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'title': title, 'detail': detail}),
    );
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Create feature failed');
    }
    return body['sentry_issue_id'].toString();
  }

  /// Phase 2.5: feature feasibility analysis (reads the repo, takes ~1–5 min).
  Future<Map<String, dynamic>> analyzeFeature(String issueId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/analyze-feature'),
    );
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Feasibility analysis failed');
    }
    return body;
  }

  /// Phase 2.5: toggle "selected for dev".
  Future<void> setSelected(String issueId, bool selected) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/select'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'selected': selected}),
    );
    if (resp.statusCode != 200) {
      throw Exception('Update failed ${resp.statusCode}');
    }
  }

  /// Phase 3: open a GitHub ticket for one item; result includes ticket_url.
  Future<Map<String, dynamic>> openTicket(String issueId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/ticket'),
    );
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Ticket creation failed');
    }
    return body;
  }

  /// Phase 3: open tickets for every selected-but-unticketed item; returns a summary.
  Future<Map<String, dynamic>> openSelectedTickets() async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/tickets/open-selected'),
    );
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Bulk ticket creation failed');
    }
    return body;
  }

  /// Phase 4: generate an AI draft PR for a selected item (takes minutes).
  Future<Map<String, dynamic>> draftPr(String issueId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/draft-pr'),
    );
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Draft PR failed');
    }
    return body;
  }

  /// Sync current ticket/PR states from GitHub. Returns how many were synced.
  Future<int> syncGithub() async {
    final resp = await http.post(Uri.parse('$baseUrl/api/sync-github'));
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Sync failed');
    }
    return (body['synced'] as num?)?.toInt() ?? 0;
  }

  /// Delete an item (mainly for manually created features).
  Future<void> deleteIssue(String issueId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/issues/$issueId/delete'),
    );
    if (resp.statusCode != 200) {
      throw Exception('Delete failed ${resp.statusCode}');
    }
  }

  /// Settings: read current config (secrets masked by the server).
  Future<Map<String, dynamic>> getConfig() => _getJson('/api/config');

  /// Settings: save config values.
  Future<void> saveConfig(Map<String, String> values) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/config'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(values),
    );
    if (resp.statusCode != 200) {
      final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['error']?.toString() ?? 'Save failed ${resp.statusCode}');
    }
  }

  /// Trigger a Sentry ingest run; returns the summary map.
  Future<Map<String, dynamic>> ingest() async {
    final resp = await http.post(Uri.parse('$baseUrl/api/ingest'));
    final body = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'Ingest failed ${resp.statusCode}');
    }
    return body;
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final resp = await http.get(Uri.parse('$baseUrl$path'));
    if (resp.statusCode != 200) {
      throw Exception('$path failed ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }
}
