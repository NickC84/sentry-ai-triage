import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

import 'app_paths.dart';

/// Where the SQLite native library comes from.
///
/// Windows ships no system SQLite at all, which is why "download sqlite3.dll
/// yourself" used to be a setup step. Release bundles now carry the DLL next
/// to the binary, so the executable's own directory is searched before the
/// PATH — a bundled copy always wins over whatever a machine happens to have.
class SqliteLibraryMissing implements Exception {
  final String message;

  SqliteLibraryMissing(this.message);

  @override
  String toString() => message;
}

bool _configured = false;

/// Installs the library-resolution override. Idempotent; call before opening
/// any database.
void configureSqlite3() {
  if (_configured) return;
  _configured = true;

  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => _load(
        fileNames: const ['sqlite3.dll'],
        hint: 'SQLite (sqlite3.dll) could not be loaded. Release bundles ship '
            'it next to the executable — if you are running from source, put '
            'sqlite3.dll (https://www.sqlite.org/download.html) beside the '
            'binary or anywhere on your PATH.',
      ),
    );
  } else if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => _load(
        fileNames: const ['libsqlite3.so.0', 'libsqlite3.so'],
        hint: 'SQLite (libsqlite3) could not be loaded. Install it with '
            '`apt install libsqlite3-0` (Debian/Ubuntu) or '
            '`dnf install sqlite-libs` (Fedora/RHEL).',
      ),
    );
  }
  // macOS always has libsqlite3 in the system, so the package default is fine.
}

DynamicLibrary _load({
  required List<String> fileNames,
  required String hint,
}) {
  // A bundled copy wins — but only if it actually loads. A Linux build made
  // against a newer glibc than the host has must not shadow a working system
  // library.
  for (final name in fileNames) {
    for (final path in AppPaths.nativeLibraryCandidates(name)) {
      if (!File(path).existsSync()) continue;
      try {
        return DynamicLibrary.open(path);
      } catch (_) {
        continue;
      }
    }
  }
  for (final name in fileNames) {
    try {
      return DynamicLibrary.open(name); // system search path
    } catch (_) {
      continue;
    }
  }
  throw SqliteLibraryMissing(hint);
}
