part of '../ai_analyzer.dart';

/// Prompt builders — kept next to their JSON schemas so the contract between
/// what we ask for and what we validate stays in one place.
extension AiPrompts on AiAnalyzer {
  String get _langInstruction => outputLanguage == 'zh-Hant'
      ? 'Write root_cause_summary and recommended_action in Traditional Chinese (繁體中文).'
      : 'Write root_cause_summary and recommended_action in English.';

  String get _appContextSection => appContext.trim().isEmpty
      ? '(No app context provided — judge from the issue itself. '
          'You can describe your app in Settings → App context to improve accuracy.)'
      : appContext.trim();

  String _buildPrompt({
    required String shortId,
    required String title,
    required String culprit,
    required String level,
    required int totalCount,
    required int userCount,
    required String? firstSeen,
    required String? lastSeen,
    required List<String> releaseLines,
  }) {
    final rel = releaseLines.isEmpty
        ? '(no per-release data)'
        : releaseLines.map((l) => '  - $l').join('\n');
    return '''
You are an expert at triaging application crashes. Below is a Sentry issue. Judge its severity and whether it is a bug fixable in the app's own code.

## App context
$_appContextSection

## Issue ($shortId)
- Title: $title
- Culprit: ${culprit.isEmpty ? '(none)' : culprit}
- Level: $level
- Events (stats period): $totalCount, users affected: $userCount
- First seen: ${firstSeen ?? '—'}, last seen: ${lastSeen ?? '—'}
- Per-release frequency (release → events):
$rel

## Criteria
- severity_score (0–100): weigh frequency, users affected, and whether core functionality is blocked.
- is_app_fixable:
  - app_fixable = fixable in the app's own code (logic, state, null-safety, API integration…).
  - not_fixable = device driver/firmware, OS, or transient external network issues.
  - needs_more_data = missing stack trace / event details.
- root_cause_summary / recommended_action: concise and actionable. $_langInstruction

Output only JSON matching the schema.''';
  }

  String _buildFeaturePrompt({required String title, required String detail}) {
    final lang = outputLanguage == 'zh-Hant'
        ? 'Write summary / approach / risks in Traditional Chinese (繁體中文).'
        : 'Write summary / approach / risks in English.';

    return '''
You are a senior engineer on this project. A user proposed a new feature. **Actually read the project code** (use file/search tools), then assess feasibility and give a pragmatic plan.

## Feature request
Title: $title
Detail: ${detail.isEmpty ? '(none provided)' : detail}

## Your job
1. Read the relevant existing implementation and judge how this fits the current architecture.
2. feasibility: feasible (straightforward) / hard (doable, large change) / blocked (hard blocker) / needs_info (unclear requirements).
3. effort: S / M / L / XL (relative).
4. priority_score (0–100): suggested priority weighing user value vs. implementation cost (advisory only — a human decides).
5. affected_areas: the real files/modules you found that would change.
6. approach: recommended, actionable steps.
7. risks: risks or watch-outs.
$lang

Output only JSON matching the schema. Base everything on real code — do not guess.''';
  }
}

const _schema = {
  'type': 'object',
  'properties': {
    'severity_score': {
      'type': 'integer',
      'description':
          'Severity 0–100 (frequency, users affected, whether core features are blocked)',
    },
    'is_app_fixable': {
      'type': 'string',
      'enum': ['app_fixable', 'not_fixable', 'needs_more_data'],
      'description':
          'Fixable in app code / device-layer or external (not fixable) / not enough data',
    },
    'root_cause_summary': {
      'type': 'string',
      'description': '1–3 sentence root cause',
    },
    'recommended_action': {'type': 'string', 'description': 'Suggested action'},
    'confidence': {'type': 'number', 'description': '0–1 confidence'},
  },
  'required': [
    'severity_score',
    'is_app_fixable',
    'root_cause_summary',
    'recommended_action',
    'confidence',
  ],
};

const _featureSchema = {
  'type': 'object',
  'properties': {
    'feasibility': {
      'type': 'string',
      'enum': ['feasible', 'hard', 'blocked', 'needs_info'],
    },
    'effort': {
      'type': 'string',
      'enum': ['S', 'M', 'L', 'XL'],
    },
    'priority_score': {'type': 'integer'},
    'summary': {'type': 'string', 'description': 'Feasibility summary'},
    'approach': {'type': 'string', 'description': 'Recommended approach/steps'},
    'affected_areas': {
      'type': 'string',
      'description': 'Real files/modules that would change',
    },
    'risks': {'type': 'string', 'description': 'Risks or watch-outs'},
    'confidence': {'type': 'number'},
  },
  'required': [
    'feasibility',
    'effort',
    'priority_score',
    'summary',
    'approach',
    'affected_areas',
    'risks',
    'confidence',
  ],
};
