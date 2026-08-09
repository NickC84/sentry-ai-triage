import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'process_runner.dart';

/// One row of the environment check shown on the Settings page.
///
/// The backend reports *codes*, never sentences: the UI owns all wording
/// (en / zh-Hant), and [values] carries the raw bits — versions, paths,
/// slugs — to interpolate into whichever language is active.
class EnvCheck {
  /// Stable row identity, also the i18n key for the row's label.
  final String id;

  /// ok | warn | error — error means a feature cannot work at all, warn means
  /// an optional one is unavailable.
  final String status;

  /// i18n key for the row's message.
  final String code;

  final Map<String, String> values;

  const EnvCheck(this.id, this.status, this.code, [this.values = const {}]);

  Map<String, Object?> toJson() =>
      {'id': id, 'status': status, 'code': code, 'values': values};
}

const _probeTimeout = Duration(seconds: 15);

/// Probe everything the tool depends on, in the order the UI lists it.
Future<List<EnvCheck>> runEnvChecks(Config cfg) async {
  // The three process probes are independent and each may block on a slow
  // CLI, so they overlap.
  final probes = await Future.wait([
    _checkAi(cfg),
    _checkGithubCli(cfg),
    _checkGit(),
  ]);
  return [
    _checkSentry(cfg),
    probes[0], // ai
    probes[1], // github cli
    _checkGithubRepo(cfg),
    probes[2], // git
    _checkAppRepo(cfg),
  ];
}

EnvCheck _checkSentry(Config cfg) {
  final missing = cfg.missingForIngest;
  return missing.isEmpty
      ? EnvCheck('sentry', 'ok', 'sentryReady',
          {'org': cfg.org, 'project': cfg.project})
      : EnvCheck('sentry', 'error', 'sentryMissing', {'keys': missing.join(', ')});
}

/// The AI engine: either the CLI (subscription) or an API key.
Future<EnvCheck> _checkAi(Config cfg) async {
  if (cfg.aiMode == 'anthropic_api') {
    return cfg.anthropicApiKey.isEmpty
        ? const EnvCheck('ai', 'error', 'apiKeyMissing')
        : const EnvCheck('ai', 'ok', 'apiKeyReady');
  }

  final version = await _firstLine(cfg.cliCommand, ['--version']);
  if (version == null) {
    return EnvCheck('ai', 'error', 'cliNotFound', {'command': cfg.cliCommand});
  }

  // Installed but logged out is the single most common dead end, and it is
  // invisible until the first analysis fails — so ask the CLI directly.
  final auth = await _json(cfg.cliCommand, ['auth', 'status', '--json']);
  if (auth == null) {
    // A custom CLI_COMMAND wrapper need not implement `auth status`.
    return EnvCheck('ai', 'warn', 'cliLoginUnknown', {'version': version});
  }
  if (auth['loggedIn'] != true) {
    return EnvCheck('ai', 'error', 'cliLoggedOut', {'version': version});
  }
  return EnvCheck('ai', 'ok', 'cliReady', {
    'version': version,
    'plan': (auth['subscriptionType'] ?? auth['authMethod'] ?? '').toString(),
  });
}

/// GitHub CLI — optional: only the ticketing / draft-PR features need it.
Future<EnvCheck> _checkGithubCli(Config cfg) async {
  final version = await _firstLine('gh', ['--version']);
  if (version == null) {
    return const EnvCheck('githubCli', 'warn', 'ghNotFound');
  }
  if (cfg.githubToken.isNotEmpty) {
    return EnvCheck('githubCli', 'ok', 'ghToken', {'version': version});
  }
  final auth = await _run('gh', ['auth', 'status']);
  return auth?.exitCode == 0
      ? EnvCheck('githubCli', 'ok', 'ghReady', {'version': version})
      : EnvCheck('githubCli', 'warn', 'ghLoggedOut', {'version': version});
}

Future<EnvCheck> _checkGit() async {
  final version = await _firstLine('git', ['--version']);
  return version == null
      ? const EnvCheck('git', 'warn', 'gitNotFound')
      : EnvCheck('git', 'ok', 'gitReady', {'version': version});
}

EnvCheck _checkGithubRepo(Config cfg) => cfg.githubRepo.isEmpty
    ? const EnvCheck('githubRepo', 'warn', 'repoMissing')
    : EnvCheck('githubRepo', 'ok', 'repoReady', {'repo': cfg.githubRepo});

EnvCheck _checkAppRepo(Config cfg) {
  if (cfg.appRepoPath.isEmpty) {
    return const EnvCheck('appRepo', 'warn', 'appRepoMissing');
  }
  final values = {'path': cfg.appRepoPath};
  if (!Directory(cfg.appRepoPath).existsSync()) {
    return EnvCheck('appRepo', 'error', 'appRepoNotFound', values);
  }
  // Draft PRs branch off a worktree, so a plain directory is not enough.
  final isRepo = Directory('${cfg.appRepoPath}/.git').existsSync() ||
      File('${cfg.appRepoPath}/.git').existsSync();
  return isRepo
      ? EnvCheck('appRepo', 'ok', 'appRepoReady', values)
      : EnvCheck('appRepo', 'error', 'appRepoNotGit', values);
}

// ── probe helpers: a missing or misbehaving CLI is never fatal here ──

Future<ProcessResult?> _run(String command, List<String> args) async {
  try {
    return await runCommand(command, args, timeout: _probeTimeout);
  } catch (_) {
    return null;
  }
}

Future<String?> _firstLine(String command, List<String> args) async {
  final res = await _run(command, args);
  if (res == null || res.exitCode != 0) return null;
  final out = res.stdout.toString().trim();
  return out.isEmpty ? null : out.split('\n').first.trim();
}

Future<Map<String, dynamic>?> _json(String command, List<String> args) async {
  final res = await _run(command, args);
  if (res == null || res.exitCode != 0) return null;
  try {
    return jsonDecode(res.stdout.toString()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
