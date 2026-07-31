// main.dart depends on dart:html (web-only) and can't be imported in a VM
// widget test, so this file tests the pure data models instead (VM-safe).
import 'package:flutter_test/flutter_test.dart';
import 'package:triage_ui/models.dart';

void main() {
  test('Issue.delta vs. previous snapshot', () {
    final i = Issue.fromJson({
      'sentry_issue_id': '1',
      'total_count': 120,
      'prev_total_count': 100,
    });
    expect(i.delta, 20);
  });

  test('Issue.delta is null without a previous snapshot', () {
    final i = Issue.fromJson({'sentry_issue_id': '1', 'total_count': 120});
    expect(i.delta, isNull);
  });

  test('ReleaseStat.shortRelease keeps the version+build tail', () {
    final r = ReleaseStat.fromJson({
      'release': 'com.example.myapp@1.5.51+130',
      'event_count': 739,
    });
    expect(r.shortRelease, '1.5.51+130');
  });

  test('unified priority: bugs use severity, features use priority_score', () {
    final bug = Issue.fromJson({
      'sentry_issue_id': '1',
      'source': 'sentry',
      'severity_score': 80,
    });
    final feature = Issue.fromJson({
      'sentry_issue_id': 'feat-1',
      'source': 'feature',
      'priority_score': 65,
    });
    final unanalyzed = Issue.fromJson({'sentry_issue_id': '2'});
    expect(bug.priority, 80);
    expect(feature.priority, 65);
    expect(unanalyzed.priority, isNull);
  });
}
