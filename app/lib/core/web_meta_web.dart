import 'package:web/web.dart' as web;

/// Intent link to open the Android app, injected by the server into
/// index.html for /c/<code> requests from Android browsers.
String? appIntentLink() {
  final v = web.document.querySelector('meta[name="acm-app-intent"]')?.getAttribute('content');
  return v != null && v.startsWith('intent://') ? v : null;
}

void openExternal(String url) => web.window.location.href = url;
