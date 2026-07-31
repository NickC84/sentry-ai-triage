# Sentry 問題分流 + AI 分析 Pipeline — 架構規格

> 目的:用**已付費的 Claude Code** 取代 Sentry Seer 的付費 AI,自建一套「撈取 → 分流 → 趨勢分析 → AI 判斷 → 開票/開 PR → 人工 review → merge」的流程。核心價值:**先過濾裝置層噪音,只把真正可修的 App bug 丟給 AI**,省成本又貼合需求。
>
> 狀態:草稿規格（待確認開放決策後動工）
> 相關記憶:[已知裝置層崩潰分類](../../memory 內 project_rendering_native_crash / project_known_crashes)

---

## 1. 設計原則

1. **不重寫 Sentry 已做好的重活**:崩潰收集、分組、native 符號化、去重、session replay、即時 Alerts —— 這些繼續靠 Sentry,我們只把「處理好的結果」撈出來。
2. **分流優先於自動化**:已知裝置層崩潰（DeadSystemException / libGLES_mali / 特定機型 SIGTRAP）先自動歸類為 `known_noise`，**排除在 AI 分析與通知之外**。這是最大的省錢點。
3. **人在迴圈中（human-in-the-loop）**:AI 可開票、可開 **draft PR**，但**永不自動 merge** production。
4. **成本護欄**:只分析「未隱藏 + 影響達門檻」的 issue；分析結果快取，僅在顯著變化時重跑。
5. **保留期獨立**:自己存快照，做跨版本長期趨勢，不受 Sentry 免費方案 ~30 天保留限制。

---

## 2. 高階架構

```
Sentry（收集 / 分組 / 符號化 / Alerts）
      │  REST API（唯讀）
      ▼
┌─────────────────┐     ┌──────────────────────────────┐
│ Ingestion Worker │────▶│ Local DB (SQLite/Postgres)   │
│ (cron 5–15 min)  │     │ issues / release_stats /     │
└─────────────────┘     │ snapshots / ai_analysis /    │
                        │ triage_rules                 │
                        └──────────────────────────────┘
              ┌───────────────┬────────────────┬─────────────┐
              ▼               ▼                ▼             ▼
        Triage UI      Analysis Orchestrator  Action Layer   Digest
      (Flutter Web)    (Claude Agent SDK)     (GitHub 開票/PR)（可選）
              │               │                │
        人工分流         AI 分級/分類      開票 + draft PR
      (隱藏/保留/噪音)   (省成本門檻)          │
              └──────────────────────────────▶ 人工 review → merge
```

**分工原則**:Sentry = 資料來源與即時通知；本系統 = 整理 / 分流 / 趨勢 / AI 判斷 / 開票開 PR。

---

## 3. 元件規格

### 3.1 Ingestion Worker（排程撈取）
- **頻率**:cron 每 5–15 分鐘（可調）。
- **資料來源**:Sentry REST API（唯讀 token，`project:read` + `event:read`）。
  - 列 issues：`GET /api/0/projects/{org}/{proj}/issues/?query=...&sort=freq`
  - 依版本聚合：`GET /api/0/organizations/{org}/events/`（Discover 查詢，`release` 分組）
  - 單一 issue 事件：`GET /api/0/issues/{id}/events/`（取 device.model / os / release 等 tag）
- **增量策略**:用 `lastSeen` + cursor 分頁，只拉新增/變動的 issue。
- **寫入**:更新 `issues`、寫 `issue_release_stats`、每次寫一筆 `issue_snapshots`（做時間序列）。
- **冪等**:以 `sentry_issue_id` upsert，重跑不產生重複。

### 3.2 資料庫 Schema

```
issues
  sentry_issue_id   TEXT PK
  short_id          TEXT           -- e.g. FLUTTER-CF
  title             TEXT
  culprit           TEXT
  level             TEXT           -- fatal/error/...
  category          TEXT           -- app_bug | device_layer | unknown（自動+人工）
  triage_state      TEXT           -- new | keep | hidden | known_noise | resolved
  triage_note       TEXT
  first_seen        DATETIME
  last_seen         DATETIME
  permalink         TEXT
  updated_at        DATETIME

issue_release_stats               -- 每版頻率
  sentry_issue_id   TEXT
  release           TEXT           -- 1.5.51 (130)
  event_count       INTEGER
  first_seen_in_release DATETIME
  last_seen_in_release  DATETIME
  PRIMARY KEY (sentry_issue_id, release)

issue_snapshots                   -- 趨勢時間序列（保留期獨立的關鍵）
  sentry_issue_id   TEXT
  captured_at       DATETIME
  total_count       INTEGER
  user_count        INTEGER

releases
  version           TEXT PK        -- 1.5.51
  build             INTEGER        -- 130
  released_at       DATETIME

ai_analysis
  sentry_issue_id   TEXT
  analyzed_at       DATETIME
  severity_score    INTEGER        -- 0–100
  is_app_fixable    BOOLEAN
  root_cause_summary TEXT
  recommended_action TEXT
  confidence        REAL
  ticket_url        TEXT
  pr_url            TEXT
  model             TEXT
  input_context_hash TEXT          -- 用來判斷是否需要重跑

triage_rules                      -- 自動分流規則
  id                INTEGER PK
  match_type        TEXT           -- title | culprit | tag | signal
  pattern           TEXT           -- e.g. "DeadSystemException"
  set_category      TEXT           -- device_layer
  set_state         TEXT           -- known_noise
  note              TEXT
```

