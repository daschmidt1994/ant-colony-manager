// Access to the host page (web only); no-ops elsewhere.
export 'web_meta_stub.dart' if (dart.library.js_interop) 'web_meta_web.dart';
