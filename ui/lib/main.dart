import 'package:flutter/material.dart';

import 'i18n.dart';
import 'triage_page.dart';

void main() => runApp(const TriageApp());

/// App shell: wires the locale + theme preferences into MaterialApp.
///
/// The UI lives in one file per screen:
/// - triage_page.dart   — main screen (list, toolbar, tabs)
/// - issue_detail.dart  — right-hand detail panel
/// - settings_page.dart — in-app configuration
/// - help_page.dart     — user guide
/// with shared pieces in ui_helpers.dart / issue_tile.dart /
/// detail_widgets.dart, and all display strings in i18n.dart.
class TriageApp extends StatelessWidget {
  const TriageApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole tree when the locale or theme toggles. TriagePage
    // must NOT be const here — a const child is skipped on rebuild, which
    // would freeze the language.
    return AnimatedBuilder(
      animation: Listenable.merge([I18n.locale, AppTheme.mode]),
      builder: (_, __) => MaterialApp(
        title: t('appTitle'),
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          visualDensity: VisualDensity.compact,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          visualDensity: VisualDensity.compact,
        ),
        themeMode: AppTheme.isDark ? ThemeMode.dark : ThemeMode.light,
        // ignore: prefer_const_constructors
        home: TriagePage(),
      ),
    );
  }
}
