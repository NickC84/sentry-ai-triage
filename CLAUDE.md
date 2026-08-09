# CLAUDE.md — Sentry AI Triage

Project instructions for AI-assisted development. Loaded automatically when a
Claude Code session starts in this repo.

## What this is

A self-hosted ops tool that replaces Sentry's paid AI (Seer) with the user's
existing Claude subscription:

```
Sentry ingest → SQLite → rule triage (filter device-layer noise) → trends
    → AI severity/fixability analysis → GitHub tickets + draft PRs → human review
```

Core idea: filter out unfixable device/network noise **before** any AI runs,
so only genuinely fixable app bugs spend AI budget. See `README.md` for user
docs and `docs/sentry-triage-ai-spec.md` for the original design spec
(zh-Hant, historical).

## Architecture

```
bin/ingest.dart        fetch → DB → apply rules → summary
bin/serve.dart         backend entry point: local API server (default :8787)
bin/analyze.dart       batch AI analysis (thresholds / cache / cost guardrails)
bin/feature.dart       feature feasibility CLI (Claude reads the app repo)
lib/config.dart        config: env > .env > data/config.json (Settings UI)
lib/app_paths.dart     resolves data/web/rules against the executable, so a
                         compiled release binary works from any cwd (TRIAGE_HOME)
lib/process_runner.dart PATH resolution + install hints for claude / gh / git
                         (also fixes Windows .cmd shims)
lib/sqlite_loader.dart  loads a bundled sqlite3.dll / libsqlite3 when present
lib/env_check.dart     Settings self-diagnosis (CLIs installed/logged in,
                         config completeness) — emits codes, never prose
lib/version.dart       APP_VERSION stamped in at compile time + --version
lib/sentry_client.dart read-only Sentry REST client (issues + release tags)
lib/db.dart            SQLite core (schema/migrations); queries live in
lib/db/                  ingest_store / issue_queries / analysis_store /
                         github_store (part files, grouped by domain)
lib/api_server.dart    server core (engines/router/static hosting); routes in
lib/api/                 config_routes / issue_routes / github_routes /
                         health_routes / scheduler (auto-ingest timer)
lib/ai_analyzer.dart   AI orchestration; split into
lib/ai/                  models / prompts / engines (CLI + Anthropic API)
lib/github.dart        tickets via gh CLI (or GITHUB_TOKEN)
lib/pr_maker.dart      worktree branch → claude edits → push → draft PR
rules/                 default triage rules seeded on first run
packaging/             build_bundle.sh (release zip contents) + per-OS launchers
test/                  rule matching, config/env-check, path resolution
.github/workflows/     ci.yml (analyze + test + web build),
                         release.yml (tag → binaries + GHCR image)
ui/lib/                Flutter Web frontend, one file per screen:
                         main (app shell) / triage_page / issue_detail /
                         settings_page / help_page, shared pieces in
                         ui_helpers / issue_tile / issue_list_pane /
                         detail_widgets / page_chrome / dialogs, strings in
                         i18n.dart, API client in api.dart, models.dart
```

Keep classes under ~300 lines — extract widgets / extensions instead of
letting page states and stores grow.

DB tables: `issues` (unified backlog: source = sentry | feature),
`issue_release_stats`, `issue_snapshots` (long-term trends),
`triage_rules`, `ai_analysis` (results + `input_context_hash` cache).

triage_state: `new` / `keep` / `hidden` / `known_noise` / `resolved`.

## Hard rules (do not violate)

1. **Don't rebuild what Sentry does well** — crash collection, grouping,
   symbolication, alerting. Only pull processed data via the API.
2. **Triage first** — known noise goes to `known_noise` and is never sent to
   the AI. This is the whole cost model.
3. **Human in the loop** — the AI may open tickets and *draft* PRs, but
   production changes are never auto-merged.
4. **Cost guardrails** — only analyze `triage_state ∈ {new, keep}` above the
   event threshold; cache results, re-run only on meaningful change.
5. **Secrets** — `.env`, `data/` and `*.db` are gitignored; never commit
   them. The Settings API masks secret values.

## Conventions

- Plain Dart backend (shelf), no frameworks beyond pubspec.
- All UI strings go through `ui/lib/i18n.dart` (en / zh-Hant) — never
  hardcode display text in widgets.
- User-facing AI output honors `OUTPUT_LANGUAGE`; code and comments are
  English.
- Keep everything configurable via `Config` (env > `.env` >
  `data/config.json`) — no hardcoded org/project/repo values.
- Never resolve app files against the current directory: go through
  `AppPaths.resolve()`, or a double-clicked release binary looks for them in
  the wrong place.
- Never call `Process.run` for an external CLI directly — use
  `runCommand()` from `process_runner.dart` so a missing tool produces an
  install hint instead of errno 2.

## Dev quickstart

```bash
dart pub get
cd ui && flutter pub get && flutter build web --no-web-resources-cdn && cd ..
dart run bin/serve.dart          # http://localhost:8787, serves UI + API
# UI hot reload:
#   cd ui && flutter run -d chrome --dart-define=API_BASE=http://localhost:8787
# Checks:
dart analyze lib bin && dart test && cd ui && flutter analyze
```

Tests must never call `Config.load()` / `Config.applyAndSave()` — both read
and write the real `data/config.json`. Construct a `Config` directly instead.

Release bundles (what users actually download — binaries + prebuilt web, no
Dart/Flutter needed) are assembled by `packaging/build_bundle.sh`; pushing a
`v*` tag runs it on four platforms via `.github/workflows/release.yml`.
Toolchain versions are pinned there — bump them deliberately.
