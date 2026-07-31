# Sentry AI Triage

Self-hosted Sentry issue triage with AI analysis — powered by the Claude
subscription you already pay for, instead of a separate AI add-on.

```
Sentry ingest → rule-based noise filtering → long-term trends
             → AI severity / root-cause analysis (cost-guarded)
             → GitHub tickets (@claude discussion) → AI draft PRs → human review
```

Built for teams whose Sentry feed is dominated by unfixable noise (device
firmware crashes, flaky networks) with real app bugs buried in between —
common for mobile / IoT / kiosk apps.

## What it does

- **Ingest** issues from Sentry (REST API, auto-pagination) into a local
  SQLite DB, snapshotting every run so trends survive Sentry's retention
  window.
- **Auto-triage rules** mark known device-layer / network noise
  (`DeadSystemException`, `libGLES_mali`, GC/firmware crashes, timeouts…) as
  `known_noise` before any AI runs — zero cost, zero misclassified app bugs.
  Rules are seeded from `rules/default_rules.json` and editable in the DB.
- **AI analysis** of what's left: severity (0–100), app-fixable or not, root
  cause, recommended action, confidence. Runs through the **Claude Code CLI**
  (uses your subscription, no API cost) or the **Anthropic API** — your
  choice.
- **Web UI** (Flutter Web, English / 繁體中文): triage list with per-release
  frequency bars, manual re-classification, feature backlog with AI
  feasibility analysis (it reads your actual repo), and in-app Settings — no
  config files needed.
- **GitHub integration**: one click opens a ticket with the analysis and
  auto-@claude's it to start a discussion; a second click asks for an AI
  draft PR (opened as draft, never merged without human review). Ticket/PR
  states sync back.
- **Cost guardrails**: minimum event count before AI, per-batch cap, content
  hashing so unchanged issues are never re-analyzed, noise never sent.

## Quick start

Requirements: [Dart SDK](https://dart.dev/get-dart) ≥ 3.5,
[Flutter](https://flutter.dev) (to build the web UI once), and either the
[Claude Code CLI](https://claude.com/claude-code) (logged in) or an Anthropic
API key. `gh` CLI optional, for GitHub ticketing.

```bash
git clone https://github.com/NickC84/sentry-ai-triage
cd sentry-ai-triage
./start.sh        # macOS / Linux — or double-click start.command in Finder
start.bat         # Windows
```

That's it — the first run builds the web UI (takes a minute), then the
server starts and your browser opens automatically. macOS users can also
double-click `start.command` in Finder.

<details>
<summary>Manual steps (what the launcher does)</summary>

```bash
dart pub get
cd ui && flutter pub get && flutter build web --no-web-resources-cdn && cd ..
dart run bin/serve.dart   # PORT=9000 to change port, NO_OPEN=1 to keep the browser closed
```

</details>

Open Settings in the UI, paste a read-only Sentry token (the Settings page
links to the right page and can auto-fill your org/project from the token),
then hit **Sync from Sentry**. Everything else is optional.

Works on macOS, Linux, and Windows. The only native dependency is SQLite:
macOS ships it, most Linux distros have it (`apt install libsqlite3-0` if
not), and on Windows drop [sqlite3.dll](https://www.sqlite.org/download.html)
somewhere on your `PATH` (or next to the executable).

Prefer files? `cp .env.example .env` and edit — env vars > `.env` >
in-app settings.

## Headless CLI

Everything the UI does is scriptable (cron-friendly):

```bash
dart run bin/ingest.dart     # fetch + rule triage + summary
dart run bin/analyze.dart    # batch AI analysis over the threshold
dart run bin/feature.dart    # feature feasibility analysis
```

## How the AI engine works

`AI_MODE=claude_cli` (default) shells out to `claude -p` with a JSON schema —
so analysis runs on your existing Claude subscription. `AI_MODE=anthropic_api`
calls the API directly with `ANTHROPIC_API_KEY`. `CLI_COMMAND` can point at
any compatible agentic CLI wrapper.

Set `APP_CONTEXT` (in Settings) to describe your app — platform, what "core
feature" means, known noise sources — and the analysis gets noticeably
sharper. `OUTPUT_LANGUAGE` switches AI output and ticket bodies between
English and Traditional Chinese.

## Data & privacy

Everything stays local: SQLite in `data/`, config in `data/config.json`
(gitignored, secrets masked in the UI). The only outbound calls are to your
Sentry instance, Claude, and (optionally) GitHub.

## Repo layout

```
bin/       entry points: serve / ingest / analyze / feature
lib/       backend: config, sentry client, ingest, db, AI, GitHub, API server
rules/     default triage rules seeded on first run
ui/        Flutter Web frontend (en / zh-Hant)
docs/      original design spec (zh-Hant, historical)
```

## License

[MIT](LICENSE)
