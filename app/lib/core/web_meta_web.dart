import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Intent link to open the Android app, injected by the server into
/// index.html for /c/<code> requests from Android browsers.
String? appIntentLink() {
  final v = web.document.querySelector('meta[name="acm-app-intent"]')?.getAttribute('content');
  return v != null && v.startsWith('intent://') ? v : null;
}

void openExternal(String url) => web.window.location.href = url;

/// Saves a generated file (e.g. the label PDF) via a temporary blob link.
void downloadFile(String name, Uint8List bytes, String mime) {
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.append(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}
