import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../../app/i18n.dart';
import '../../app/strings.dart';
import '../../data/repositories/colony_repository.dart';
import '../../domain/widget_summary.dart';

/// Android home screen widget „Ameisen – fällig“ (DueWidgetProvider.kt).
/// Refreshed together with the reminders: after every sync, when the app
/// comes back and hourly in the background.
const _provider = 'at.antcolony.manager.DueWidgetProvider';

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> updateHomeWidget(ColonyRepository repo) async {
  if (!_android) return;
  final cols = repo.colonies();
  final s = widgetSummary(colonies: cols, due: repo.dueAll(cols), readOnlyColonies: repo.readOnlyColonies());
  await _save(
    headline: s.headline,
    urgent: s.overdue > 0,
    lines: s.lines.isEmpty ? tr('Nichts fällig – gut gemacht.') : s.lines.join('\n'),
    footer: tr('Stand {0} · Tippen für den Rundgang', [S.time(DateTime.now())]),
  );
}

/// Logout: the widget must not keep showing the previous account.
Future<void> clearHomeWidget() async {
  if (!_android) return;
  await _save(headline: tr('Nicht angemeldet'), urgent: false, lines: '', footer: '');
}

Future<void> _save({
  required String headline,
  required bool urgent,
  required String lines,
  required String footer,
}) async {
  await HomeWidget.saveWidgetData<String>('title', tr('Ameisen'));
  await HomeWidget.saveWidgetData<String>('headline', headline);
  await HomeWidget.saveWidgetData<bool>('urgent', urgent);
  await HomeWidget.saveWidgetData<String>('lines', lines);
  await HomeWidget.saveWidgetData<String>('footer', footer);
  await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
}
