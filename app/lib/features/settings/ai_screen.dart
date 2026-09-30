import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/i18n.dart';
import '../../app/theme.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';
import '../ai/ai_count.dart';

/// Counting ants with AI – administrators choose the provider (Claude,
/// ChatGPT, OpenRouter) and enter its API key here.
final aiSettingsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.read(authProvider.notifier).api.get('/api/v1/admin/ai') as Map<String, dynamic>;
});

/// Request body; the key only when typed or removed.
Map<String, dynamic> aiBody({
  required bool enabled,
  String provider = 'anthropic',
  required String model,
  String apiKey = '',
  bool removeKey = false,
}) => {
  'enabled': enabled,
  'provider': provider,
  'model': model.trim(),
  if (removeKey) 'api_key': '' else if (apiKey.trim().isNotEmpty) 'api_key': apiKey.trim(),
};

/// Where to get the key, and which model to enter – per provider.
({String key, String keyHint, String modelHelp}) aiProviderHelp(String provider) => switch (provider) {
  'openai' => (
    key: 'platform.openai.com → API keys',
    keyHint: 'sk-…',
    modelHelp: tr('Ein Modell, das Bilder versteht – Liste: platform.openai.com/docs/models'),
  ),
  'openrouter' => (
    key: 'openrouter.ai → Keys',
    keyHint: 'sk-or-…',
    modelHelp: tr(
      'Modell-ID aus openrouter.ai/models mit Eingabe „image“, z. B. anthropic/… oder openai/… – '
      'OpenRouter leitet an viele Anbieter weiter.',
    ),
  ),
  _ => (
    key: 'console.anthropic.com → API Keys',
    keyHint: 'sk-ant-…',
    modelHelp: tr('Standard: claude-opus-5-5 (am genauesten). Günstiger: claude-sonnet-5-5.'),
  ),
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
  late String _provider = _s['provider'] as String? ?? 'anthropic';
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
            aiBody(
              enabled: _enabled,
              provider: _provider,
              model: _model.text,
              apiKey: _key.text,
              removeKey: _removeKey,
            ),
          );
      setState(() {
        _s = r as Map<String, dynamic>;
        _key.clear();
        _removeKey = false;
      });
      ref.invalidate(aiInfoProvider);
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
    // a key belongs to its provider: after switching, a new one is needed
    final keySet = _s['api_key_set'] == true && !_removeKey && _s['provider'] == _provider;
    final help = aiProviderHelp(_provider);
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
                    'Foto, die Zahlen werden addiert. Dafür werden die gewählten Fotos an den gewählten Anbieter '
                    'geschickt. Die Kosten gehen auf dein Konto dort – meist einige Cent pro Zählung.',
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
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'anthropic', label: Text('Claude')),
                    ButtonSegment(value: 'openai', label: Text('ChatGPT')),
                    ButtonSegment(value: 'openrouter', label: Text('OpenRouter')),
                  ],
                  selected: {_provider},
                  onSelectionChanged: (v) => setState(() {
                    _provider = v.first;
                    _model.text = _provider == _s['provider']
                        ? _s['model'] as String? ?? ''
                        : (_provider == 'anthropic' ? 'claude-opus-5-5' : '');
                  }),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('API-Schlüssel ({0})', [aiProviders[_provider] ?? _provider]),
                    hintText: keySet ? tr('gespeichert – leer lassen zum Behalten') : help.keyHint,
                    helperText: help.key,
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
                  decoration: InputDecoration(labelText: tr('Modell'), helperText: help.modelHelp, helperMaxLines: 3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
