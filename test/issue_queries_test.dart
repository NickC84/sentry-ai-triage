import 'dart:io';

import 'package:sentry_triage/db.dart';
import 'package:test/test.dart';

/// `issueById` feeds the on-demand analysis routes, so a column missing from
/// its SELECT does not fail loudly — it silently sends the AI less than the
/// user typed.
void main() {
  late Directory tmp;
  late TriageDb db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('issue_queries_test_');
    db = TriageDb.open('${tmp.path}/test.db');
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('issueById returns the fields the analysis routes read', () {
    final id = db.createFeature('Badge for waiting count', 'Show it top-right.');
    final row = db.issueById(id);

    expect(row, isNotNull);
    expect(row!['title'], 'Badge for waiting count');
    // The feature body: analyzeFeature passes this straight to the AI.
    expect(row['detail'], 'Show it top-right.');
    expect(row['source'], 'feature');
    expect(row['triage_state'], isNotNull);
    expect(row['category'], isNotNull);
  });
}
