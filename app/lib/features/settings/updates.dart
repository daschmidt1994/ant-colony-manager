import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../core/session.dart';

/// Newer releases, checked by the server (GitHub, cached there).
final updatesProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  try {
    return await ref.read(authProvider.notifier).api.get('/api/v1/updates') as Map<String, dynamic>;
  } on Exception {
    return null; // offline or old server
  }
});

const _dismissedKey = 'update_warning_dismissed';

/// Newest release with breaking changes that is ahead – what the warning shows.
Map<String, dynamic>? breakingRelease(Map<String, dynamic>? info) {
  if (info?['breaking'] != true) return null;
  for (final r in (info!['newer'] as List? ?? const [])) {
    if (r is Map<String, dynamic> && r['breaking'] == true) return r;
  }
  return null;
}

/// Red card on the dashboard before a breaking update – until dismissed for
/// that version.
class UpdateWarning extends ConsumerStatefulWidget {
  const UpdateWarning({super.key});
  @override
  ConsumerState<UpdateWarning> createState() => _UpdateWarningState();
}

class _UpdateWarningState extends ConsumerState<UpdateWarning> {
  @override
  Widget build(BuildContext context) {
    final r = breakingRelease(ref.watch(updatesProvider).value);
    if (r == null) return const SizedBox.shrink();
    final db = ref.read(databaseProvider);
    final version = r['version'] as String;
    if (db.getMeta(_dismissedKey) == version) return const SizedBox.shrink();
    final text = (r['breaking_text'] as String?)?.trim();
    final red = context.colors.overdue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: red.withValues(alpha: .12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Update $version: Breaking Change',
                      style: TextStyle(color: red, fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (text != null && text.isNotEmpty) ...[Text(text), const SizedBox(height: 8)],
              const Text(
                'Vor dem Update: 1. Backup machen · 2. Server aktualisieren · 3. dann erst die App. '
                'App und Server müssen danach dieselbe Version haben.',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (r['url'] is String && (r['url'] as String).startsWith('https://'))
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse(r['url'] as String), mode: LaunchMode.externalApplication),
                      child: const Text('Details'),
                    ),
                  TextButton(
                    onPressed: () => setState(() => db.setMeta(_dismissedKey, version)),
                    child: const Text('Ausblenden'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line for Mehr → Server: „Update 1.3.0 verfügbar“ (red if breaking).
String? updateLine(Map<String, dynamic>? info) {
  if (info == null || info['update_available'] != true) return null;
  final latest = info['latest'];
  return info['breaking'] == true
      ? 'Update $latest verfügbar – ⚠ Breaking Change, vorher Backup'
      : 'Update $latest verfügbar';
}
