import 'dart:convert';

import 'package:http/http.dart' as http;

DateTime? _parseTime(dynamic v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString());
}

/// One Sentry issue (trimmed-down fields).
class SentryIssue {
  final String id;
  final String shortId;
  final String title;
  final String culprit;
  final String level;
  final int count; // total event count
  final int userCount;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final String permalink;

  SentryIssue({
    required this.id,
    required this.shortId,
    required this.title,
    required this.culprit,
    required this.level,
    required this.count,
    required this.userCount,
    required this.firstSeen,
    required this.lastSeen,
    required this.permalink,
  });

  factory SentryIssue.fromJson(Map<String, dynamic> j) => SentryIssue(
        id: j['id'].toString(),
        shortId: (j['shortId'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        culprit: (j['culprit'] ?? '').toString(),
        level: (j['level'] ?? '').toString(),
        count: int.tryParse((j['count'] ?? '0').toString()) ?? 0,
        userCount: (j['userCount'] as num?)?.toInt() ?? 0,
        firstSeen: _parseTime(j['firstSeen']),
        lastSeen: _parseTime(j['lastSeen']),
        permalink: (j['permalink'] ?? '').toString(),
      );
}

/// Event count of one release for a given issue.
class ReleaseStat {
  final String release;
  final int count;
  final DateTime? firstSeen;
  final DateTime? lastSeen;

  ReleaseStat({
    required this.release,
    required this.count,
    required this.firstSeen,
    required this.lastSeen,
  });

  factory ReleaseStat.fromJson(Map<String, dynamic> j) => ReleaseStat(
        release: (j['value'] ?? '').toString(),
        count: (j['count'] as num?)?.toInt() ?? 0,
        firstSeen: _parseTime(j['firstSeen']),
        lastSeen: _parseTime(j['lastSeen']),
      );
}

/// Read-only client for the Sentry REST API.
class SentryClient {
  final String baseUrl;
  final String org;
  final String project;
  final String token;
  final http.Client _http = http.Client();
  static const _timeout = Duration(seconds: 30);

  SentryClient({
    required this.baseUrl,
    required this.org,
    required this.project,
    required this.token,
  });

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  /// Discover the organizations and projects a token can access — lets the
  /// Settings page offer pickers instead of asking users to type slugs.
  /// Uses GET /api/0/projects/ (each project carries its org slug) because it
  /// only needs project:read — the organizations endpoint would demand the
  /// extra org:read scope our token guide doesn't ask for.
  static Future<List<Map<String, Object?>>> discover({
    required String baseUrl,
    required String token,
  }) async {
    final client = http.Client();
    try {
      final resp = await client
          .get(Uri.parse('$baseUrl/api/0/projects/'),
              headers: {'Authorization': 'Bearer $token'})
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        throw Exception(
            'Sentry replied ${resp.statusCode} — check the token/scopes');
      }
      final byOrg = <String, List<String>>{};
      for (final p in jsonDecode(resp.body) as List<dynamic>) {
        final m = p as Map<String, dynamic>;
        final org =
            ((m['organization'] as Map<String, dynamic>?)?['slug'] ?? '')
                .toString();
        if (org.isEmpty) continue;
        byOrg.putIfAbsent(org, () => []).add(m['slug'].toString());
      }
      return [
        for (final e in byOrg.entries) {'org': e.key, 'projects': e.value}
      ];
    } finally {
      client.close();
    }
  }

  /// List issues (auto-pagination).
  Future<List<SentryIssue>> listIssues({
    String query = 'is:unresolved',
    int statsPeriodDays = 90,
    int maxPages = 20,
  }) async {
    final issues = <SentryIssue>[];
    // This endpoint's statsPeriod only accepts '' / '24h' / '14d' — no 90d.
    // Longer ranges need an absolute start/end window (ISO8601, UTC).
    final now = DateTime.now().toUtc();
    final start = now.subtract(Duration(days: statsPeriodDays));
    String iso(DateTime d) =>
        d.toIso8601String().split('.').first; // strip millis; Sentry is happier
    var url = Uri.parse('$baseUrl/api/0/projects/$org/$project/issues/')
        .replace(queryParameters: {
      'query': query,
      'start': iso(start),
      'end': iso(now),
      'utc': 'true',
      'sort': 'freq',
      'limit': '100',
    });

    var page = 0;
    while (page < maxPages) {
      final resp =
          await _http.get(url, headers: _headers).timeout(_timeout);
      if (resp.statusCode != 200) {
        throw Exception('List issues failed ${resp.statusCode}: ${resp.body}');
      }
      final list = jsonDecode(resp.body) as List<dynamic>;
      for (final j in list) {
        issues.add(SentryIssue.fromJson(j as Map<String, dynamic>));
      }
      final next = _nextCursorUrl(resp.headers['link']);
      if (next == null) break;
      url = Uri.parse(next);
      page++;
    }
    return issues;
  }

  /// Issues Sentry itself considers closed, as `id -> resolved | ignored`.
  ///
  /// Needed because the main fetch only asks for unresolved issues: without
  /// this, anything a teammate resolves in Sentry would sit in the local
  /// backlog looking active forever. Absence from the unresolved feed is not
  /// enough to conclude anything — a quiet issue is absent too — so the
  /// closed set is asked for explicitly.
  ///
  /// [truncated] reports that the page cap was hit, i.e. some closed issues
  /// were not seen this run.
  Future<({Map<String, String> statuses, bool truncated})> closedIssues({
    int statsPeriodDays = 90,
    int maxPages = 10,
  }) async {
    final statuses = <String, String>{};
    var truncated = false;
    for (final status in const ['resolved', 'ignored']) {
      final page = await _issueIds('is:$status',
          statsPeriodDays: statsPeriodDays, maxPages: maxPages);
      for (final id in page.ids) {
        statuses[id] = status;
      }
      truncated = truncated || page.truncated;
    }
    return (statuses: statuses, truncated: truncated);
  }

  /// Paginated id-only fetch (the full issue bodies are not needed here).
  Future<({List<String> ids, bool truncated})> _issueIds(
    String query, {
    required int statsPeriodDays,
    required int maxPages,
  }) async {
    final ids = <String>[];
    final now = DateTime.now().toUtc();
    final start = now.subtract(Duration(days: statsPeriodDays));
    String iso(DateTime d) => d.toIso8601String().split('.').first;

    var url = Uri.parse('$baseUrl/api/0/projects/$org/$project/issues/')
        .replace(queryParameters: {
      'query': query,
      'start': iso(start),
      'end': iso(now),
      'utc': 'true',
      'limit': '100',
    });

    for (var page = 0; page < maxPages; page++) {
      final resp = await _http.get(url, headers: _headers).timeout(_timeout);
      if (resp.statusCode != 200) {
        throw Exception('List issues ($query) failed ${resp.statusCode}: ${resp.body}');
      }
      for (final j in jsonDecode(resp.body) as List<dynamic>) {
        final id = (j as Map<String, dynamic>)['id'];
        if (id != null) ids.add(id.toString());
      }
      final next = _nextCursorUrl(resp.headers['link']);
      if (next == null) return (ids: ids, truncated: false);
      url = Uri.parse(next);
    }
    return (ids: ids, truncated: true);
  }

  /// Per-release event counts for an issue (via tag values — the
  /// "per-release frequency").
  Future<List<ReleaseStat>> releaseStats(String issueId) async {
    final url = Uri.parse('$baseUrl/api/0/issues/$issueId/tags/release/');
    final resp = await _http.get(url, headers: _headers).timeout(_timeout);
    if (resp.statusCode == 404) return []; // issue has no release tag
    if (resp.statusCode != 200) {
      throw Exception('Release tag fetch failed ${resp.statusCode}: ${resp.body}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final top = (j['topValues'] ?? []) as List<dynamic>;
    return top
        .map((e) => ReleaseStat.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Parse the next page from the Link header (rel="next" with results="true").
  String? _nextCursorUrl(String? link) {
    if (link == null) return null;
    for (final part in link.split(',')) {
      final seg = part.trim();
      if (seg.contains('rel="next"') && seg.contains('results="true"')) {
        final m = RegExp(r'<([^>]+)>').firstMatch(seg);
        if (m != null) return m.group(1);
      }
    }
    return null;
  }

  void close() => _http.close();
}
