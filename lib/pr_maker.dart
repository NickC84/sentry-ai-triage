import 'dart:io';

/// Result of a draft-PR run.
class PrResult {
  final String prUrl;
  final String branch;
  final List<String> changedFiles;
  PrResult(
      {required this.prUrl, required this.branch, required this.changedFiles});
}

/// Lets the agentic CLI edit code on an **isolated git worktree branch**,
/// commit, push, and open a GitHub **draft PR**. Never merges — a human
/// reviews and merges.
///
/// Safety design:
/// - A fresh worktree branch: your working directory is never touched.
/// - CLI runs with --permission-mode acceptEdits (file edits only).
/// - Draft PRs only; nothing in this flow ever merges.
class PrMaker {
  final String appRepoPath;
  final String githubRepo; // owner/repo
  final String token; // for gh (GH_TOKEN)
  final String model;
  final String cliCommand;
  final String gitRemote; // remote in the app repo that points at GitHub
  final String outputLanguage; // en | zh-Hant
  final Duration timeout;

  PrMaker({
    required this.appRepoPath,
    required this.githubRepo,
    required this.token,
    this.model = 'sonnet',
    this.cliCommand = 'claude',
    this.gitRemote = 'origin',
    this.outputLanguage = 'en',
    this.timeout = const Duration(minutes: 20),
  });

  bool get _zh => outputLanguage == 'zh-Hant';

  Future<PrResult> makeDraftPr({
    required String shortId,
    required String title,
    required bool isFeature,
    required String detail,
    required String rootCause,
    required String approach,
    required String affectedAreas,
  }) async {
    if (appRepoPath.isEmpty) {
      throw Exception('APP_REPO_PATH is not set — configure it in Settings.');
    }
    final repo = Directory(appRepoPath);
    if (!repo.existsSync()) {
      throw Exception('App repo not found: $appRepoPath');
    }
    if (githubRepo.isEmpty) {
      throw Exception('GITHUB_REPO is not set — configure it in Settings.');
    }

    final branch = _branchName(shortId, title);
    final worktree = Directory.systemTemp.createTempSync('triage_pr_').path;

    // 1) Create the worktree on a new branch from HEAD.
    await _git(
        ['-C', appRepoPath, 'worktree', 'add', '-b', branch, worktree, 'HEAD']);

    try {
      // 2) Let the CLI edit code inside the worktree.
      final prompt = _prompt(
        shortId: shortId,
        title: title,
        isFeature: isFeature,
        detail: detail,
        rootCause: rootCause,
        approach: approach,
        affectedAreas: affectedAreas,
      );
      final res = await Process.run(
        cliCommand,
        [
          '-p', prompt,
          '--permission-mode', 'acceptEdits',
          '--model', model,
        ],
        workingDirectory: worktree,
      ).timeout(timeout);
      if (res.exitCode != 0) {
        throw Exception(
            '$cliCommand failed (exit ${res.exitCode}): ${res.stderr}');
      }

      // 3) Any actual changes?
      final status =
          (await _git(['-C', worktree, 'status', '--porcelain'])).trim();
      if (status.isEmpty) {
        throw Exception(
            'The AI produced no file changes (possibly not enough info, or no code change needed).');
      }
      final changed = status
          .split('\n')
          .map((l) => l.trim().split(RegExp(r'\s+')).last)
          .where((s) => s.isNotEmpty)
          .toList();

      // 4) Commit under a clearly-labeled bot identity.
      await _git(['-C', worktree, 'add', '-A']);
      await _git([
        '-C', worktree,
        '-c', 'user.name=sentry-ai-triage (AI draft)',
        '-c', 'user.email=triage-bot@localhost',
        'commit', '-m', _commitMsg(shortId, title),
      ]);

      // 5) Push to the GitHub remote.
      await _git(['-C', worktree, 'push', '-u', gitRemote, branch]);

      // 6) Open the draft PR.
      final prTitle = _zh
          ? '[AI草稿] ${_truncate(title, 60)}（$shortId）'
          : '[AI draft] ${_truncate(title, 60)} ($shortId)';
      final prUrl = await _createDraftPr(
        branch: branch,
        title: prTitle,
        body: _prBody(
          shortId: shortId,
          isFeature: isFeature,
          rootCause: rootCause,
          approach: approach,
          changed: changed,
        ),
        cwd: worktree,
      );

      return PrResult(prUrl: prUrl, branch: branch, changedFiles: changed);
    } finally {
      // 7) Clean up the worktree (the remote branch stays for the PR).
      await _git(['-C', appRepoPath, 'worktree', 'remove', worktree, '--force'],
          allowFail: true);
      await _git(['-C', appRepoPath, 'branch', '-D', branch], allowFail: true);
    }
  }

