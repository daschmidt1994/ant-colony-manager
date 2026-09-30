import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';
import '../ai/ai_count.dart';

/// Counting ants with AI – administrators enter the Anthropic API key here.
final aiSettingsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/ai') as Map<String, dynamic>;
});

/// Request body; the key only when typed or removed.
Map<String, dynamic> aiBody({
  required bool enabled,
  required String model,
  String apiKey = '',
  bool removeKey = false,
}) => {
  'enabled': enabled,
  'model': model.trim(),
  if (removeKey) 'api_key': '' else if (apiKey.trim().isNotEmpty) 'api_key': apiKey.trim(),
};

class AiScreen extends ConsumerWidget {
  const AiScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(aiSettingsProvider)
      .when(
        loading: () => Scaffold(
          appBar: AppBar(title: Text(tr('KI-Zählung'))),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Scaffold(
          appBar: AppBar(title: Text(tr('KI-Zählung'))),
          body: EmptyState(
            icon: Icons.cloud_off,
            title: tr('Nur mit Verbindung zum Server'),
            text: errorText(e),
            action: FilledButton(onPressed: () => ref.invalidate(aiSettingsProvider), child: Text(tr('Erneut'))),
          ),
        ),
        data: (s) => _AiForm(initial: s),
      );
}

class _AiForm extends ConsumerStatefulWidget {
  const _AiForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  ConsumerState<_AiForm> createState() => _AiFormState();
}

class _AiFormState extends ConsumerState<_AiForm> {
  late Map<String, dynamic> _s = widget.initial;
  late bool _enabled = _s['enabled'] == true;
  late final _model = TextEditingController(text: _s['model'] as String? ?? 'claude-opus-5-5');
  final _key = TextEditingController();
  bool _removeKey = false;
  bool _busy = false;

  @override
  void dispose() {
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(authProvider.notifier)
          .api
          .put(
            '/api/v1/admin/ai',
            aiBody(enabled: _enabled, model: _model.text, apiKey: _key.text, removeKey: _removeKey),
          );
      setState(() {
        _s = r as Map<String, dynamic>;
        _key.clear();
        _removeKey = false;
      });
      ref.invalidate(aiAvailableProvider);
      if (mounted) showUndoSnack(context, tr('Gespeichert'));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: context.colors.muted);
    final keySet = _s['api_key_set'] == true && !_removeKey;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('KI-Zählung')),
        actions: [TextButton(onPressed: _busy ? null : _save, child: Text(tr('Speichern')))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ContentWidth(
            maxWidth: 640,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(
                    'Bei „Größe & Brut“ gibt es dann „Mit KI zählen“: Fotos wählen, die KI zählt die Ameisen auf jedem '
                    'Foto, die Zahlen werden addiert. Dafür werden die gewählten Fotos an Anthropic (Claude) geschickt. '
                    'Die Kosten gehen auf dein Anthropic-Konto – einige Cent pro Zählung.',
                  ),
                  style: muted,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Zählen mit KI anbieten')),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                TextField(
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Anthropic-API-Schlüssel'),
                    hintText: keySet ? tr('gespeichert – leer lassen zum Behalten') : 'sk-ant-…',
                    helperText: tr('console.anthropic.com → API Keys'),
                    suffixIcon: keySet
                        ? IconButton(
                            tooltip: tr('Schlüssel entfernen'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => setState(() => _removeKey = true),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _model,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Modell'),
                    helperText: tr('Standard: claude-opus-5-5 (am genauesten). Günstiger: claude-sonnet-5-5.'),
                    helperMaxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
