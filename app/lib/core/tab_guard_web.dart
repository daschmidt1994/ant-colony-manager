import 'dart:js_interop';
import '../app/i18n.dart';

import 'package:web/web.dart' as web;

// Kept alive for the lifetime of the tab so it can answer later tabs.
web.BroadcastChannel? channel;
bool _owner = false;

/// Asks other tabs of this app whether they are open. The local database lives
/// in IndexedDB; two tabs writing it at the same time would overwrite each
/// other's changes, so only the first tab may use it. BroadcastChannel is used
/// because the Web Locks API is missing on plain http:// (home network).
Future<bool> otherTabActive() async {
  final ch = web.BroadcastChannel('ant-colony-manager-tab');
  channel = ch;
  var seen = false;
  ch.onmessage = ((web.MessageEvent e) {
    final msg = (e.data as JSString?)?.toDart;
    if (msg == 'present') seen = true;
    if (msg == 'hello' && _owner) ch.postMessage('present'.toJS);
  }).toJS;
  ch.postMessage('hello'.toJS);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  _owner = !seen;
  if (seen) web.document.title = tr('Bereits geöffnet – Ant Colony Manager');
  return seen;
}

void reloadPage() => web.window.location.reload();
