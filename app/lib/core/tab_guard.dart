// Only one browser tab may own the local database (web); always false elsewhere.
export 'tab_guard_stub.dart' if (dart.library.js_interop) 'tab_guard_web.dart';
