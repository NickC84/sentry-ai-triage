import 'package:sentry_triage/config.dart';
import 'package:sentry_triage/env_check.dart';
import 'package:test/test.dart';

/// Note: nothing here calls [Config.load] or [Config.applyAndSave] — both
/// touch the real data/config.json, and a test suite must never rewrite the
/// user's settings.
Config testConfig({
  String org = '',
  String project = '',
  String token = '',
  String aiMode = 'claude_cli',
  String apiKey = '',
  String githubRepo = '',
  String appRepoPath = '',
}) =>
    Config(
      baseUrl: 'https://sentry.io',
      org: org,
      project: project,
      token: token,
      dbPath: '/tmp/does-not-matter.db',
      statsPeriodDays: 90,
      maxReleaseLookups: 50,
      ingestIntervalHours: 0,
      aiMode: aiMode,
      aiModel: 'sonnet',
      anthropicApiKey: apiKey,
      cliCommand: 'definitely-not-a-real-cli-xyz',
      appContext: '',
      outputLanguage: 'en',
      aiMinEvents: 50,
      aiMaxIssues: 20,
      appRepoPath: appRepoPath,
      githubRepo: githubRepo,
      githubToken: '',
      prModel: 'sonnet',
      gitRemote: 'origin',
    );

void main() {
  group('Config', () {
    test('every editable key round-trips through toMap', () {
      // Adding a setting without wiring it here is how a field ends up
      // invisible to the Settings page.
      final keys = testConfig().toMap().keys.toSet();
      expect(Config.editableKeys.difference(keys), isEmpty);
    });

    test('secret keys are a subset of the editable ones', () {
      expect(Config.secretKeys.difference(Config.editableKeys), isEmpty);
    });

    test('missingForIngest names exactly what is unset', () {
      expect(testConfig().missingForIngest,
          ['SENTRY_ORG', 'SENTRY_PROJECT', 'SENTRY_TOKEN']);
      expect(
        testConfig(org: 'o', project: 'p', token: 't').missingForIngest,
        isEmpty,
      );
    });
  });

  group('runEnvChecks', () {
    test('reports unconfigured Sentry as an error', () async {
      final checks = await runEnvChecks(testConfig());
      final sentry = checks.firstWhere((c) => c.id == 'sentry');
      expect(sentry.status, 'error');
      expect(sentry.code, 'sentryMissing');
    });

    test('reports a missing AI CLI as an error, with the command name', () async {
      final checks = await runEnvChecks(testConfig());
      final ai = checks.firstWhere((c) => c.id == 'ai');
      expect(ai.status, 'error');
      expect(ai.code, 'cliNotFound');
      expect(ai.values['command'], 'definitely-not-a-real-cli-xyz');
    });

    test('anthropic_api mode checks the key instead of the CLI', () async {
      final missing = await runEnvChecks(testConfig(aiMode: 'anthropic_api'));
      expect(missing.firstWhere((c) => c.id == 'ai').code, 'apiKeyMissing');

      final set =
          await runEnvChecks(testConfig(aiMode: 'anthropic_api', apiKey: 'k'));
      expect(set.firstWhere((c) => c.id == 'ai').status, 'ok');
    });

    test('an app repo path that is not a git repo is an error', () async {
      final checks = await runEnvChecks(testConfig(appRepoPath: '/tmp'));
      final repo = checks.firstWhere((c) => c.id == 'appRepo');
      expect(repo.status, 'error');
      expect(repo.code, 'appRepoNotGit');
    });

    test('optional integrations degrade to warnings, never errors', () async {
      final checks = await runEnvChecks(testConfig());
      for (final id in ['githubCli', 'githubRepo', 'git']) {
        expect(checks.firstWhere((c) => c.id == id).status, isNot('error'),
            reason: '$id is optional');
      }
    });
  });
}
