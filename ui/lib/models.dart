/// One issue as served by the backend /api/issues.
class Issue {
  final String id;
  final String shortId;
  final String title;
  final String culprit;
  final String level;
  final String category;
  final String triageState;
  final String? triageNote;
  final String? firstSeen;
  final String? lastSeen;
  final String permalink;
  final int totalCount;
  final int userCount;
  final int? prevTotalCount;

  // Phase 2 AI analysis (null = not analyzed yet)
  final int? severityScore;
  final String? isAppFixable;
  final String? analyzedAt;
  final String? rootCauseSummary;
  final String? recommendedAction;
  final double? confidence;

  // Phase 2.5 unified backlog / feature items
  final String source; // sentry | feature
  final String? detail; // feature description
  final bool selectedForDev;
  final String? feasibility; // feasible | hard | blocked | needs_info
  final String? effort; // S | M | L | XL
  final int? priorityScore;
  final String? affectedAreas;
  final String? risks;
  final String? ticketUrl; // Phase 3: opened GitHub ticket
  final String? prUrl; // Phase 4: opened draft PR
  final String? ticketState; // GitHub state: open|closed|deleted
  final String? prState; // GitHub state: open|closed|merged|deleted

  bool get isFeature => source == 'feature';

  /// Unified priority (0–100, null = not analyzed): features use the AI's
  /// suggested priority, bugs use severity (which already factors in
  /// frequency / affected users). Used to sort bugs and features together.
  int? get priority => isFeature ? priorityScore : severityScore;

  /// Whether AI analysis ran (feasibility for features, severity for bugs).
  /// Ticketing is disabled until analyzed.
  bool get analyzed => isFeature ? feasibility != null : severityScore != null;

  Issue({
    required this.id,
    required this.shortId,
    required this.title,
    required this.culprit,
    required this.level,
    required this.category,
    required this.triageState,
    required this.triageNote,
    required this.firstSeen,
    required this.lastSeen,
    required this.permalink,
    required this.totalCount,
    required this.userCount,
    required this.prevTotalCount,
    this.severityScore,
    this.isAppFixable,
    this.analyzedAt,
    this.rootCauseSummary,
    this.recommendedAction,
    this.confidence,
    this.source = 'sentry',
    this.detail,
    this.selectedForDev = false,
    this.feasibility,
    this.effort,
    this.priorityScore,
    this.affectedAreas,
    this.risks,
    this.ticketUrl,
    this.prUrl,
    this.ticketState,
    this.prState,
  });

  /// Change vs. the previous snapshot (null = no earlier snapshot).
  int? get delta =>
      prevTotalCount == null ? null : totalCount - prevTotalCount!;

