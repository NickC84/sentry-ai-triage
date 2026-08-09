import 'dart:convert';
import 'dart:io';

import 'package:sentry_triage/db.dart';
import 'package:sentry_triage/sentry_client.dart';
import 'package:test/test.dart';

/// Rule matching is the load-bearing part of the cost model: everything it
/// marks as noise is never seen by the AI and effectively disappears from the
/// backlog. A pattern that over-matches silently buries real app bugs, so
/// these tests pin the matching semantics rather than the happy path only.
void main() {
  late Directory tmp;
  late TriageDb db;

  SentryIssue issue(String id, {String title = '', String culprit = ''}) =>
      SentryIssue(
        id: id,
        shortId: 'SHORT-$id',
        title: title,
        culprit: culprit,
        level: 'error',
        count: 100,
        userCount: 10,
        firstSeen: DateTime.utc(2026, 1, 1),
        lastSeen: DateTime.utc(2026, 1, 2),
        permalink: '',
      );

  void seed(List<Map<String, String>> rules) {
    final f = File('${tmp.path}/rules.json')
      ..writeAsStringSync(jsonEncode({'rules': rules}));
    db.seedDefaultRules(rulesPath: f.path);
  }

  Map<String, Object?> row(String id) => db
      .listIssues(includeNoise: true)
      .firstWhere((r) => r['sentry_issue_id'] == id);

  String stateOf(String id) => row(id)['triage_state'] as String;
  String categoryOf(String id) => row(id)['category'] as String;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('triage_rules_test_');
    db = TriageDb.open('${tmp.path}/test.db');
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('matches on title and sets category + state', () {
    seed([
      {
        'match_type': 'title',
        'pattern': 'DeadSystemException',
        'set_category': 'device_layer',
        'set_state': 'known_noise',
      }
    ]);
    db.upsertIssue(issue('1', title: 'android.os.DeadSystemException'));
    db.upsertIssue(issue('2', title: 'NullPointerException in checkout'));

    expect(db.applyRules(), 1);
    expect(stateOf('1'), 'known_noise');
    expect(categoryOf('1'), 'device_layer');
    expect(stateOf('2'), 'new', reason: 'unmatched issues stay untouched');
  });

  test('match_type any looks at culprit too', () {
    seed([
      {
        'match_type': 'any',
        'pattern': 'libGLES_mali',
        'set_category': 'device_layer',
        'set_state': 'known_noise',
      }
    ]);
    // Native-stack signatures usually land in culprit, not title.
    db.upsertIssue(issue('1', title: 'SIGSEGV', culprit: 'libGLES_mali.so'));
    db.upsertIssue(issue('2', title: 'SIGSEGV', culprit: 'libapp.so'));

    expect(db.applyRules(), 1);
    expect(stateOf('1'), 'known_noise');
    expect(stateOf('2'), 'new');
  });

  test('title rules ignore culprit', () {
    seed([
      {
        'match_type': 'title',
        'pattern': 'libGLES_mali',
        'set_category': 'device_layer',
        'set_state': 'known_noise',
      }
    ]);
    db.upsertIssue(issue('1', title: 'SIGSEGV', culprit: 'libGLES_mali.so'));

    expect(db.applyRules(), 0);
    expect(stateOf('1'), 'new');
  });

  test('matching is case-insensitive', () {
    seed([
      {
        'match_type': 'title',
        'pattern': 'deadsystemexception',
        'set_category': 'device_layer',
        'set_state': 'known_noise',
      }
    ]);
    db.upsertIssue(issue('1', title: 'android.os.DeadSystemException'));

    expect(db.applyRules(), 1);
  });

  test('underscore and percent are literal, not LIKE wildcards', () {
    seed([
      {
        'match_type': 'title',
        'pattern': 'a_b',
        'set_category': 'log_event',
        'set_state': 'known_noise',
      }
    ]);
    db.upsertIssue(issue('1', title: 'crash in a_b handler'));
    db.upsertIssue(issue('2', title: 'crash in axb handler'));

    expect(db.applyRules(), 1);
    expect(stateOf('1'), 'known_noise');
    expect(stateOf('2'), 'new', reason: '_ must not match any character');
  });

  test('never overrides a human triage decision', () {
    seed([
      {
        'match_type': 'title',
        'pattern': 'Timeout',
        'set_category': 'network_noise',
        'set_state': 'known_noise',
      }
    ]);
    db.upsertIssue(issue('1', title: 'Timeout while syncing'));
    db.updateTriage('1', state: 'keep');

    expect(db.applyRules(), 0);
    expect(stateOf('1'), 'keep');
  });

  test('seeding is idempotent and keeps manual edits', () {
    final rule = {
      'match_type': 'title',
      'pattern': 'Timeout',
      'set_category': 'network_noise',
      'set_state': 'known_noise',
    };
    seed([rule]);
    seed([rule]);

    db.upsertIssue(issue('1', title: 'Timeout while syncing'));
    expect(db.applyRules(), 1,
        reason: 'a duplicated rule would apply (and count) twice');
  });

  test('unknown match_type is skipped instead of throwing', () {
    seed([
      {
        'match_type': 'stacktrace',
        'pattern': 'whatever',
        'set_category': 'unknown',
        'set_state': 'known_noise',
      }
    ]);
    db.upsertIssue(issue('1', title: 'whatever'));

    expect(db.applyRules(), 0);
    expect(stateOf('1'), 'new');
  });
}
