# Sentry AI Triage

**English** · [繁體中文](#zh-hant)

A small self-hosted companion to Sentry. It keeps a local copy of your
issues, sorts the device and network noise out of the way, and sends what is
left to Claude for a severity and root-cause read. The analysis runs through
the Claude Code CLI, on a subscription you already have.

```
Sentry sync → noise rules → long-term trends
           → AI severity / root-cause read (cost-guarded)
           → GitHub tickets (@claude discussion) → AI draft PRs → human review
```

It is aimed at projects that collect a lot of crashes nobody can fix from
the app side — firmware faults, flaky radios, kiosk hardware — where the
bugs that do matter are mixed in among them. Sentry stays where it is: it
still collects, groups and alerts, and it stays the authority on whether an
issue is open. Resolving or archiving something there closes it here on the
next sync.

![Triage list — noise filtered, AI severity badges, per-release trends](docs/screenshots/triage-main.png)

## What it does

Syncs your issues into a local SQLite database and takes a snapshot each
run, so you can still see how something has trended over a year even after
it has aged out of Sentry.

Marks known device and network noise (`DeadSystemException`, `libGLES_mali`,
GC and firmware crashes, timeouts) as `known_noise` before any AI runs.
Noise is never sent for analysis, which is what keeps the cost down. The
starting rules are in `rules/default_rules.json` and you can edit them.

Reads whatever is left: severity 0–100, whether it looks fixable from the
app, likely root cause, a recommended action and a confidence score. Runs
either through the Claude Code CLI on your subscription, or against the
Anthropic API with a key.

Comes with a web UI in English and 繁體中文: the triage list with
per-release frequency bars, manual re-classification, a feature backlog
where the AI reads your actual repo to judge feasibility, and settings you
fill in from the browser.

Opens GitHub tickets with the analysis attached and @claude's them to start
a discussion. A second click asks for a draft PR, which stays a draft until
a human merges it. Ticket and PR states are synced back.

Keeps a few guardrails on spending: a minimum event count before anything is
analyzed, a cap per batch, and content hashing so an unchanged issue is
never analyzed twice.

## Quick start

### 1 · Install the prerequisites (once)

| Tool | Needed for | Notes |
|---|---|---|
| [Claude Code CLI](https://claude.com/claude-code), logged in | AI analysis on your subscription | or use an Anthropic API key instead (Settings → Advanced) |
| [`gh` CLI](https://cli.github.com), logged in | GitHub ticketing / draft PRs | optional — skip if you don't use the GitHub features |

That's it. **No Dart, no Flutter, no SQLite setup** — the release bundles
below carry a compiled server, the prebuilt web UI, and (on Windows) the
SQLite library.

### 2 · Get it running

<table>
<tr><th></th><th>You need</th><th>Best for</th></tr>
<tr><td><b>A · Release download</b> (recommended)</td><td>nothing extra</td><td>most people</td></tr>
<tr><td><b>B · Docker</b></td><td>Docker</td><td>teams already running containers, or putting it on a server</td></tr>
<tr><td><b>C · From source</b></td><td>Dart + Flutter</td><td>hacking on the tool itself</td></tr>
</table>

#### A · Release download

1. Grab the zip for your machine from
   [**Releases**](https://github.com/NickC84/sentry-ai-triage/releases/latest) —
   `macos-arm64` (Apple Silicon), `macos-x64` (Intel), `linux-x64`,
   `linux-arm64` (Pi / ARM servers), `windows-x64`.
2. Unzip it anywhere you like.
3. Launch:
   - **macOS** — double-click **`start.command`**. If macOS blocks it as
     unsigned, run once: `xattr -dr com.apple.quarantine /path/to/the/folder`
   - **Linux** — `./start.sh` (or run `./sentry-triage` directly)
   - **Windows** — double-click **`start.bat`**

Your browser opens at `http://localhost:8787`; if that port is taken the
server steps to the next free one and prints where it landed (`--port 9000`
to choose). Everything it writes — `data/triage.db`, `data/config.json` —
stays inside the unzipped folder, so deleting the folder uninstalls it.

The headless CLIs (`sentry-triage-ingest`, `-analyze`, `-feature`) sit in the
same folder, ready for cron.

#### B · Docker

Solves the toolchain in one shot, at the cost of two mounts: the AI runs on
*your* Claude login and reads *your* app repo, and neither can live inside
the image.

```bash
# Log the container's Claude CLI in once — the credentials persist in ~/.claude
docker run -it --rm -v "$HOME/.claude:/root/.claude" \
  ghcr.io/nickc84/sentry-ai-triage:latest claude

docker run -d -p 8787:8787 \
  -v "$PWD/data:/app/data" \
  -v "$HOME/.claude:/root/.claude" \
  -v "/path/to/your/app-repo:/workspace" \
  -e APP_REPO_PATH=/workspace \
  ghcr.io/nickc84/sentry-ai-triage:latest
```

The published image is `linux/amd64`. On Apple Silicon add
`--platform linux/amd64` to both commands (Docker Desktop emulates it); on
ARM servers use the `linux-arm64` release bundle instead. To build a native
image yourself, `docker-compose.yml` does the same thing from source
(`docker compose up -d --build`).

#### C · From source

Needs the [Dart SDK](https://dart.dev/get-dart) ≥ 3.5 and
[Flutter](https://flutter.dev/docs/get-started/install) 3.24 (the version CI
pins; newer stable releases generally work).

```bash
git clone https://github.com/NickC84/sentry-ai-triage
cd sentry-ai-triage
./start.sh          # macOS/Linux — builds the web UI on first run
                    # Windows: start.bat
```

Clone rather than downloading the source zip — GitHub's zip drops the
executable bit, and `./start.sh` then fails with `permission denied`
(`chmod +x start.sh start.command` fixes it).

<details>
<summary>Manual steps / building your own bundle</summary>

```bash
dart pub get
cd ui && flutter pub get && flutter build web --no-web-resources-cdn && cd ..
dart run bin/serve.dart   # PORT=9000 or --port 9000, NO_OPEN=1 to keep the browser closed

# Same self-contained zip contents that CI publishes:
packaging/build_bundle.sh --out dist/my-build
```

</details>

### 3 · Connect your Sentry (in the browser)

Open **Settings** (gear icon): paste a read-only Sentry token — the page
links straight to Sentry's token screen and tells you which two scopes to
tick — then hit **auto-detect** to fill in your org/project. Back on the
main screen, hit **Sync from Sentry**. Everything else is optional.

The **Environment check** at the top of Settings tells you whether the Claude
CLI is installed *and logged in*, whether `gh` is authenticated, and whether
your app repo path is really a git repo — so a missing prerequisite shows up
as a red row with the command to fix it, not as a failed analysis later. Set
**auto-sync** there too if this install lives on a server (analysis stays
manual — it costs money, syncing doesn't).

For what every button does (noise rules, AI analysis, ticketing, sync…),
open **Settings → User guide** — the full manual is built into the app, in
English and 繁體中文.

![Settings — token link, auto-detect, advanced collapsed](docs/screenshots/settings.png)

Prefer files? `cp .env.example .env` and edit — env vars > `.env` >
in-app settings. Both live next to the executable (or the repo root when
running from source); `TRIAGE_HOME` overrides that base directory.

## Headless CLI

Everything the UI does is scriptable (cron-friendly). From a release bundle:

```bash
./sentry-triage-ingest      # fetch + rule triage + summary
./sentry-triage-analyze     # batch AI analysis over the threshold
./sentry-triage-feature     # feature feasibility analysis
```

From source, the same three are `dart run bin/ingest.dart`,
`bin/analyze.dart`, `bin/feature.dart`. Every binary takes `--version`.

## How the AI engine works

`AI_MODE=claude_cli` (the default) calls `claude -p` with a JSON schema, so
the analysis runs on your Claude subscription. `AI_MODE=anthropic_api` calls
the API directly with `ANTHROPIC_API_KEY` instead. `CLI_COMMAND` can point at
any compatible agentic CLI wrapper.

It is worth filling in `APP_CONTEXT` in Settings: describe the platform, what
counts as a core feature, and the noise sources you already know about. The
analysis gets noticeably sharper with that context than without it.
`OUTPUT_LANGUAGE` switches AI output and ticket bodies between English and
Traditional Chinese.

## Data & privacy

Everything stays local: SQLite in `data/`, config in `data/config.json`
(gitignored, secrets masked in the UI), both next to the executable — or the
repo root when running from source, or wherever `TRIAGE_HOME` points. The
only outbound calls are to your Sentry instance, Claude, and (optionally)
GitHub.

## Repo layout

```
bin/        entry points: serve / ingest / analyze / feature
lib/        backend: config, sentry client, ingest, db, AI, GitHub, API server
rules/      default triage rules seeded on first run
ui/         Flutter Web frontend (en / zh-Hant)
packaging/  release bundle builder + per-OS launchers
.github/    CI (analyze + build) and the release pipeline
docs/       original design spec (zh-Hant, historical)
```

## Releasing

```bash
git tag v1.2.0 && git push --tags
```

CI builds the web UI once, compiles binaries for macOS (arm64/x64), Linux
(x64/arm64) and Windows, smoke-tests each bundle by running it from an
unrelated directory, pushes the container image to GHCR, and attaches the
zips plus `SHA256SUMS.txt` to the GitHub release. Toolchain versions are
pinned in `.github/workflows/release.yml`.

The GHCR package published from a public repo is publicly pullable as-is —
verified by pulling it anonymously. GHCR exposes no API for package
visibility, so if one ever does land private, it is a manual flip at
`https://github.com/users/<owner>/packages/container/sentry-ai-triage/settings`.

## License

[MIT](LICENSE)

---

<a name="zh-hant"></a>

# Sentry AI Triage（繁體中文）

[English](#sentry-ai-triage) · **繁體中文**

一個自架的 Sentry 小夥伴。它在本地保留一份 issue 副本，把裝置與網路類的噪音先分出去，剩下的交給 Claude 判斷嚴重度與根因。分析走 Claude Code CLI，用你手上已經有的訂閱。

```
從 Sentry 同步 → 噪音規則 → 長期趨勢
             → AI 嚴重度／根因判讀（有成本護欄）
             → GitHub 開票（@claude 討論）→ AI 草稿 PR → 人工 review
```

適合這樣的專案：Sentry 裡累積了大量從 App 端根本修不了的崩潰（韌體問題、訊號不穩、看板機硬體），而真正該處理的 bug 混在裡面。Sentry 該做的事還是它在做：收集、分組、告警，而且一個 issue 到底結案了沒，也還是以 Sentry 為準——在那邊 resolve 或封存，下次同步時這裡就會跟著關掉。

![分流清單——噪音已濾除、AI 嚴重度徽章、每版趨勢](docs/screenshots/triage-main.png)

## 功能

把 issue 同步進本地 SQLite，每次同步存一份快照，所以就算某個問題早就超過 Sentry 的保留期，你還是看得到它一整年的走勢。

在 AI 介入之前，先用規則把已知的裝置與網路噪音（`DeadSystemException`、`libGLES_mali`、GC 與韌體崩潰、逾時）標成「已知噪音」。噪音永遠不會送去分析，成本就是這樣壓下來的。起始規則放在 `rules/default_rules.json`，可以自己改。

剩下的才判讀：嚴重度 0–100、看起來能不能從 App 端修、可能的根因、建議處置，以及信心值。可以走 Claude Code CLI 吃你的訂閱，也可以填 key 直接呼叫 Anthropic API。

附一套中英雙語的 Web UI：分流清單帶每版頻率長條圖、可手動重新分類、需求待辦會讓 AI 讀你真實的 repo 來評估可行性，設定也在瀏覽器裡填。

可以直接開 GitHub 票並附上分析內容，順手 @claude 起個討論；再點一次可以請 AI 產草稿 PR，它會一直是 draft，要人來 merge。票和 PR 的狀態會同步回來。

花費上有幾道護欄：低於事件門檻不分析、單批有上限、內容沒變就不重跑。

## 快速開始

### 1 · 安裝前置工具（一次性）

| 工具 | 用途 | 備註 |
|---|---|---|
| [Claude Code CLI](https://claude.com/claude-code)（已登入） | 用訂閱跑 AI 分析 | 也可改填 Anthropic API key（設定 → 進階） |
| [`gh` CLI](https://cli.github.com)（已登入） | GitHub 開票／草稿 PR | 選用——不用 GitHub 功能可跳過 |

就這樣。**不用裝 Dart、不用裝 Flutter、不用處理 SQLite**——下面的 release 壓縮檔裡已經有編譯好的伺服器、打包好的 Web UI，Windows 版連 SQLite 函式庫都附上了。

### 2 · 跑起來

<table>
<tr><th></th><th>需要什麼</th><th>適合誰</th></tr>
<tr><td><b>A · 下載 release</b>（推薦）</td><td>什麼都不用裝</td><td>大多數人</td></tr>
<tr><td><b>B · Docker</b></td><td>Docker</td><td>本來就在跑容器、或想放在伺服器上</td></tr>
<tr><td><b>C · 從原始碼跑</b></td><td>Dart + Flutter</td><td>想改這個工具本身</td></tr>
</table>

#### A · 下載 release

1. 到 [**Releases**](https://github.com/NickC84/sentry-ai-triage/releases/latest)
   抓你機器對應的壓縮檔——`macos-arm64`（Apple Silicon）、`macos-x64`（Intel）、
   `linux-x64`、`linux-arm64`（樹莓派／ARM 伺服器）、`windows-x64`。
2. 解壓縮到任何你喜歡的位置。
3. 啟動：
   - **macOS**——雙擊 **`start.command`**。若被 macOS 擋下（未簽章），執行一次：
     `xattr -dr com.apple.quarantine /解壓縮後的資料夾`
   - **Linux**——`./start.sh`（或直接跑 `./sentry-triage`）
   - **Windows**——雙擊 **`start.bat`**

瀏覽器會開啟 `http://localhost:8787`；如果這個 port 被佔用，伺服器會自動往下找一個沒被用的，並印出實際位址（也可用 `--port 9000` 指定）。所有它寫出來的東西（`data/triage.db`、`data/config.json`）都在解壓縮的資料夾裡——刪掉資料夾就等於解除安裝。

無介面 CLI（`sentry-triage-ingest`、`-analyze`、`-feature`）也在同一個資料夾裡，可直接排程。

#### B · Docker

一次解決所有工具鏈問題，代價是兩個 mount：AI 跑在**你的** Claude 登入上、讀**你的** App repo，這兩樣都不可能包進 image 裡。

```bash
# 先讓容器裡的 Claude CLI 登入一次，憑證會留在 ~/.claude
docker run -it --rm -v "$HOME/.claude:/root/.claude" \
  ghcr.io/nickc84/sentry-ai-triage:latest claude

docker run -d -p 8787:8787 \
  -v "$PWD/data:/app/data" \
  -v "$HOME/.claude:/root/.claude" \
  -v "/你的/app-repo/絕對路徑:/workspace" \
  -e APP_REPO_PATH=/workspace \
  ghcr.io/nickc84/sentry-ai-triage:latest
```

發佈的 image 是 `linux/amd64`。Apple Silicon 請在兩行指令都加上 `--platform linux/amd64`（Docker Desktop 會模擬）；ARM 伺服器則建議改用 `linux-arm64` 的 release 壓縮檔。想 build 原生 image，`docker-compose.yml` 會從原始碼做同一件事（`docker compose up -d --build`）。

#### C · 從原始碼跑

需要 [Dart SDK](https://dart.dev/get-dart) ≥ 3.5 與
[Flutter](https://flutter.dev/docs/get-started/install) 3.24（CI 鎖的版本，較新的 stable 通常也能用）。

```bash
git clone https://github.com/NickC84/sentry-ai-triage
cd sentry-ai-triage
./start.sh          # macOS/Linux——首次啟動會打包 Web UI
                    # Windows：start.bat
```

請用 clone，不要下載原始碼 zip——GitHub 的 zip 會掉執行權限，`./start.sh` 會直接 `permission denied`（`chmod +x start.sh start.command` 可修）。

<details>
<summary>手動步驟／自己打包 bundle</summary>

```bash
dart pub get
cd ui && flutter pub get && flutter build web --no-web-resources-cdn && cd ..
dart run bin/serve.dart   # PORT=9000 或 --port 9000；NO_OPEN=1 不自動開瀏覽器

# 產出跟 CI 一樣的自帶一切壓縮檔內容：
packaging/build_bundle.sh --out dist/my-build
```

</details>

### 3 · 在瀏覽器裡連上你的 Sentry

打開**設定**（齒輪圖示）：貼上唯讀的 Sentry token——設定頁有直達 Sentry token 頁面的連結，也寫明要勾哪兩個權限——然後按**自動偵測**填入 org／project。回主畫面按**從 Sentry 拉取**，完成。其他都是選用。

設定頁最上面的**環境檢查**會告訴你：Claude CLI 有沒有裝、**有沒有登入**、`gh` 有沒有認證、填的 App repo 路徑是不是真的 git repo——少了什麼會直接顯示紅色一行加上修復指令，而不是等分析跑到一半才失敗。放在伺服器上的話，也可以在這裡設定**自動同步**（分析仍維持手動——那個要花錢，同步不用）。

每個按鈕在做什麼（噪音規則、AI 分析、開票、同步…），打開**設定 → 使用說明**——完整操作手冊就內建在 app 裡，中英雙語。

![設定頁——token 直達連結、自動偵測、進階收合](docs/screenshots/settings.png)

## 無介面 CLI

UI 能做的都能用指令跑（適合排程）。用 release bundle 的話：

```bash
./sentry-triage-ingest      # 拉取 + 規則分流 + 摘要
./sentry-triage-analyze     # 達門檻的 issue 批次 AI 分析
./sentry-triage-feature     # 需求可行性分析
```

從原始碼跑則是 `dart run bin/ingest.dart`、`bin/analyze.dart`、`bin/feature.dart`。每支執行檔都支援 `--version`。

## AI 引擎怎麼運作

`AI_MODE=claude_cli`（預設）用 JSON schema 呼叫 `claude -p`——分析跑在你現有的 Claude 訂閱上。`AI_MODE=anthropic_api` 則直接用 `ANTHROPIC_API_KEY` 呼叫 API。`CLI_COMMAND` 可以指向任何相容的 agentic CLI。

在設定裡填 **App context**（描述你的 App：平台、什麼算核心功能、已知的噪音來源），分析準確度會明顯提升。AI 輸出語言自動跟隨介面語言。

## 資料與隱私

一切都在本地：SQLite 在 `data/`、設定在 `data/config.json`（已 gitignore，UI 裡機密欄位有遮罩），位置固定在執行檔旁邊（從原始碼跑就是 repo 根目錄），可用 `TRIAGE_HOME` 改。唯二的對外連線是你的 Sentry、Claude，以及（選用的）GitHub。

## 發佈新版

```bash
git tag v1.2.0 && git push --tags
```

CI 會打包一次 Web UI、編出 macOS（arm64／x64）／Linux（x64／arm64）／Windows 的原生執行檔，並在**不相干的目錄下實際跑一次**做煙霧測試，推送 container image 到 GHCR，最後把壓縮檔與 `SHA256SUMS.txt` 掛到 GitHub release。工具鏈版本鎖在 `.github/workflows/release.yml`。

公開 repo 推上 GHCR 的 package 本身就是公開可 pull 的——已用匿名 pull 驗證過。GHCR 沒有改 visibility 的 API，萬一哪天真的變成 private，只能手動到
`https://github.com/users/<owner>/packages/container/sentry-ai-triage/settings` 切換。

## 授權

[MIT](LICENSE)
