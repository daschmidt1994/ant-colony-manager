// Periodic background sync (Android WorkManager); no-op on the web.
export 'background_sync_stub.dart' if (dart.library.io) 'background_sync_native.dart';
