// Where SessionStore keeps its values: Keystore on Android, localStorage on web.
export 'key_value_store_native.dart' if (dart.library.js_interop) 'key_value_store_web.dart';
