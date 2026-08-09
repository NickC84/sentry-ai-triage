import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

/// Configuration loader / store.
///
/// Priority (highest wins): environment variables > .env file > data/config.json.
/// The Settings page in the web UI writes to data/config.json, so users can
/// configure everything in-app without touching any file.
class Config {
  // ── Sentry ──
  String baseUrl;
  String org;
  String project;
  String token;

  // ── Storage / ingest ──
  String dbPath;
  int statsPeriodDays;
  int maxReleaseLookups;

  /// Unattended re-ingest interval for installs that sit on a server; 0 (the
  /// default) keeps syncing manual. Analysis stays manual either way — it
  /// costs money, syncing doesn't.
  int ingestIntervalHours;

  // ── AI analysis ──
  /// claude_cli (default; uses your Claude subscription via the `claude` CLI)
  /// or anthropic_api (direct API with a key).
  String aiMode;
  String aiModel;
  String anthropicApiKey;

  /// CLI executable for claude_cli mode. Point it at a compatible wrapper to
  /// use another agentic CLI (must support -p / --output-format json /
  /// --json-schema and the same output envelope).
  String cliCommand;

  /// Free-text description of YOUR app, injected into the analysis prompt so
  /// the AI knows the context (platform, known noise sources, what "core
  /// features" means for severity).
  String appContext;

  /// Language for AI output and GitHub ticket bodies: en | zh-Hant.
  String outputLanguage;

  int aiMinEvents;
  int aiMaxIssues;

  // ── Feature feasibility analysis (reads your app repo; claude_cli only) ──
  String appRepoPath;

  // ── GitHub ──
  String githubRepo;
  String githubToken;
  String prModel;

  /// Git remote name in your app repo that points at GitHub (for pushing
  /// draft-PR branches). Usually 'origin'.
  String gitRemote;

  Config({
    required this.baseUrl,
    required this.org,
    required this.project,
    required this.token,
    required this.dbPath,
    required this.statsPeriodDays,
    required this.maxReleaseLookups,
    required this.ingestIntervalHours,
    required this.aiMode,
    required this.aiModel,
    required this.anthropicApiKey,
    required this.cliCommand,
    required this.appContext,
    required this.outputLanguage,
    required this.aiMinEvents,
    required this.aiMaxIssues,
    required this.appRepoPath,
    required this.githubRepo,
    required this.githubToken,
    required this.prModel,
    required this.gitRemote,
  });

  /// Resolved against the app root, so a double-clicked release binary keeps
  /// its settings next to itself instead of in whatever directory it inherited.
  static String get configJsonPath => AppPaths.resolve('data/config.json');

  /// Keys the Settings UI may read/write (stored in data/config.json).
  static const editableKeys = {
    'SENTRY_BASE_URL',
    'SENTRY_ORG',
    'SENTRY_PROJECT',
    'SENTRY_TOKEN',
    'STATS_PERIOD_DAYS',
    'INGEST_INTERVAL_HOURS',
    'AI_MODE',
    'AI_MODEL',
    'ANTHROPIC_API_KEY',
    'CLI_COMMAND',
    'APP_CONTEXT',
    'OUTPUT_LANGUAGE',
    'AI_MIN_EVENTS',
    'AI_MAX_ISSUES',
    'APP_REPO_PATH',
    'GITHUB_REPO',
    'GITHUB_TOKEN',
    'PR_MODEL',
    'GIT_REMOTE',
  };

  /// Secret-ish keys — the API masks their values when serving the settings
  /// page (the UI shows a placeholder and only overwrites when re-entered).
  static const secretKeys = {'SENTRY_TOKEN', 'ANTHROPIC_API_KEY', 'GITHUB_TOKEN'};

  /// Load configuration. Never exits: missing required values are surfaced by
  /// [missingForIngest] so the server can boot with zero config and let the
  /// user fill things in from the Settings page.
  static Config load() {
    final envFile = _readEnvFile(AppPaths.resolve('.env'));
    final json = _readConfigJson();

    String opt(String k, String d) {
      final v = Platform.environment[k] ?? envFile[k] ?? json[k];
      return (v == null || v.trim().isEmpty) ? d : v.trim();
    }

    return Config(
      baseUrl: opt('SENTRY_BASE_URL', 'https://sentry.io'),
      org: opt('SENTRY_ORG', ''),
      project: opt('SENTRY_PROJECT', ''),
      token: opt('SENTRY_TOKEN', ''),
      dbPath: AppPaths.resolve(opt('DB_PATH', 'data/triage.db')),
      statsPeriodDays: int.tryParse(opt('STATS_PERIOD_DAYS', '90')) ?? 90,
      maxReleaseLookups: int.tryParse(opt('MAX_RELEASE_LOOKUPS', '50')) ?? 50,
      ingestIntervalHours:
          int.tryParse(opt('INGEST_INTERVAL_HOURS', '0')) ?? 0,
      aiMode: opt('AI_MODE', 'claude_cli'),
      aiModel: opt('AI_MODEL', 'sonnet'),
      anthropicApiKey: opt('ANTHROPIC_API_KEY', ''),
      cliCommand: opt('CLI_COMMAND', 'claude'),
      appContext: opt('APP_CONTEXT', ''),
      outputLanguage: opt('OUTPUT_LANGUAGE', 'en'),
      aiMinEvents: int.tryParse(opt('AI_MIN_EVENTS', '50')) ?? 50,
      aiMaxIssues: int.tryParse(opt('AI_MAX_ISSUES', '20')) ?? 20,
      appRepoPath: opt('APP_REPO_PATH', ''),
      githubRepo: opt('GITHUB_REPO', ''),
      githubToken: opt('GITHUB_TOKEN', ''),
      prModel: opt('PR_MODEL', 'sonnet'),
      gitRemote: opt('GIT_REMOTE', 'origin'),
    );
  }

