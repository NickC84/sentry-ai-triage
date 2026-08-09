import 'dart:io';

/// Build version, stamped in by the release pipeline
/// (`dart compile exe -DAPP_VERSION=0.2.0`).
///
/// A binary that cannot tell you which build it is makes every bug report a
/// guessing game; source runs report `dev`.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Handles `--version` / `-v` for any entry point. Returns true when the
/// caller should stop.
bool handledVersionFlag(List<String> args) {
  if (!args.contains('--version') && !args.contains('-v')) return false;
  stdout.writeln('sentry-ai-triage $appVersion');
  return true;
}
