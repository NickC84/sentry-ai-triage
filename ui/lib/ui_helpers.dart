// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';

import 'i18n.dart';

/// Flutter Web only: open a link in a new tab (Sentry / GitHub).
void openUrl(String url) => html.window.open(url, '_blank');

// ── Display helpers for category / state / severity ───────────────

const kCategories = [
  'app_bug',
  'device_layer',
  'network_noise',
  'log_event',
  'feature',
  'unknown',
];
const kStates = ['new', 'keep', 'hidden', 'known_noise', 'resolved'];

/// Localized label with graceful fallback for values outside the known set.
String _lookup(String prefix, String value) {
  final s = t('$prefix$value');
  return s == '$prefix$value' ? value : s;
}

String categoryLabel(String c) => _lookup('cat_', c);
String stateLabel(String s) => _lookup('st_', s);
String fixLabel(String? f) => f == null ? '—' : _lookup('fix_', f);
String feasLabel(String f) => _lookup('feas_', f);

Color categoryColor(String c) => switch (c) {
      'device_layer' => Colors.brown,
      'network_noise' => Colors.blueGrey,
      'log_event' => Colors.teal,
      'app_bug' => Colors.red,
      'feature' => Colors.indigo,
      _ => Colors.grey,
    };

Color feasColor(String? f) => switch (f) {
      'feasible' => Colors.green,
      'hard' => Colors.orange,
      'blocked' => Colors.red,
      _ => Colors.grey,
    };

Color sevColor(int s) =>
    s >= 70 ? Colors.red : (s >= 40 ? Colors.orange : Colors.green);

// ── Small shared widgets ──────────────────────────────────────────

Widget badge(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );

/// Small severity badge used in the list and detail panel.
Widget sevBadge(int score, String? fixable) {
  final c = sevColor(score);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: c.withOpacity(0.14),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text('${tp('sevPrefix', {'s': score})} · ${fixLabel(fixable)}',
        style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
  );
}

/// Feasibility badge for feature items.
Widget feasBadge(String feasibility, String? effort) {
  final c = feasColor(feasibility);
  final e = effort == null ? '' : tp('effortPrefix', {'e': effort});
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: c.withOpacity(0.14),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text('${feasLabel(feasibility)}$e',
        style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
  );
}

// ── Tiny formatters ───────────────────────────────────────────────

String fmt(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

String fmtDate(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  final l = d.toLocal();
  return '${l.year}/${l.month.toString().padLeft(2, '0')}/${l.day.toString().padLeft(2, '0')}';
}
