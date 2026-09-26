// Opens the platform database: native SQLite on Android/iOS/desktop,
// SQLite-WASM persisted in IndexedDB on the web.
export 'sql_open_native.dart' if (dart.library.js_interop) 'sql_open_web.dart';
