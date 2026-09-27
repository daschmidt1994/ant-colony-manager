import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/api_client.dart';

/// Listens to `GET /api/v1/sync/events` (Server-Sent Events) and calls
/// [onChange] when the server reports new data – the engine then pulls.
/// Used while the Android app is in the foreground; reconnects with backoff.
class RealtimeListener {
  // ignore: prefer_initializing_formals
  RealtimeListener({required this.api, required this.onChange, http.Client? client}) : _client = client;

  final ApiClient api;
  final void Function() onChange;
  final http.Client? _client;
  http.Client? _active;
  bool _running = false;
  Duration _backoff = const Duration(seconds: 2);

  void start() {
    if (_running) return;
    _running = true;
    _loop();
  }

  void stop() {
    _running = false;
    _active?.close();
    _active = null;
  }

  Future<void> _loop() async {
    while (_running) {
      try {
        await _listenOnce();
        _backoff = const Duration(seconds: 2);
      } on SessionExpiredException {
        _running = false; // the sync engine reports this to the user
        return;
      } catch (_) {
        // network drop – retry below
      }
      if (!_running) return;
      await Future<void>.delayed(_backoff);
      _backoff = Duration(seconds: (_backoff.inSeconds * 2).clamp(2, 120));
    }
  }

  Future<void> _listenOnce() async {
    if (!api.hasAccessToken && !await api.refresh()) throw SessionExpiredException();
    final client = _client ?? http.Client();
    _active = client;
    final req = http.Request('GET', api.uri('/api/v1/sync/events'))
      ..headers['Authorization'] = 'Bearer ${api.accessToken}'
      ..headers['Accept'] = 'text/event-stream';
    final res = await client.send(req);
    if (res.statusCode == 401) {
      if (!await api.refresh()) throw SessionExpiredException();
      return; // reconnect with the new token
    }
    if (res.statusCode != 200) throw Exception('sse ${res.statusCode}');
    onChange(); // catch up on anything missed while disconnected
    await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!_running) break;
      if (line.startsWith('data:')) onChange();
    }
  }
}
