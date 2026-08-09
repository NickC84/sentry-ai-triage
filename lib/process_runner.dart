import 'dart:io';

import 'package:path/path.dart' as p;

/// Running the external CLIs this tool leans on (`claude`, `gh`, `git`).
///
/// Two things `Process.run` does badly on its own:
///
/// 1. A missing command surfaces as a raw `ProcessException` with errno 2,
///    which tells the user nothing about what to install.
/// 2. On Windows, npm installs `claude` as a `claude.cmd` shim. `CreateProcess`
///    cannot launch a batch file directly, and Dart's PATH lookup ignores
///    `PATHEXT` — so the CLI "isn't found" even though it is installed.
///
/// Both are resolved here, once, for every call site.

/// Thrown when a required CLI is not on the PATH — carries an install hint so
/// the message is actionable wherever it surfaces (terminal or web UI).
class CliNotFoundException implements Exception {
  final String command;

  CliNotFoundException(this.command);

  String get hint =>
      _installHints[p.basenameWithoutExtension(command).toLowerCase()] ??
      'Install it and make sure it is on your PATH, or point CLI_COMMAND at its full path in Settings.';

  @override
  String toString() => '`$command` was not found on your PATH. $hint';
}

const _installHints = {
  'claude': 'Install the Claude Code CLI '
      '(npm install -g @anthropic-ai/claude-code), then run `claude` once to '
      'log in: https://claude.com/claude-code — or switch AI_MODE to '
      'anthropic_api in Settings and use an API key instead.',
  'gh': 'Install the GitHub CLI and run `gh auth login`: https://cli.github.com',
  'git': 'Install git: https://git-scm.com/downloads',
};

final _resolved = <String, String>{};

/// Absolute path of [command], or null when it is not on the PATH.
///
/// Only successful lookups are cached: installing a missing CLI while the
/// server is running should start working without a restart.
String? resolveCommand(String command) {
  if (command.contains('/') || command.contains(r'\')) {
    return File(command).existsSync() ? command : null;
  }

  final cached = _resolved[command];
  if (cached != null && File(cached).existsSync()) return cached;

  final extensions = Platform.isWindows
      ? (Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
          .split(';')
          .where((e) => e.isNotEmpty)
          .toList()
      : const [''];
  final separator = Platform.isWindows ? ';' : ':';

  for (final dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    if (dir.trim().isEmpty) continue;
    for (final ext in extensions) {
      final candidate = p.join(dir, '$command$ext');
      if (!File(candidate).existsSync()) continue;
      if (!Platform.isWindows && !_isExecutable(candidate)) continue;
      return _resolved[command] = candidate;
    }
  }
  return null;
}

bool _isExecutable(String path) {
  try {
    return File(path).statSync().mode & 0x49 != 0; // any of the +x bits
  } catch (_) {
    return false;
  }
}

/// `Process.run` with PATH resolution and a useful error when the CLI is
/// missing. Throws [CliNotFoundException] instead of a bare `ProcessException`.
Future<ProcessResult> runCommand(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  Duration? timeout,
}) {
  final resolved = resolveCommand(executable);
  if (resolved == null) throw CliNotFoundException(executable);

  // Batch shims (npm-installed CLIs on Windows) only launch through the shell.
  final needsShell = Platform.isWindows &&
      const ['.cmd', '.bat'].contains(p.extension(resolved).toLowerCase());

  final future = Process.run(
    resolved,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: needsShell,
  );
  return timeout == null ? future : future.timeout(timeout);
}
