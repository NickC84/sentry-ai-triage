import 'package:flutter/material.dart';

import 'api.dart';
import 'help_page.dart';
import 'i18n.dart';
import 'ui_helpers.dart';

/// Edits everything in the backend's editable config via /api/config.
/// Secrets come back masked; leaving them masked keeps the stored value.
class SettingsPage extends StatefulWidget {
  final TriageApi api;
  const SettingsPage({required this.api, super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _ctls = <String, TextEditingController>{};
  String _aiMode = 'claude_cli';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // Sentry org/project discovery state.
  bool _detecting = false;
  List<dynamic>? _discovered;

  static const _textKeys = [
    'SENTRY_BASE_URL',
    'SENTRY_ORG',
    'SENTRY_PROJECT',
    'SENTRY_TOKEN',
    'STATS_PERIOD_DAYS',
    'AI_MODEL',
    'ANTHROPIC_API_KEY',
    'CLI_COMMAND',
    'APP_CONTEXT',
    'AI_MIN_EVENTS',
    'AI_MAX_ISSUES',
    'APP_REPO_PATH',
    'GITHUB_REPO',
    'GITHUB_TOKEN',
    'PR_MODEL',
    'GIT_REMOTE',
  ];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadConfig() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.getConfig();
      final cfg = (res['config'] as Map<String, dynamic>? ?? {});
      for (final k in _textKeys) {
        _ctls[k] = TextEditingController(text: (cfg[k] ?? '').toString());
      }
      _aiMode = (cfg['AI_MODE'] ?? 'claude_cli').toString();
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = tp('settingsLoadFail', {'e': e});
        _loading = false;
      });
    }
  }

  /// Call the backend to list orgs/projects for the pasted token, then let
  /// the user tap to fill the slug fields.
  Future<void> _detect() async {
    final token = _ctls['SENTRY_TOKEN']!.text.trim();
    if (token.isEmpty) {
      _snack(t('settingsDetectHint'));
      return;
    }
    setState(() {
      _detecting = true;
      _discovered = null;
    });
    try {
      final orgs = await widget.api.discoverSentry(
        token: token,
        sentryBaseUrl: _ctls['SENTRY_BASE_URL']!.text.trim(),
      );
      setState(() => _discovered = orgs);
      // Exactly one org/project pair → no choice to make, fill & save it.
      final pairs = <List<String>>[
        for (final o in orgs)
          for (final p
              in ((o as Map<String, dynamic>)['projects'] as List<dynamic>? ??
                  []))
            [o['org'].toString(), p.toString()]
      ];
      if (pairs.length == 1) {
        await _fillAndSave(pairs.first[0], pairs.first[1]);
      } else if (orgs.isEmpty && mounted) {
        _snack(t('settingsDetectEmpty'));
      }
    } catch (e) {
      if (mounted) _snack(tp('genericFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  /// Fill the slug fields from discovery and persist right away — no extra
  /// "save" step for the common path.
  Future<void> _fillAndSave(String org, String project) async {
    setState(() {
      _ctls['SENTRY_ORG']!.text = org;
      _ctls['SENTRY_PROJECT']!.text = project;
    });
    await _save(successMsg: tp('settingsAutoFilled', {'p': '$org / $project'}));
  }

  Future<void> _save({String? successMsg}) async {
    setState(() => _saving = true);
    try {
      final values = <String, String>{
        for (final k in _textKeys) k: _ctls[k]!.text.trim(),
        'AI_MODE': _aiMode,
      };
      await widget.api.saveConfig(values);
      if (mounted) _snack(successMsg ?? t('settingsSaved'));
    } catch (e) {
      if (mounted) _snack(tp('settingsSaveFail', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String key, String label,
      {bool secret = false, int maxLines = 1, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _ctls[key],
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: secret ? t('settingsSecretHint') : null,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 10),
            child: Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          ...children,
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('settingsTitle')),
        actions: [
          FilledButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(t('settingsSave')),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorBody()
              : _form(),
    );
  }

  Widget _errorBody() => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: _loadConfig, child: Text(t('retry'))),
      ]));

  Widget _form() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const _PreferenceCards(),
            _section(t('settingsSentry'), [
              _tokenHelp(),
              _field('SENTRY_TOKEN', t('settingsToken'), secret: true),
              _detectButton(),
              DiscoveredPicker(
                orgs: _discovered,
                onPick: _fillAndSave,
                onPickOrg: (org) =>
                    setState(() => _ctls['SENTRY_ORG']!.text = org),
              ),
              _field('SENTRY_ORG', t('settingsOrg')),
              _field('SENTRY_PROJECT', t('settingsProject')),
              _field('SENTRY_BASE_URL', t('settingsSentryBase')),
              _field('STATS_PERIOD_DAYS', t('settingsPeriod')),
            ]),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(t('settingsAdvanced'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              childrenPadding: EdgeInsets.zero,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section(t('settingsAi'), [
                  _aiModeDropdown(),
                  _field('AI_MODEL', t('settingsAiModel')),
                  _field('ANTHROPIC_API_KEY', t('settingsApiKey'),
                      secret: true),
                  _field('CLI_COMMAND', t('settingsCliCmd')),
                  _field('APP_CONTEXT', t('settingsAppContext'),
                      maxLines: 4, hint: t('settingsAppContextHint')),
                  _field('AI_MIN_EVENTS', t('settingsMinEvents')),
                  _field('AI_MAX_ISSUES', t('settingsMaxIssues')),
                ]),
                _section(t('settingsGithub'), [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(t('settingsGithubHint'),
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ),
                  _field('GITHUB_REPO', t('settingsRepo')),
                  _field('GITHUB_TOKEN', t('settingsGhToken'), secret: true),
                  _field('PR_MODEL', t('settingsPrModel')),
                  _field('GIT_REMOTE', t('settingsGitRemote')),
                  _field('APP_REPO_PATH', t('settingsAppRepo')),
                ]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tokenHelp() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton.icon(
              onPressed: () {
                final base = _ctls['SENTRY_BASE_URL']!.text.trim();
                openUrl(
                    '${base.isEmpty ? 'https://sentry.io' : base}/settings/account/api/auth-tokens/');
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(t('settingsGetToken')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(t('settingsTokenSteps'),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      );

  Widget _detectButton() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _detecting ? null : _detect,
            icon: _detecting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.travel_explore, size: 16),
            label:
                Text(_detecting ? t('settingsDetecting') : t('settingsDetect')),
          ),
        ),
      );

  Widget _aiModeDropdown() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          value: _aiMode,
          decoration: InputDecoration(
            labelText: t('settingsAiMode'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem(
                value: 'claude_cli', child: Text(t('settingsAiModeCli'))),
            DropdownMenuItem(
                value: 'anthropic_api', child: Text(t('settingsAiModeApi'))),
          ],
          onChanged: (v) => setState(() => _aiMode = v ?? 'claude_cli'),
        ),
      );
}

/// Top-of-page cards: the user guide link and the dark-theme switch.
class _PreferenceCards extends StatelessWidget {
  const _PreferenceCards();

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: Text(t('settingsHelp')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const HelpPage())),
        ),
      ),
      Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ValueListenableBuilder<String>(
          valueListenable: AppTheme.mode,
          builder: (_, __, ___) => SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: Text(t('settingsDarkMode')),
            value: AppTheme.isDark,
            onChanged: (_) => AppTheme.toggle(),
          ),
        ),
      ),
    ]);
  }
}

/// Tap-to-fill buttons for every discovered org/project pair. Orgs without
/// visible projects still get a button that fills the org slug alone.
class DiscoveredPicker extends StatelessWidget {
  final List<dynamic>? orgs;
  final void Function(String org, String project) onPick;
  final ValueChanged<String> onPickOrg;
  const DiscoveredPicker(
      {required this.orgs,
      required this.onPick,
      required this.onPickOrg,
      super.key});

  @override
  Widget build(BuildContext context) {
    final list = orgs;
    if (list == null || list.isEmpty) return const SizedBox.shrink();
    final chips = <Widget>[];
    for (final o in list) {
      final org = (o as Map<String, dynamic>)['org'].toString();
      final projects = (o['projects'] as List<dynamic>? ?? []);
      if (projects.isEmpty) {
        chips.add(OutlinedButton(
          onPressed: () => onPickOrg(org),
          child: Text(org),
        ));
      }
      for (final p in projects) {
        chips.add(OutlinedButton.icon(
          icon: const Icon(Icons.bolt, size: 16),
          label: Text('$org / $p'),
          onPressed: () => onPick(org, p.toString()),
        ));
      }
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('settingsDetectPick'),
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
  }
}
