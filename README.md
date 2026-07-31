# Sentry AI Triage

**English** · [繁體中文](#sentry-ai-triage-繁體中文)

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

### 1 · Install the prerequisites (once)

| Tool | Needed for | Notes |
|---|---|---|
| [Dart SDK](https://dart.dev/get-dart) ≥ 3.5 | running the backend | required |
| [Flutter](https://flutter.dev/docs/get-started/install) | building the web UI (first run only) | required |
| [Claude Code CLI](https://claude.com/claude-code), logged in | AI analysis on your subscription | or use an Anthropic API key instead (Settings → Advanced) |
| [`gh` CLI](https://cli.github.com), logged in | GitHub ticketing / draft PRs | optional — skip if you don't use the GitHub features |

Works on macOS, Linux, and Windows. The only native dependency is SQLite:
macOS ships it, most Linux distros have it (`apt install libsqlite3-0` if
not), and on Windows drop [sqlite3.dll](https://www.sqlite.org/download.html)
somewhere on your `PATH` (or next to the executable).

### 2 · Clone and launch

```bash
git clone https://github.com/NickC84/sentry-ai-triage
```

Then launch — no config files to edit:

- **macOS**: double-click **`start.command`** in Finder (or run `./start.sh`)
- **Linux**: `./start.sh`
- **Windows**: double-click **`start.bat`**

The first run builds the web UI (takes a minute); after that it starts
instantly. The server boots with zero configuration and opens your browser
at `http://localhost:8787`.

### 3 · Connect your Sentry (in the browser)

Open **Settings** (gear icon): paste a read-only Sentry token — the page
links straight to Sentry's token screen and tells you which two scopes to
tick — then hit **auto-detect** to fill in your org/project. Back on the
main screen, hit **Sync from Sentry**. Everything else is optional.

For what every button does (noise rules, AI analysis, ticketing, sync…),
open **Settings → User guide** — the full manual is built into the app, in
English and 繁體中文.

<details>
<summary>Manual steps (what the launcher does)</summary>

```bash
dart pub get
cd ui && flutter pub get && flutter build web --no-web-resources-cdn && cd ..
dart run bin/serve.dart   # PORT=9000 to change port, NO_OPEN=1 to keep the browser closed
```

</details>

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

---

# Sentry AI Triage（繁體中文）

[English](#sentry-ai-triage) · **繁體中文**

自架的 Sentry issue 分流工具，內建 AI 分析——用你**已經在付費的 Claude 訂閱**驅動，不用另外加購 AI 服務。

```
Sentry 拉取 → 規則過濾噪音 → 長期趨勢
           → AI 嚴重度／根因分析（有成本護欄）
           → GitHub 開票（@claude 討論）→ AI 草稿 PR → 人工 review
```

為這種團隊而生：Sentry 裡塞滿修不了的噪音（裝置韌體崩潰、網路不穩），真正的 App bug 被埋在裡面——行動裝置／IoT／看板類 App 尤其常見。

## 功能

- **拉取**：透過 Sentry REST API（自動翻頁）把 issues 抓進本地 SQLite，每次拉取都存快照，長期趨勢不受 Sentry 保留期限制。
- **自動分流規則**：已知的裝置層／網路噪音（`DeadSystemException`、`libGLES_mali`、GC／韌體崩潰、逾時…）在 AI 介入前就標成「已知噪音」——零成本、不誤殺 App bug。預設規則在 `rules/default_rules.json`，可自行增修。
- **AI 分析**：對剩下的 issue 判斷嚴重度（0–100）、App 端可不可修、根因、建議處置與信心值。預設走 **Claude Code CLI**（吃訂閱、零 API 費），也可改用 **Anthropic API**。
- **Web UI**（Flutter Web，中英雙語）：分流清單附每版頻率長條圖、手動重新分類、需求待辦附 AI 可行性分析（會讀你真實的 repo）、站內設定頁——完全不用碰設定檔。
- **GitHub 整合**：一鍵開票（附上分析內容）並自動 @claude 開啟討論；再一鍵請 AI 產草稿 PR（永遠是 draft，人工 review 才 merge）。票／PR 狀態會同步回來。
- **成本護欄**：低於門檻不送 AI、單批有上限、內容沒變走快取不重跑、噪音完全不送。

## 快速開始

### 1 · 安裝前置工具（一次性）

| 工具 | 用途 | 備註 |
|---|---|---|
| [Dart SDK](https://dart.dev/get-dart) ≥ 3.5 | 跑後端 | 必要 |
| [Flutter](https://flutter.dev/docs/get-started/install) | 打包 Web UI（僅首次） | 必要 |
| [Claude Code CLI](https://claude.com/claude-code)（已登入） | 用訂閱跑 AI 分析 | 也可改填 Anthropic API key（設定 → 進階） |
| [`gh` CLI](https://cli.github.com)（已登入） | GitHub 開票／草稿 PR | 選用——不用 GitHub 功能可跳過 |

macOS／Linux／Windows 都能跑。唯一的原生依賴是 SQLite：macOS 內建、多數 Linux 都有（沒有就 `apt install libsqlite3-0`）、Windows 把 [sqlite3.dll](https://www.sqlite.org/download.html) 放進 `PATH` 即可。

### 2 · Clone 後一鍵啟動

```bash
git clone https://github.com/NickC84/sentry-ai-triage
```

啟動——不用編輯任何設定檔：

- **macOS**：Finder 裡雙擊 **`start.command`**（或跑 `./start.sh`）
- **Linux**：`./start.sh`
- **Windows**：雙擊 **`start.bat`**

首次啟動會打包 Web UI（約一分鐘），之後秒開。伺服器零設定開機，瀏覽器自動開啟 `http://localhost:8787`。

### 3 · 在瀏覽器裡連上你的 Sentry

打開**設定**（齒輪圖示）：貼上唯讀的 Sentry token——設定頁有直達 Sentry token 頁面的連結，也寫明要勾哪兩個權限——然後按**自動偵測**填入 org／project。回主畫面按**從 Sentry 拉取**，完成。其他都是選用。

每個按鈕在做什麼（噪音規則、AI 分析、開票、同步…），打開**設定 → 使用說明**——完整操作手冊就內建在 app 裡，中英雙語。

## 無介面 CLI

UI 能做的都能用指令跑（適合排程）：

```bash
dart run bin/ingest.dart     # 拉取 + 規則分流 + 摘要
dart run bin/analyze.dart    # 達門檻的 issue 批次 AI 分析
dart run bin/feature.dart    # 需求可行性分析
```

## AI 引擎怎麼運作

`AI_MODE=claude_cli`（預設）用 JSON schema 呼叫 `claude -p`——分析跑在你現有的 Claude 訂閱上。`AI_MODE=anthropic_api` 則直接用 `ANTHROPIC_API_KEY` 呼叫 API。`CLI_COMMAND` 可以指向任何相容的 agentic CLI。

在設定裡填 **App context**（描述你的 App：平台、什麼算核心功能、已知的噪音來源），分析準確度會明顯提升。AI 輸出語言自動跟隨介面語言。

## 資料與隱私

一切都在本地：SQLite 在 `data/`、設定在 `data/config.json`（已 gitignore，UI 裡機密欄位有遮罩）。唯二的對外連線是你的 Sentry、Claude，以及（選用的）GitHub。

## 授權

[MIT](LICENSE)
