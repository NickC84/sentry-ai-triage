import 'package:flutter/material.dart';

import 'api.dart';
import 'i18n.dart';

/// "Is this machine actually set up?" — the Settings panel that answers it.
///
/// Installed-but-not-logged-in used to surface only as a failed analysis
/// twenty seconds in; here it is a red row with the exact command to run.
///
/// The backend returns codes plus raw values (versions, paths) and never
/// prose, so all wording stays in [i18n].
class EnvCheckCard extends StatefulWidget {
  final TriageApi api;
  const EnvCheckCard({required this.api, super.key});

  @override
  State<EnvCheckCard> createState() => _EnvCheckCardState();
}

class _EnvCheckCardState extends State<EnvCheckCard> {
  List<dynamic>? _checks;
  String _version = '';
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.toolsHealth();
      if (!mounted) return;
      setState(() {
        _checks = (res['checks'] as List<dynamic>?) ?? const [];
        _version = (res['version'] ?? '').toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = tp('envFail', {'e': e});
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(t('envTitle'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const Spacer(),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  IconButton(
                    tooltip: t('envRecheck'),
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _load,
                  ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error!,
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              ),
            if (_checks != null)
              for (final c in _checks!)
                _CheckRow(check: c as Map<String, dynamic>),
            if (_version.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(tp('envVersion', {'v': _version}),
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final Map<String, dynamic> check;
  const _CheckRow({required this.check});

  @override
  Widget build(BuildContext context) {
    final status = (check['status'] ?? 'warn').toString();
    final values = (check['values'] as Map<String, dynamic>? ?? {});
    final message =
        tp('envMsg_${check['code']}', values.map((k, v) => MapEntry(k, v)));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(_icon(status), size: 16, color: _color(status)),
          ),
          SizedBox(
            width: 108,
            child: Text(t('env_${check['id']}'),
                style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: SelectableText(message,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  static IconData _icon(String status) => switch (status) {
        'ok' => Icons.check_circle,
        'error' => Icons.error,
        _ => Icons.warning_amber_rounded,
      };

  static Color _color(String status) => switch (status) {
        'ok' => Colors.green,
        'error' => Colors.red,
        _ => Colors.orange,
      };
}
