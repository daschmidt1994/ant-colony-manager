import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/i18n.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../domain/models.dart';
import '../../shared/widgets.dart';

/// Public share link of a colony: a read-only page without sign-in – e.g.
/// for a keeping report in a forum – plus a ready forum text (BBCode).
/// Never on it: find location, seller, location, the owner's name or e-mail.
Future<void> showPublicShareSheet(BuildContext context, Colony colony) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (c) => _ShareSheet(colony: colony),
);

/// The path of a public link (`/p/<token>`) – also reachable via the address
/// this device uses, which may differ from the public one.
String publicPath(String url) {
  final i = url.indexOf('/p/');
  return i < 0 ? url : url.substring(i);
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.colony});
  final Colony colony;
  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  Map<String, dynamic>? _link;
  bool _loading = true, _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list =
          await ref.read(authProvider.notifier).api.get('/api/v1/colonies/${widget.colony.id}/public-links') as List;
      if (mounted) setState(() => _link = list.isEmpty ? null : (list.first as Map).cast<String, dynamic>());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() => _run(() async {
    final r = await ref.read(authProvider.notifier).api.post('/api/v1/colonies/${widget.colony.id}/public-links', {
      'photos': true,
      'timeline': true,
      'notes': false,
    });
    setState(() => _link = (r as Map).cast<String, dynamic>());
  });

  Future<void> _option(String key, bool value) => _run(() async {
    final opts = {...(_link!['options'] as Map).cast<String, dynamic>(), key: value};
    await ref.read(authProvider.notifier).api.patch('/api/v1/public-links/${_link!['id']}', opts);
    setState(() => _link = {..._link!, 'options': opts});
  });

  Future<void> _revoke() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Link widerrufen?')),
        content: Text(tr('Die Seite ist danach sofort nicht mehr erreichbar – auch in Forenbeiträgen.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Abbrechen'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(tr('Widerrufen'))),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await ref.read(authProvider.notifier).api.delete('/api/v1/public-links/${_link!['id']}');
      setState(() => _link = null);
    });
  }

  void _copy(String text, String done) {
    Clipboard.setData(ClipboardData(text: text));
    showUndoSnack(context, done);
  }

  Future<void> _copyForum() => _run(() async {
    final api = ref.read(authProvider.notifier).api;
    final res = await http.get(Uri.parse('${api.baseUrl}${publicPath(_link!['url'] as String)}/forum.txt'));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    if (mounted) _copy(res.body, tr('Forenbeitrag kopiert – einfach im Forum einfügen'));
  });

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted, fontSize: 13);
    final link = _link;
    final opts = (link?['options'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Öffentlich teilen'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            tr(
              'Eine Seite zum Ansehen ohne Anmeldung – etwa für einen Haltungsbericht im Forum. Nie darauf: '
              'Fundort, Verkäufer, Standort, dein Name oder deine E-Mail.',
            ),
            style: muted,
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Text(errorText(_error!))
          else if (link == null)
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.public),
              label: Text(tr('Öffentlichen Link erstellen')),
            )
          else ...[
            SelectableText(link['url'] as String, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _copy(link['url'] as String, tr('Link kopiert')),
                  icon: const Icon(Icons.link),
                  label: Text(tr('Link kopieren')),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _copyForum,
                  icon: const Icon(Icons.forum_outlined),
                  label: Text(tr('Forenbeitrag kopieren')),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(tr('Forenbeitrag: BBCode mit Fakten, Fotos und Link – für die meisten Ameisenforen.'), style: muted),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Fotos zeigen')),
              value: opts['photos'] == true,
              onChanged: _busy ? null : (v) => _option('photos', v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Chronik zeigen')),
              subtitle: Text(tr('Fütterungen, Koloniegröße, Messwerte …')),
              value: opts['timeline'] == true,
              onChanged: _busy ? null : (v) => _option('timeline', v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Notizen zeigen')),
              subtitle: Text(tr('Texte von Notizen, Kontrollen und Fotos')),
              value: opts['notes'] == true,
              onChanged: _busy ? null : (v) => _option('notes', v),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: context.colors.overdue),
              onPressed: _busy ? null : _revoke,
              icon: const Icon(Icons.link_off),
              label: Text(tr('Link widerrufen')),
            ),
          ],
        ],
      ),
    );
  }
}
