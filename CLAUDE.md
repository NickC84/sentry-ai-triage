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
lib/db.dart            SQLite: schema, upserts, rules, queries, ai_analysis
lib/api_server.dart    shelf API + CORS + serves the built web UI
lib/ai_analyzer.dart   structured analysis via claude CLI or Anthropic API
lib/github.dart        tickets via gh CLI (or GITHUB_TOKEN)
lib/pr_maker.dart      worktree branch → claude edits → push → draft PR
rules/                 default triage rules seeded on first run
ui/                    Flutter Web frontend (lib/{main,api,models,i18n}.dart)
```

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