  // ── internals ──────────────────────────────────────────────

  Future<String> _createDraftPr({
    required String branch,
    required String title,
    required String body,
    required String cwd,
  }) async {
    final res = await Process.run(
      'gh',
      [
        'pr', 'create',
        '--repo', githubRepo,
        '--draft',
        '--head', branch,
        '--title', title,
        '--body', body,
      ],
      workingDirectory: cwd,
      environment: token.isEmpty ? null : {'GH_TOKEN': token},
    ).timeout(const Duration(seconds: 60));
    if (res.exitCode != 0) {
      throw Exception(
          'gh pr create failed (exit ${res.exitCode}): ${res.stderr}');
    }
    final m = RegExp(r'https://github\.com/\S+/pull/\d+')
        .firstMatch(res.stdout.toString());
    if (m == null) {
      throw Exception('PR created but URL not found: ${res.stdout}');
    }
    return m.group(0)!;
  }

  Future<String> _git(List<String> args, {bool allowFail = false}) async {
    final res =
        await Process.run('git', args).timeout(const Duration(seconds: 120));
    if (res.exitCode != 0 && !allowFail) {
      throw Exception(
          'git ${args.join(' ')} failed (exit ${res.exitCode}): ${res.stderr}');
    }
    return res.stdout.toString();
  }

  String _branchName(String shortId, String title) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final short =
        slug.isEmpty ? '' : '-${slug.substring(0, slug.length.clamp(0, 24))}';
    return 'triage/${shortId.toLowerCase()}$short';
  }

  String _commitMsg(String shortId, String title) => _zh
      ? '[AI草稿] ${_truncate(title, 60)}（$shortId）\n\n由 sentry-ai-triage 的 AI 產生的修復/實作草稿，待人工 review。'
      : '[AI draft] ${_truncate(title, 60)} ($shortId)\n\nAI-generated draft fix/implementation from sentry-ai-triage — pending human review.';

  String _prompt({
    required String shortId,
    required String title,
    required bool isFeature,
    required String detail,
    required String rootCause,
    required String approach,
    required String affectedAreas,
  }) {
    final kind = isFeature ? 'feature' : 'crash fix';
    final lang = _zh
        ? 'Write code comments and your summary in Traditional Chinese where natural.'
        : '';
    return '''
You are a senior engineer on this project. On **the current working directory's branch**, implement a **draft** of the following $kind (it will be opened as a draft PR for human review — it will never be merged directly).

## Item ($shortId)
$title
${isFeature && detail.isNotEmpty ? 'Feature detail: $detail' : ''}

## Prior AI analysis (reference)
- Root cause / summary: $rootCause
- Suggested approach: $approach
- Affected areas: $affectedAreas

## Requirements
1. Read the relevant code first; keep changes focused and minimal, matching the existing architecture and style.
2. Edit files directly (you have acceptEdits permission).
3. If there isn't enough information for a complete implementation, build the **minimal viable skeleton/change** and mark gaps with TODO comments — do not guess wildly.
4. Do not touch unrelated files. Do not run git commands (commit/push are handled externally).
$lang
When done, briefly summarize what you changed.''';
  }

  String _prBody({
    required String shortId,
    required bool isFeature,
    required String rootCause,
    required String approach,
    required List<String> changed,
  }) {
    final buf = StringBuffer();
    if (_zh) {
      buf.writeln('> ⚠️ 這是 **sentry-ai-triage 的 AI 產生的草稿**，尚未 review，**請勿直接 merge**。\n');
      buf.writeln('對應項目：$shortId（${isFeature ? '需求' : 'Bug'}）\n');
      if (rootCause.isNotEmpty) buf.writeln('### 分析根因/摘要\n$rootCause\n');
      if (approach.isNotEmpty) buf.writeln('### 原建議做法\n$approach\n');
      buf.writeln('### 本次改動檔案');
      for (final f in changed) {
        buf.writeln('- `$f`');
      }
      buf.writeln('\n---\n_由 sentry-ai-triage 產生，人工 review 通過才 merge。_');
    } else {
      buf.writeln(
          '> ⚠️ This is an **AI-generated draft from sentry-ai-triage** — not yet reviewed. **Do not merge as-is.**\n');
      buf.writeln('Item: $shortId (${isFeature ? 'feature' : 'bug'})\n');
      if (rootCause.isNotEmpty) buf.writeln('### Root cause / summary\n$rootCause\n');
      if (approach.isNotEmpty) buf.writeln('### Suggested approach\n$approach\n');
      buf.writeln('### Files changed');
      for (final f in changed) {
        buf.writeln('- `$f`');
      }
      buf.writeln(
          '\n---\n_Generated by sentry-ai-triage. Merge only after human review._');
    }
    return buf.toString();
  }

  static String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}
