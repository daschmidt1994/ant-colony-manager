import 'dart:typed_data';

/// Intent link to open the Android app, injected by the server into index.html.
String? appIntentLink() => null;

void openExternal(String url) {}

/// Saves a generated file in the browser (web only).
void downloadFile(String name, Uint8List bytes, String mime) {}