  factory Issue.fromJson(Map<String, dynamic> j) => Issue(
        id: j['sentry_issue_id'].toString(),
        shortId: (j['short_id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        culprit: (j['culprit'] ?? '').toString(),
        level: (j['level'] ?? '').toString(),
        category: (j['category'] ?? 'unknown').toString(),
        triageState: (j['triage_state'] ?? 'new').toString(),
        triageNote: j['triage_note']?.toString(),
        firstSeen: j['first_seen']?.toString(),
        lastSeen: j['last_seen']?.toString(),
        permalink: (j['permalink'] ?? '').toString(),
        totalCount: (j['total_count'] as num?)?.toInt() ?? 0,
        userCount: (j['user_count'] as num?)?.toInt() ?? 0,
        prevTotalCount: (j['prev_total_count'] as num?)?.toInt(),
        severityScore: (j['severity_score'] as num?)?.toInt(),
        isAppFixable: j['is_app_fixable']?.toString(),
        analyzedAt: j['analyzed_at']?.toString(),
        rootCauseSummary: j['root_cause_summary']?.toString(),
        recommendedAction: j['recommended_action']?.toString(),
        confidence: (j['confidence'] as num?)?.toDouble(),
        source: (j['source'] ?? 'sentry').toString(),
        detail: j['detail']?.toString(),
        selectedForDev: (j['selected_for_dev'] as num?)?.toInt() == 1,
        feasibility: j['feasibility']?.toString(),
        effort: j['effort']?.toString(),
        priorityScore: (j['priority_score'] as num?)?.toInt(),
        affectedAreas: j['affected_areas']?.toString(),
        risks: j['risks']?.toString(),
        ticketUrl: j['ticket_url']?.toString(),
        prUrl: j['pr_url']?.toString(),
        ticketState: j['ticket_state']?.toString(),
        prState: j['pr_state']?.toString(),
      );

  Issue _copy({
    String? ticketUrl,
    String? prUrl,
    int? severityScore,
    String? isAppFixable,
    String? rootCauseSummary,
    String? recommendedAction,
    double? confidence,
    bool? selectedForDev,
    String? feasibility,
    String? effort,
    int? priorityScore,
    String? affectedAreas,
    String? risks,
  }) =>
      Issue(
        id: id,
        shortId: shortId,
        title: title,
        culprit: culprit,
        level: level,
        category: category,
        triageState: triageState,
        triageNote: triageNote,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
        permalink: permalink,
        totalCount: totalCount,
        userCount: userCount,
        prevTotalCount: prevTotalCount,
        analyzedAt: DateTime.now().toIso8601String(),
        source: source,
        detail: detail,
        severityScore: severityScore ?? this.severityScore,
        isAppFixable: isAppFixable ?? this.isAppFixable,
        rootCauseSummary: rootCauseSummary ?? this.rootCauseSummary,
        recommendedAction: recommendedAction ?? this.recommendedAction,
        confidence: confidence ?? this.confidence,
        selectedForDev: selectedForDev ?? this.selectedForDev,
        feasibility: feasibility ?? this.feasibility,
        effort: effort ?? this.effort,
        priorityScore: priorityScore ?? this.priorityScore,
        affectedAreas: affectedAreas ?? this.affectedAreas,
        risks: risks ?? this.risks,
        ticketUrl: ticketUrl ?? this.ticketUrl,
        prUrl: prUrl ?? this.prUrl,
        ticketState: ticketState,
        prState: prState,
      );

  /// Apply a bug analysis result to the UI.
  Issue withAnalysis(Map<String, dynamic> a) => _copy(
        severityScore: (a['severity_score'] as num?)?.toInt(),
        isAppFixable: a['is_app_fixable']?.toString(),
        rootCauseSummary: a['root_cause_summary']?.toString(),
        recommendedAction: a['recommended_action']?.toString(),
        confidence: (a['confidence'] as num?)?.toDouble(),
      );

  /// Apply a feature feasibility result to the UI.
  Issue withFeatureAnalysis(Map<String, dynamic> a) => _copy(
        feasibility: a['feasibility']?.toString(),
        effort: a['effort']?.toString(),
        priorityScore: (a['priority_score'] as num?)?.toInt(),
        rootCauseSummary: a['summary']?.toString(),
        recommendedAction: a['approach']?.toString(),
        affectedAreas: a['affected_areas']?.toString(),
        risks: a['risks']?.toString(),
        confidence: (a['confidence'] as num?)?.toDouble(),
      );

  Issue withSelected(bool v) => _copy(selectedForDev: v);
  Issue withTicket(String url) => _copy(ticketUrl: url);
  Issue withPr(String url) => _copy(prUrl: url);
}

/// Event count of an issue within one release.
class ReleaseStat {
  final String release;
  final int eventCount;

  ReleaseStat({required this.release, required this.eventCount});

  /// Keep only the version+build tail, e.g. com.foo@1.5.51+130 → 1.5.51+130.
  String get shortRelease {
    final at = release.lastIndexOf('@');
    return at >= 0 ? release.substring(at + 1) : release;
  }

  factory ReleaseStat.fromJson(Map<String, dynamic> j) => ReleaseStat(
        release: (j['release'] ?? '').toString(),
        eventCount: (j['event_count'] as num?)?.toInt() ?? 0,
      );
}

/// Header stats.
class Summary {
  final Map<String, int> states;
  final Map<String, int> categories;
  Summary({required this.states, required this.categories});

  factory Summary.fromJson(Map<String, dynamic> j) => Summary(
        states: _toIntMap(j['states']),
        categories: _toIntMap(j['categories']),
      );

  static Map<String, int> _toIntMap(dynamic m) => (m as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, (v as num).toInt())) ??
      {};
}
