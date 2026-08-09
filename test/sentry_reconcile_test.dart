import 'dart:io';

import 'package:sentry_triage/db.dart';
import 'package:sentry_triage/sentry_client.dart';
import 'package:test/test.dart';

/// Sentry decides whether an issue is still open; this side decides what to
/// do about it. The tests below pin where that boundary sits, because the
/// failure mode is silent either way: a backlog full of things someone
/// already fixed, or a human decision quietly undone by a sync.
void main() {
  late Directory tmp;
  late TriageDb db;

  SentryIssue issue(String id) => SentryIssue(
        id: id,
        shortId: 'SHORT-$id',
        title: 'Issue $id',
        culprit: '',
        level: 'error',
        count: 100,
        userCount: 10,
        firstSeen: DateTime.utc(2026, 1, 1),
        lastSeen: DateTime.utc(2026, 1, 2),
        permalink: '',
      );

  Map<String, Object?> row(String id) => db
      .listIssues(includeNoise: true)
      .firstWhere((r) => r['sentry_issue_id'] == id);

  String stateOf(String id) => row(id)['triage_state'] as String;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reconcile_test_');
    db = TriageDb.open('${tmp.path}/test.db');
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('resolving in Sentry closes the item here', () {
    db.upsertIssue(issue('1'));
    final moved = db.reconcileWithSentry(
      unresolvedIds: const [],
      closedStatuses: const {'1': 'resolved'},
    );

    expect(moved.closed, 1);
    expect(stateOf('1'), 'resolved');
  });

  test('archiving in Sentry closes it too', () {
    db.upsertIssue(issue('1'));
    db.reconcileWithSentry(
      unresolvedIds: const [],
      closedStatuses: const {'1': 'ignored'},
    );

    expect(stateOf('1'), 'resolved');
  });

  test('a kept item still closes when Sentry resolves it', () {
    db.upsertIssue(issue('1'));
    db.updateTriage('1', state: 'keep');
    db.reconcileWithSentry(
      unresolvedIds: const [],
      closedStatuses: const {'1': 'resolved'},
    );

    expect(stateOf('1'), 'resolved');
  });

  test('human decisions here are left alone', () {
    for (final state in ['hidden', 'known_noise']) {
      db.upsertIssue(issue(state));
      db.updateTriage(state, state: state);
    }
    final moved = db.reconcileWithSentry(
      unresolvedIds: const [],
      closedStatuses: const {'hidden': 'resolved', 'known_noise': 'resolved'},
    );

    expect(moved.closed, 0);
    expect(stateOf('hidden'), 'hidden');
    expect(stateOf('known_noise'), 'known_noise');
  });

  test('a regression in Sentry brings the item back', () {
    db.upsertIssue(issue('1'));
    db.reconcileWithSentry(
      unresolvedIds: const [],
      closedStatuses: const {'1': 'resolved'},
    );
    expect(stateOf('1'), 'resolved');

    // Next run: Sentry lists it as unresolved again.
    final moved = db.reconcileWithSentry(
      unresolvedIds: const ['1'],
      closedStatuses: const {},
    );

    expect(moved.reopened, 1);
    expect(stateOf('1'), 'new');
  });

  test('a manual resolve here is not reopened by a later sync', () {
    db.upsertIssue(issue('1'));
    db.updateTriage('1', state: 'resolved');

    final moved = db.reconcileWithSentry(
      unresolvedIds: const ['1'],
      closedStatuses: const {},
    );

    expect(moved.reopened, 0);
    expect(stateOf('1'), 'resolved');
  });

  test('unknown ids from Sentry are ignored', () {
    final moved = db.reconcileWithSentry(
      unresolvedIds: const ['nope'],
      closedStatuses: const {'also-nope': 'resolved'},
    );

    expect(moved.closed, 0);
    expect(moved.reopened, 0);
  });
}
