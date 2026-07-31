import 'package:flutter/material.dart';

import 'i18n.dart';

/// Explains what every feature and button does, in the UI language.
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const _sections = [
    ['helpFlowTitle', 'helpFlowBody'],
    ['helpIngestTitle', 'helpIngestBody'],
    ['helpNoiseTitle', 'helpNoiseBody'],
    ['helpAnalyzeTitle', 'helpAnalyzeBody'],
    ['helpFeatureTitle', 'helpFeatureBody'],
    ['helpTicketTitle', 'helpTicketBody'],
    ['helpPrTitle', 'helpPrBody'],
    ['helpSyncTitle', 'helpSyncBody'],
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t('helpTitle'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: _sections.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(_sections[i][0]),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 6),
                  Text(t(_sections[i][1]),
                      style: const TextStyle(fontSize: 13, height: 1.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
