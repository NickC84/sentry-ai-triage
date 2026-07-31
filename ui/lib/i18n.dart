// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Tiny i18n: en / zh (Traditional Chinese). Locale persists to localStorage;
/// first visit follows the browser language.
class I18n {
  static final ValueNotifier<String> locale = ValueNotifier(_initial());

  static String _initial() {
    final saved = html.window.localStorage['triage_locale'];
    if (saved == 'en' || saved == 'zh') return saved!;
    final lang = ui.PlatformDispatcher.instance.locale.languageCode;
    return lang == 'zh' ? 'zh' : 'en';
  }

  static bool get isZh => locale.value == 'zh';

  static void toggle() {
    locale.value = isZh ? 'en' : 'zh';
    html.window.localStorage['triage_locale'] = locale.value;
  }

  /// t('key') → localized string. Unknown keys return the key itself.
  static String t(String key) {
    final v = _s[key];
    if (v == null) return key;
    return isZh ? v[1] : v[0];
  }

  // [en, zh]
  static const Map<String, List<String>> _s = {
    'appTitle': ['Sentry AI Triage', 'Sentry AI 分流'],
    'tabBugs': ['Bugs (Sentry)', 'Bug（Sentry）'],
    'tabFeatures': ['Features', '需求'],
    'newFeature': ['New feature', '新增需求'],
    'syncStatus': ['Sync states', '同步狀態'],
    'syncing': ['Syncing…', '同步中…'],
    'syncFromSentry': ['Sync from Sentry', '從 Sentry 拉取'],
    'ingesting': ['Fetching…', '拉取中…'],
    'ingestDone': ['Fetched {n} issues from Sentry', '已從 Sentry 拉取 {n} 筆 issue'],
    'ingestFail': ['Ingest failed: {e}', '拉取失敗：{e}'],
    'showNoise': ['Show noise', '顯示噪音'],
    'refresh': ['Refresh', '重新整理'],
    'settings': ['Settings', '設定'],
    'chipNew': ['new', '待看'],
    'chipNoise': ['noise', '噪音'],
    'searchHint': ['Search title / short id / culprit', '搜尋標題 / short id / culprit'],
    'allCategories': ['All categories', '全部分類'],
    'sort': ['Sort', '排序'],
    'sortCount': ['Events', '次數'],
    'sortPriority': ['Priority', '優先度'],
    'itemsCount': ['{n} items', '{n} 筆'],
    'emptyList': ['No matching issues', '沒有符合條件的 issue'],
    'emptyListFirstRun': [
      'No data yet — open Settings, fill in Sentry, then hit "Sync from Sentry".',
      '還沒有資料——先到「設定」填 Sentry 資訊，再按「從 Sentry 拉取」。'
    ],
    'backendDown': ['Cannot reach the backend:\n{e}', '連不到後端：\n{e}'],
    'backendHint': ['Start it with: dart run bin/serve.dart', '請先啟動：dart run bin/serve.dart'],
    'retry': ['Retry', '重試'],
    'detailPlaceholder': [
      '← Pick an issue to see details & per-release frequency',
      '← 點左邊任一 issue 看每版頻率與明細'
    ],
    // categories
    'cat_app_bug': ['App bug', 'App Bug'],
    'cat_device_layer': ['Device layer', '裝置層'],
    'cat_network_noise': ['Network noise', '網路噪音'],
    'cat_log_event': ['Log event', 'Log 事件'],
    'cat_feature': ['Feature', '需求'],
    'cat_unknown': ['Uncategorized', '未分類'],
    // triage states
    'st_new': ['New', '待看'],
    'st_keep': ['Keep', '保留'],
    'st_hidden': ['Hidden', '隱藏'],
    'st_known_noise': ['Known noise', '已知噪音'],
    'st_resolved': ['Resolved', '已解決'],
    // fixability
    'fix_app_fixable': ['App-fixable', 'App 可修'],
    'fix_not_fixable': ['Not fixable', '不可修'],
    'fix_needs_more_data': ['Needs more data', '需更多資料'],
    // feasibility
    'feas_feasible': ['Feasible', '可做'],
    'feas_hard': ['Hard', '較難'],
    'feas_blocked': ['Blocked', '受阻'],
    'feas_needs_info': ['Needs info', '需澄清'],
    'sevPrefix': ['sev {s}', '嚴重 {s}'],
    'effortPrefix': [' · effort {e}', ' · 工作量 {e}'],
    'priorityShort': ['prio {p}', '優先 {p}'],
    'usersSuffix': ['{n} users', '{n} 人'],
    'setStateTip': ['Set triage state', '設定分流狀態'],
    'setCategoryTip': ['Set category', '設定分類'],
    'categoryLabel': ['Category: ', '分類：'],
    'stateLabel': ['State: ', '狀態：'],
    'noteLabel': ['Note: {n}', '註記：{n}'],
    // detail metas
    'metaTotal': ['Events', '總次數'],
    'metaUsers': ['Users', '影響人數'],
    'metaLevel': ['Level', '等級'],
    'metaFirst': ['First seen', '首次'],
    'metaLast': ['Last seen', '最近'],
    // AI section
    'aiSection': ['🤖 AI analysis', '🤖 AI 分析'],
    'aiAnalyze': ['Analyze', '分析'],
    'aiReanalyze': ['Re-analyze', '重新分析'],
    'aiAnalyzing': ['Analyzing…', '分析中…'],
    'aiWaitBug': ['Analyzing with AI, ~15–30s…', 'AI 分析中，約 15–30 秒…'],
    'aiNotYetBug': [
      'Not analyzed yet. Hit "Analyze" to judge severity & fixability.',
      '尚未分析。點右上「分析」判斷嚴重度與可修性。'
    ],
    'confidence': ['confidence {p}%', '信心 {p}%'],
    'rootCause': ['Root cause', '根因'],
    'recommended': ['Recommended action', '建議處置'],
    // feature section
    'featureSection': ['🤖 Feasibility (AI reads your repo)', '🤖 需求可行性（AI 讀 repo）'],
    'featureAnalyze': ['Assess feasibility', '分析可行性'],
    'featureWait': [
      'AI is reading your app repo, ~1–5 minutes…',
      'AI 讀 App repo 評估中，約 1–5 分鐘…'
    ],
    'featureNotYet': [
      'Not assessed yet. Hit "Assess feasibility" to let the AI read real code.',
      '尚未分析。點右上「分析可行性」讓 AI 讀真實 code 評估。'
    ],
    'suggestedPriority': ['priority {p}', '建議優先度 {p}'],
    'summaryField': ['Summary', '可行性摘要'],
    'affected': ['Affected areas', '影響範圍'],
    'approach': ['Approach', '建議做法'],
    'risks': ['Risks', '風險'],
    'selectedDevYes': [
      'Selected for dev (ticket opened — continue with @claude on GitHub)',
      '要開發（已開票，去 GitHub 跟 @claude 討論並實作）'
    ],
    'selectedDevNo': [
      'No ticket yet — hit "Ticket + discuss"; it will auto-@claude to start the discussion',
      '尚未開票——先按右上「開票 + 討論」，開票後會自動 @claude 開始討論'
    ],
    // releases
    'releaseFreq': ['Per-release frequency', '每版頻率'],
    'releaseError': ['Failed to load release stats: {e}', '讀取每版頻率失敗：{e}'],
    'releaseEmpty': [
      '(No per-release data. Noise issues skip release stats by default.)',
      '（這個 issue 沒有每版頻率資料。噪音類 issue 預設不抓每版分佈。）'
    ],
    // ticket button
    'ticketGo': ['Discuss / develop on GitHub', '去 GitHub 討論 / 開發'],
    'ticketGoTip': [
      'Open the GitHub issue: discuss with @claude, confirm the spec, then ask it to implement',
      '到 GitHub issue 跟 @claude 討論、確認規格後請它實作'
    ],
    'ticketClosed': ['Ticket closed', '票已關閉'],
    'ticketDeleted': ['Ticket deleted', '票已刪除'],
    'ticketCreate': ['Ticket + discuss', '開票 + 討論'],
    'ticketCreateTip': [
      'Open a GitHub issue and auto-@claude to start the discussion',
      '開 GitHub 票並自動 @claude 開啟討論'
    ],
    'ticketNeedBug': ['Analyze first, then open a ticket', '先按下方「分析」，分析後才能開票'],
    'ticketNeedFeature': [
      'Assess feasibility first, then open a ticket',
      '先按下方「分析可行性」，分析後才能開票'
    ],
    'ticketAlready': ['This item already has a ticket', '這項已經開過票了'],
    'ticketOpened': [
      'Ticket opened & @claude pinged — continue on GitHub',
      '已開票，並已 @claude 開啟討論——點「去 GitHub 討論 / 開發」繼續'
    ],
    'ticketOpenedNoComment': [
      'Ticket opened (the @claude comment failed — you can @claude on the issue yourself)',
      '已開票（@claude 留言未成功，可自行到 issue @claude）'
    ],
    // dialogs & snacks
    'deleteFeatureTitle': ['Delete feature', '刪除需求'],
    'deleteFeatureBody': ['Delete "{t}"? This cannot be undone.', '確定刪除「{t}」？此動作無法復原。'],
    'cancel': ['Cancel', '取消'],
    'delete': ['Delete', '刪除'],
    'deleted': ['Deleted', '已刪除'],
    'newFeatureTitle': ['New feature', '新增需求'],
    'featureTitleLabel': ['Feature title', '需求標題'],
    'featureTitleHint': ['One sentence describing what you want', '一句話描述想做什麼'],
    'featureDetailLabel': ['Details (optional)', '詳細說明（選填）'],
    'featureDetailHint': [
      'Background, expected behavior, constraints… clearer = better AI assessment',
      '背景、預期行為、限制… 越清楚 AI 評估越準'
    ],
    'add': ['Add', '新增'],
    'featureCreated': [
      'Feature added — hit "Assess feasibility" to let the AI read your code',
      '已新增需求，點「分析可行性」讓 AI 讀 code 評估'
    ],
    'genericFail': ['Failed: {e}', '失敗：{e}'],
    'syncedN': ['Synced {n} GitHub ticket/PR states', '已同步 {n} 個 GitHub 票/PR 狀態'],
    // settings page
    'settingsTitle': ['Settings', '設定'],
    'settingsSave': ['Save', '儲存'],
    'settingsSaved': ['Settings saved', '設定已儲存'],
    'settingsSecretHint': [
      'Saved. Leave masked to keep the current value.',
      '已儲存。保持遮罩即沿用現值。'
    ],
    'settingsSentry': ['Sentry', 'Sentry'],
    'settingsSentryBase': ['Base URL (self-hosted only)', 'Base URL（自架 Sentry 才需要改）'],
    'settingsOrg': ['Organization slug', 'Organization slug'],
    'settingsProject': ['Project slug', 'Project slug'],
    'settingsToken': ['Auth token (read-only: project:read + event:read)', 'Auth Token（唯讀：project:read + event:read）'],
    'settingsPeriod': ['Stats period (days)', '統計期間（天）'],
    'settingsAi': ['AI analysis', 'AI 分析'],
    'settingsAiMode': ['Engine', '引擎'],
    'settingsAiModeCli': ['Claude Code CLI (subscription — no API cost)', 'Claude Code CLI（訂閱制，零 API 費）'],
    'settingsAiModeApi': ['Anthropic API (API key)', 'Anthropic API（API key）'],
    'settingsAiModel': ['Model (sonnet / haiku / opus / full id)', '模型（sonnet / haiku / opus / 完整 id）'],
    'settingsApiKey': ['Anthropic API key (api mode only)', 'Anthropic API key（僅 API 模式）'],
    'settingsCliCmd': ['CLI command (swap in a compatible wrapper)', 'CLI 指令（可換相容的其他 AI CLI）'],
    'settingsAppContext': ['App context — describe your app for the AI', 'App 背景——描述你的 App 給 AI'],
    'settingsAppContextHint': [
      'e.g. "Flutter kiosk app on low-end Android TV boxes; video playback is core; device/network crashes are usually not fixable."',
      '例：「跑在低階 Android TV 盒上的 Flutter 看板 App；影片播放是核心功能；裝置/網路類崩潰通常不可修。」'
    ],
    'settingsOutputLang': ['AI output language', 'AI 輸出語言'],
    'settingsMinEvents': ['Min events before AI (cost guardrail)', '送 AI 的最低事件數（成本護欄）'],
    'settingsMaxIssues': ['Max issues per batch (cost guardrail)', '單次批次上限（成本護欄）'],
    'settingsGithub': ['GitHub', 'GitHub'],
    'settingsRepo': ['Target repo (owner/repo)', '目標 repo（owner/repo）'],
    'settingsGhToken': ['Token (optional; empty = current gh login)', 'Token（選填；留空用目前 gh 登入）'],
    'settingsPrModel': ['Draft-PR model', '產草稿 PR 模型'],
    'settingsGitRemote': ['Git remote pointing at GitHub', '指向 GitHub 的 git remote 名稱'],
    'settingsAppRepo': ['App repo path (for feasibility analysis)', 'App repo 路徑（需求可行性分析用）'],
    'settingsLoadFail': ['Failed to load settings: {e}', '讀取設定失敗：{e}'],
    'settingsSaveFail': ['Failed to save: {e}', '儲存失敗：{e}'],
    'settingsGetToken': ['Create a read-only token on Sentry ↗', '去 Sentry 建立唯讀 token ↗'],
    'settingsDetect': ['Find my orgs / projects', '自動偵測 org / project'],
    'settingsDetecting': ['Detecting…', '偵測中…'],
    'settingsDetectHint': [
      'Paste the token above first',
      '請先在上面貼上 token'
    ],
    'settingsDetectEmpty': [
      'Token works, but no organizations were found',
      'token 有效，但找不到任何組織'
    ],
    'settingsDetectPick': ['Tap to fill in:', '點一下自動填入：'],
    'settingsAdvanced': [
      'Advanced — the defaults work out of the box',
      '進階設定——預設值可直接使用'
    ],
    'settingsGithubHint': [
      'Optional — only needed for one-click tickets / draft PRs',
      '選用——要一鍵開票 / 產草稿 PR 才需要'
    ],
  };
}

/// Shorthand.
String t(String key) => I18n.t(key);

/// t() with {placeholder} substitution.
String tp(String key, Map<String, Object?> params) {
  var s = I18n.t(key);
  params.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}