  /// Values required before Sentry ingest can run.
  List<String> get missingForIngest => [
        if (org.isEmpty) 'SENTRY_ORG',
        if (project.isEmpty) 'SENTRY_PROJECT',
        if (token.isEmpty) 'SENTRY_TOKEN',
      ];

  /// Values required before GitHub ticketing can run.
  List<String> get missingForGithub =>
      [if (githubRepo.isEmpty) 'GITHUB_REPO'];

  /// Current values as a map (for the settings API).
  Map<String, String> toMap() => {
        'SENTRY_BASE_URL': baseUrl,
        'SENTRY_ORG': org,
        'SENTRY_PROJECT': project,
        'SENTRY_TOKEN': token,
        'STATS_PERIOD_DAYS': '$statsPeriodDays',
        'INGEST_INTERVAL_HOURS': '$ingestIntervalHours',
        'AI_MODE': aiMode,
        'AI_MODEL': aiModel,
        'ANTHROPIC_API_KEY': anthropicApiKey,
        'CLI_COMMAND': cliCommand,
        'APP_CONTEXT': appContext,
        'OUTPUT_LANGUAGE': outputLanguage,
        'AI_MIN_EVENTS': '$aiMinEvents',
        'AI_MAX_ISSUES': '$aiMaxIssues',
        'APP_REPO_PATH': appRepoPath,
        'GITHUB_REPO': githubRepo,
        'GITHUB_TOKEN': githubToken,
        'PR_MODEL': prModel,
        'GIT_REMOTE': gitRemote,
      };

  /// Apply updates (from the Settings page) and persist to data/config.json.
  /// Only [editableKeys] are accepted. Returns the keys actually changed.
  List<String> applyAndSave(Map<String, dynamic> updates) {
    final changed = <String>[];
    final current = _readConfigJson();

    for (final e in updates.entries) {
      if (!editableKeys.contains(e.key)) continue;
      final v = (e.value ?? '').toString();
      current[e.key] = v;
      changed.add(e.key);
      switch (e.key) {
        case 'SENTRY_BASE_URL':
          baseUrl = v.isEmpty ? 'https://sentry.io' : v;
        case 'SENTRY_ORG':
          org = v;
        case 'SENTRY_PROJECT':
          project = v;
        case 'SENTRY_TOKEN':
          token = v;
        case 'STATS_PERIOD_DAYS':
          statsPeriodDays = int.tryParse(v) ?? statsPeriodDays;
        case 'INGEST_INTERVAL_HOURS':
          ingestIntervalHours = int.tryParse(v) ?? ingestIntervalHours;
        case 'AI_MODE':
          aiMode = v.isEmpty ? 'claude_cli' : v;
        case 'AI_MODEL':
          aiModel = v.isEmpty ? 'sonnet' : v;
        case 'ANTHROPIC_API_KEY':
          anthropicApiKey = v;
        case 'CLI_COMMAND':
          cliCommand = v.isEmpty ? 'claude' : v;
        case 'APP_CONTEXT':
          appContext = v;
        case 'OUTPUT_LANGUAGE':
          outputLanguage = v.isEmpty ? 'en' : v;
        case 'AI_MIN_EVENTS':
          aiMinEvents = int.tryParse(v) ?? aiMinEvents;
        case 'AI_MAX_ISSUES':
          aiMaxIssues = int.tryParse(v) ?? aiMaxIssues;
        case 'APP_REPO_PATH':
          appRepoPath = v;
        case 'GITHUB_REPO':
          githubRepo = v;
        case 'GITHUB_TOKEN':
          githubToken = v;
        case 'PR_MODEL':
          prModel = v.isEmpty ? 'sonnet' : v;
        case 'GIT_REMOTE':
          gitRemote = v.isEmpty ? 'origin' : v;
      }
    }

    if (changed.isNotEmpty) {
      final f = File(configJsonPath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(current));
    }
    return changed;
  }

  static Map<String, String> _readConfigJson() {
    final f = File(configJsonPath);
    if (!f.existsSync()) return {};
    try {
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
    } catch (_) {
      return {};
    }
  }

  static Map<String, String> _readEnvFile(String path) {
    final f = File(path);
    if (!f.existsSync()) return {};
    final map = <String, String>{};
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i < 0) continue;
      final k = t.substring(0, i).trim();
      var v = t.substring(i + 1).trim();
      if (v.length >= 2 &&
          ((v.startsWith('"') && v.endsWith('"')) ||
              (v.startsWith("'") && v.endsWith("'")))) {
        v = v.substring(1, v.length - 1);
      }
      map[k] = v;
    }
    return map;
  }
}
