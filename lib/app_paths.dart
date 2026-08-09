import 'dart:io';

import 'package:path/path.dart' as p;

/// Filesystem layout resolution.
///
/// The same code runs in two very different shapes:
///
///   source checkout   `dart run bin/serve.dart` from the repo root
///   release bundle    an unpacked zip where the compiled binary sits next to
///                     `web/`, `rules/` and a writable `data/`
///
/// Anchoring on the executable rather than the current directory is what lets
/// someone unzip a release into Downloads, double-click it, and still find
/// their database — a double-clicked binary inherits an arbitrary cwd.
class AppPaths {
  AppPaths._();

  /// Forces the base directory. The Docker image sets it to `/app` because
  /// there the binary lives in `/usr/local/bin` but the data does not.
  static const homeEnvVar = 'TRIAGE_HOME';

  static String? _cachedRoot;

  /// True when running as a `dart compile exe` binary rather than `dart run`.
  static bool get isCompiledBinary =>
      p.basenameWithoutExtension(Platform.resolvedExecutable) != 'dart';

  /// Base directory for bundled assets and user data.
  static String get root => _cachedRoot ??= _resolveRoot();

  static String _resolveRoot() {
    final override = Platform.environment[homeEnvVar]?.trim();
    if (override != null && override.isNotEmpty) {
      return p.normalize(p.absolute(override));
    }
    if (isCompiledBinary) return p.dirname(Platform.resolvedExecutable);
    return Directory.current.path;
  }

  /// Absolute path for [relative], anchored at [root]. Absolute inputs (e.g. a
  /// user-supplied `DB_PATH`) pass through untouched.
  static String resolve(String relative) =>
      p.isAbsolute(relative) ? relative : p.normalize(p.join(root, relative));

  /// Directory holding the built web UI: `web/` in a release bundle,
  /// `ui/build/web` in a source checkout.
  static String get webRoot {
    for (final candidate in ['web', p.join('ui', 'build', 'web')]) {
      final dir = resolve(candidate);
      if (File(p.join(dir, 'index.html')).existsSync()) return dir;
    }
    return resolve('web');
  }

  /// Candidate locations for a bundled native library: next to the data root
  /// and next to the executable (the two differ when [homeEnvVar] is set).
  static List<String> nativeLibraryCandidates(String fileName) {
    final beside = p.join(p.dirname(Platform.resolvedExecutable), fileName);
    final atRoot = resolve(fileName);
    return atRoot == beside ? [atRoot] : [atRoot, beside];
  }
}
