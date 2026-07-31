import 'package:flutter/material.dart';

import 'i18n.dart';

/// Confirm deleting a feature item. Returns true when confirmed.
Future<bool> confirmDelete(BuildContext context, String title) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('deleteFeatureTitle')),
      content: Text(tp('deleteFeatureBody', {'t': title})),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('cancel'))),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('delete'))),
      ],
    ),
  );
  return ok == true;
}

/// What the user typed into the "new feature" dialog.
class FeatureDraft {
  final String title;
  final String detail;
  FeatureDraft(this.title, this.detail);
}

/// Prompt for a new feature item. Returns null when cancelled or empty.
Future<FeatureDraft?> promptNewFeature(BuildContext context) async {
  final titleCtl = TextEditingController();
  final detailCtl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('newFeatureTitle')),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: titleCtl,
            autofocus: true,
            decoration: InputDecoration(
                labelText: t('featureTitleLabel'),
                hintText: t('featureTitleHint')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: detailCtl,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: t('featureDetailLabel'),
              hintText: t('featureDetailHint'),
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('cancel'))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(t('add'))),
      ],
    ),
  );
  if (ok != true) return null;
  final title = titleCtl.text.trim();
  if (title.isEmpty) return null;
  return FeatureDraft(title, detailCtl.text.trim());
}
