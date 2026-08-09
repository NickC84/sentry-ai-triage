import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sentry_triage/app_paths.dart';
import 'package:sentry_triage/process_runner.dart';
import 'package:test/test.dart';

/// These two make the difference between a release binary that works from
/// the Downloads folder and one that silently creates a second, empty
/// database somewhere else.
void main() {
  group('AppPaths', () {
    test('relative paths anchor on the app root', () {
      final resolved = AppPaths.resolve('data/triage.db');
      expect(p.isAbsolute(resolved), isTrue);
      expect(resolved, p.join(AppPaths.root, 'data', 'triage.db'));
    });

    test('absolute paths pass through untouched', () {
      final absolute = p.join(Directory.systemTemp.path, 'elsewhere.db');
      expect(AppPaths.resolve(absolute), absolute);
    });

    test('running under `dart test` is not treated as a compiled binary', () {
      expect(AppPaths.isCompiledBinary, isFalse);
    });

    test('web root falls back to the source layout', () {
      // No release bundle here, so it must point at ui/build/web or the
      // bundle location — never at a bare relative path.
      expect(p.isAbsolute(AppPaths.webRoot), isTrue);
    });

    test('native library candidates include the app root', () {
      final candidates = AppPaths.nativeLibraryCandidates('sqlite3.dll');
      expect(candidates, contains(AppPaths.resolve('sqlite3.dll')));
    });
  });

  group('resolveCommand', () {
    test('returns null for a command that is not installed', () {
      expect(resolveCommand('definitely-not-a-real-cli-xyz'), isNull);
    });

    test('finds an executable on the PATH', () {
      // `dart` is by definition present while these tests run.
      final dart = resolveCommand(Platform.isWindows ? 'dart.exe' : 'dart');
      expect(dart, isNotNull);
      expect(File(dart!).existsSync(), isTrue);
    });

    test('missing CLIs report how to install them', () {
      final e = CliNotFoundException('claude');
      expect(e.toString(), contains('claude'));
      expect(e.toString(), contains('claude.com/claude-code'));
    });

    test('runCommand throws CliNotFoundException, not ProcessException', () {
      expect(
        () => runCommand('definitely-not-a-real-cli-xyz', const []),
        throwsA(isA<CliNotFoundException>()),
      );
    });
  });
}