### 3.3 Triage UI（Flutter Web，重用你們技能）
- **列表**:欄位 = 標題、category、總次數、趨勢（▲▼ 對比上次快照）、影響裝置/站點數、每版 sparkline、triage 狀態。
- **預設過濾**:隱藏 `hidden` / `known_noise`，一鍵切換「顯示全部」。
- **動作**:單筆/批次標記 `hidden` / `known_noise` / `keep`、加註記。← **這就是你要的「打勾隱藏不重要/短期重複」**。
- **自動建議**:`triage_rules` 命中的先預標 `device_layer / known_noise`，你只要確認。
- **明細頁**:事件樣本、裝置分佈、每版頻率圖、AI 分析結果、連回 Sentry / GitHub。

### 3.4 Analysis Orchestrator（AI，用 Claude Code / Agent SDK）
- **觸發**:排程對「未隱藏 + 影響達門檻」的 issue 跑；或 UI 上手動「分析」。
- **輸入給 AI**:issue metadata + 代表性 stack trace + 裝置/版本分佈 + **repo 存取**（Claude Code 本來就能讀 code）。
- **輸出（結構化）**:
  - `severity_score`（0–100，附理由）
  - `is_app_fixable`（App 可修 / 裝置層不可修 / 需更多資料）
  - `root_cause_summary`、`recommended_action`、`confidence`
- **成本護欄**:
  - 只分析 `triage_state ∈ {new, keep}` 且次數/影響 ≥ 門檻。
  - 用 `input_context_hash` 快取；context 沒顯著變化不重跑。
  - `known_noise` / `device_layer` **完全不送 AI**。
- **執行機制**:Claude Code headless（`claude -p`）或 **Claude Agent SDK**，可用 cron 或 `/schedule` routine 排程。

### 3.5 Action Layer（開票 + PR）
- **開票**:`is_app_fixable = true` 且達門檻 → 建 GitHub issue（含 AI 摘要 + Sentry 連結 + 裝置/版本數據）。
- **開 PR**:可選,Claude Code 在分支上產生**修復草稿 → draft PR**。
- **人工迴圈**:draft 狀態,**你 review 後才 merge**，永不自動 merge。
- **去重**:`ai_analysis.ticket_url / pr_url` 回寫 DB，避免同一 issue 重複開票。

### 3.6 通知（不重寫）
- **即時**:繼續用 Sentry Alerts（Slack/Email）。
- **可選 digest**:本系統每日/每週推一則「新 App-可修 issue + AI 嚴重度 + 已開票」摘要到 Slack。

---

## 4. 分階段交付（MVP → 完整）

| Phase | 內容 | 驗證點 |
|---|---|---|
| **0 MVP** | Ingestion Worker + DB + 唯讀清單（含每版次數） | 資料撈得到、格式正確 |
| **1** | Triage UI：隱藏/known_noise + 自動分流規則 | 裝置層噪音一鍵消失 |
| **2** | AI 分析（嚴重度 + 分類）顯示在 UI | 只花在可修 issue 上 |
| **3** | 自動開 GitHub 票 | 不重複、含足夠 context |
| **4** | AI draft PR + review 流程 | 人工 review 後才 merge |
| **5** | Digest 通知 | 每日摘要可讀 |

---

## 5. 建議技術棧（預設，可調）

| 層 | 建議 | 理由 |
|---|---|---|
| Ingestion + Backend | Dart（`shelf`/`dart_frog`）或 Node/Python | 用 Dart 可與團隊同語言；否則 Node/Python 生態最快 |
| DB | 先 **SQLite**，需多人再換 Postgres | 單人維運工具，SQLite 夠且零維運 |
| UI | **Flutter Web** | 重用你們既有技能 |
| AI 執行 | Claude Code headless / Claude Agent SDK | 重用已付費額度 |
| 排程 | cron / `/schedule` routine | 簡單 |
| 部署 | 本機 Mac mini 或小 VPS | 單人、低流量 |

---

## 6. 決策（已拍板 / 待確認）

| # | 決策 | 結果 |
|---|---|---|
| 1 | 工具放哪 | ✅ monorepo `tools/sentry_triage/`（不進 App build） |
| 2 | 單人還是多人用 | ✅ **單人 + 本機**（SQLite、免認證、跑本機/Mac mini） |
| 3 | 資料來源 | ✅ 排程用 REST API；互動式分析可另接 Sentry MCP |
| 4 | UI 技術 | ✅ **Flutter Web** |
| 5 | 部署位置 | ✅ 本機/Mac mini 起步 |
| 6 | 是否納入 OpenSpec 正式追蹤 | ⬜ 可選,若要正式追蹤再轉 openspec proposal |

> 決策確認於 2026-07-22。單人本機 + SQLite + Flutter Web 為定案技術方向。

---

## 7. 風險與備註
- **Sentry API rate limit**:每 5–15 分鐘輪詢即可,別做即時。
- **免費方案事件保留 ~30 天**:所以 `issue_snapshots` 自己存,才有長期趨勢。
- **AI 成本**:靠「分流門檻 + 快取 + 不送 known_noise」控制,別對全部 issue 無腦跑。
- **不自動 merge**:production 修改一律 draft PR + 人工 review。
- **保持 Sentry Alerts**:即時通知不要自建。
```
