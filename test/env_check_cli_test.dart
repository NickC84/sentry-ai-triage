import 'dart:io';

import 'package:sentry_triage/env_check.dart';
import 'package:test/test.dart';

import 'config_test.dart' show testConfig;

/// Exercises the AI row against a stand-in CLI, because the states that
/// matter (installed but logged out) cannot be produced from a real one on
/// demand — and getting them wrong turns the Settings check into decoration.
void main() {
  late Directory tmp;

  /// A script that answers `--version` and `auth status --json` the way the
  /// Claude CLI does, including its exit codes.
  String fakeCli({required bool loggedIn}) {
    final path = '${tmp.path}/fake-claude';
    File(path).writeAsStringSync('''
#!/bin/sh
case "\$1" in
  --version) echo "9.9.9 (Fake Claude)"; exit 0 ;;
  auth) echo '{"loggedIn": $loggedIn, "subscriptionType": "max"}'
        [ "$loggedIn" = "true" ] && exit 0 || exit 1 ;;
esac
exit 2
''');
    Process.runSync('chmod', ['+x', path]);
    return path;
  }

  setUp(() => tmp = Directory.systemTemp.createTempSync('env_check_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('logged out is an error, even though the CLI exits non-zero', () async {
    final cfg = testConfig()..cliCommand = fakeCli(loggedIn: false);
    final ai = (await runEnvChecks(cfg)).firstWhere((c) => c.id == 'ai');

    expect(ai.status, 'error');
    expect(ai.code, 'cliLoggedOut');
    expect(ai.values['version'], '9.9.9 (Fake Claude)');
  }, onPlatform: {'windows': const Skip('POSIX shell stand-in')});

  test('logged in reports the plan', () async {
    final cfg = testConfig()..cliCommand = fakeCli(loggedIn: true);
    final ai = (await runEnvChecks(cfg)).firstWhere((c) => c.id == 'ai');

    expect(ai.status, 'ok');
    expect(ai.code, 'cliReady');
    expect(ai.values['plan'], 'max');
  }, onPlatform: {'windows': const Skip('POSIX shell stand-in')});

  test('a CLI that cannot answer auth status degrades to a warning', () async {
    final path = '${tmp.path}/mute-cli';
    File(path).writeAsStringSync('#!/bin/sh\necho "1.0.0"\n');
    Process.runSync('chmod', ['+x', path]);

    final cfg = testConfig()..cliCommand = path;
    final ai = (await runEnvChecks(cfg)).firstWhere((c) => c.id == 'ai');

    expect(ai.status, 'warn');
    expect(ai.code, 'cliLoginUnknown');
  }, onPlatform: {'windows': const Skip('POSIX shell stand-in')});
}
