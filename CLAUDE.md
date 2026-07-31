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
lib/sentry_client.dart read-only Sentry REST client (issues + release tags)
lib/db.dart            SQLite core (schema/migrations); queries live in
lib/db/                  ingest_store / issue_queries / analysis_store /
                         github_store (part files, grouped by domain)
lib/api_server.dart    server core (engines/router/static hosting); routes in
lib/api/                 config_routes / issue_routes / github_routes
lib/ai_analyzer.dart   AI orchestration; split into
lib/ai/                  models / prompts / engines (CLI + Anthropic API)
lib/github.dart        tickets via gh CLI (or GITHUB_TOKEN)
lib/pr_maker.dart      worktree branch → claude edits → push → draft PR
rules/                 default triage rules seeded on first run
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

## Dev quickstart

```bash
dart pub get
cd ui && flutter pub get && flutter build web --no-web-resources-cdn && cd ..
dart run bin/serve.dart          # http://localhost:8787, serves UI + API
# UI hot reload:
#   cd ui && flutter run -d chrome --dart-define=API_BASE=http://localhost:8787
# Checks:
dart analyze lib bin && cd ui && flutter analyze
```
