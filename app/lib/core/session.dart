import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/database.dart';
import '../data/sync/background_sync.dart';
import '../data/repositories/colony_repository.dart' show newId;
import '../data/sync/sync_engine.dart';
import '../data/sync/upload_policy.dart';
import '../features/reminders/reminders.dart';
import 'api_client.dart';
import 'key_value_store.dart';

const appVersion = '1.1.0';

/// Persistent credentials. Android: Keystore-backed secure storage.
/// Web: only server/user info – the refresh token is an HttpOnly cookie.
class SessionStore implements TokenStore {
  Future<String?> read(String k) => kvRead('acm_$k');
  Future<void> write(String k, String? v) => v == null ? kvDelete('acm_$k') : kvWrite('acm_$k', v);

  @override
  Future<String?> readRefresh() => read('refresh_token');
  @override
  Future<void> writeRefresh(String? token) => write('refresh_token', token);
}

/// One id per installation (kept in the local database; a wipe starts a new device).
/// Name shown in „Geräte & Sitzungen“; can be changed there.
String deviceNameOf(AppDatabase db) => db.getMeta(deviceNameKey) ?? (kIsWeb ? 'Web-Browser' : 'Android');

String deviceIdOf(AppDatabase db) {
  final existing = db.getMeta('device_id');
  if (existing != null) return existing;
  final id = newId();
  db.setMeta('device_id', id);
  return id;
}

class User {
  User(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get email => json['email'] as String? ?? '';
  String get displayName => json['display_name'] as String? ?? email;
  bool get isAdmin => json['instance_role'] == 'admin';
}

sealed class AuthState {
  const AuthState();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

/// Android before the first connection: ask for the server address.
class NeedsServer extends AuthState {
  const NeedsServer();
}

class SignedOut extends AuthState {
  const SignedOut(this.serverUrl, {this.setupRequired = false, this.instanceName, this.notice});
  final String serverUrl;
  final bool setupRequired;
  final String? instanceName;

  /// Why the user was signed out (shown on the login screen).
  final String? notice;
}

class SignedIn extends AuthState {
  const SignedIn(this.serverUrl, this.user, {this.offline = false});
  final String serverUrl;
  final User user;

  /// Opened without reaching the server – local data only until sync works.
  final bool offline;
}

final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('overridden in main()'));
final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

/// Normalises what people type: "192.168.1.50:8080" → "http://192.168.1.50:8080".
String normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    final isLocal = RegExp(r'^(\d+\.\d+\.\d+\.\d+|localhost)(:\d+)?(/|$)').hasMatch(s);
    s = '${isLocal ? 'http' : 'https'}://$s';
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final hash = s.indexOf('#');
  if (hash >= 0) s = s.substring(0, hash);
  return s.replaceFirst(RegExp(r'/(link|setup|login|c/.*)$'), '');
}

class AuthController extends Notifier<AuthState> {
  late final SessionStore _store = ref.read(sessionStoreProvider);
  late final AppDatabase _db = ref.read(databaseProvider);
  ApiClient? _api;

  ApiClient get api => _api!;

  @override
  AuthState build() {
    Future.microtask(_init);
    ref.onDispose(() => _api?.close());
    return const AuthLoading();
  }

  ApiClient _client(String url) {
    if (_api?.baseUrl != url) {
      _api?.close();
      _api = ApiClient(baseUrl: url, tokens: _store, isWeb: kIsWeb);
    }
    return _api!;
  }

  Future<void> _init() async {
    try {
      await _restore();
    } on Object catch (e) {
      // Never leave the app on /splash: unexpected errors (not just Exceptions,
      // e.g. a JS TypeError from browser storage) end at the login screen.
      debugPrint('session restore failed: $e');
      if (state is AuthLoading) state = kIsWeb ? await _signedOut(Uri.base.origin) : const NeedsServer();
    }
  }

  Future<void> _restore() async {
    final url = kIsWeb ? Uri.base.origin : await _store.read('server_url');
    if (url == null) {
      state = const NeedsServer();
      return;
    }
    final api = _client(url);
    final userJson = await _store.read('user');
    if (userJson == null) {
      // Web: the HttpOnly refresh cookie may still be valid (new tab, cleared storage).
      if (kIsWeb) {
        try {
          if (await api.refresh()) {
            final me = await api.get('/api/v1/me') as Map<String, dynamic>;
            final user = User(me['user'] as Map<String, dynamic>);
            await _store.write('user', jsonEncode(user.json));
            state = SignedIn(url, user);
            _cacheInstanceInfo();
            return;
          }
        } on Exception {
          // fall through to the login screen
        }
      }
      state = await _signedOut(url);
      return;
    }
    final user = User(jsonDecode(userJson) as Map<String, dynamic>);
    try {
      if (await api.refresh()) {
        state = SignedIn(url, user);
        _cacheInstanceInfo();
      } else {
        state = await _signedOut(url);
      }
    } on DeviceRevokedException {
      await deviceRevoked();
    } on NetworkException {
      state = SignedIn(url, user, offline: true); // offline-first: open with local data
    }
  }

  Future<AuthState> _signedOut(String url) async {
    try {
      final i = await _client(url).public('GET', '/api/v1/instance') as Map<String, dynamic>;
      return SignedOut(url, setupRequired: i['setup_required'] == true, instanceName: i['name'] as String?);
    } on Exception {
      return SignedOut(url);
    }
  }

  /// Checks the address and remembers it (Android).
  Future<void> connect(String input) async {
    final url = normalizeServerUrl(input);
    final i = await _client(url).public('GET', '/api/v1/instance') as Map<String, dynamic>;
    if (i['api_version'] != 1) throw ApiException(0, 'incompatible', 'Server-Version wird nicht unterstützt');
    await _store.write('server_url', url);
    state = SignedOut(url, setupRequired: i['setup_required'] == true, instanceName: i['name'] as String?);
  }

  Future<Map<String, dynamic>> _device() async => {
    'device_id': deviceIdOf(_db),
    'device_name': deviceNameOf(_db),
    'platform': kIsWeb ? 'web' : 'android',
    'app_version': appVersion,
  };

  Future<void> login(String email, String password) =>
      _signIn('/api/v1/auth/login', {'email': email.trim(), 'password': password});

  Future<void> setup(String code, String email, String password, String name) => _signIn('/api/v1/setup', {
    'setup_token': code.trim(),
    'email': email.trim(),
    'password': password,
    'display_name': name.trim(),
  });

  Future<void> register(String email, String password, String name, {String? invite}) => _signIn(
    '/api/v1/auth/register',
    {'email': email.trim(), 'password': password, 'display_name': name.trim(), 'invite_token': ?invite},
  );

  Future<void> _signIn(String path, Map<String, dynamic> body) async {
    final url = switch (state) {
      SignedOut(:final serverUrl) => serverUrl,
      SignedIn(:final serverUrl) => serverUrl,
      _ => kIsWeb ? Uri.base.origin : throw StateError('no server'),
    };
    final api = _client(url);
    final res = await api.public('POST', path, {...body, 'device': await _device()}) as Map<String, dynamic>;
    await api.adopt(res);
    final user = User(res['user'] as Map<String, dynamic>);
    // Another account on this device: never mix data.
    final prev = await _store.read('user');
    if (prev != null && (jsonDecode(prev) as Map)['id'] != user.id) {
      final device = deviceIdOf(_db);
      _db.wipe();
      _db.setMeta('device_id', device); // keep the id the session was registered with
    }
    await _store.write('user', jsonEncode(user.json));
    state = SignedIn(url, user);
    _cacheInstanceInfo();
  }

  /// Remembers the public address (for QR/NFC links – may differ from the
  /// address this device uses, e.g. a LAN IP) and the NFC UID key.
  Future<void> _cacheInstanceInfo() async {
    try {
      final inst = await api.public('GET', '/api/v1/instance') as Map<String, dynamic>;
      _db.setMeta('public_url', inst['public_url'] as String?);
      final me = await api.get('/api/v1/me') as Map<String, dynamic>;
      _db.setMeta('nfc_uid_key', me['nfc_uid_key'] as String?);
    } on Exception {
      // offline – cached values (if any) stay valid
    }
  }

  /// „Android-App verbinden“: server address + one-time code from the web app's QR.
  Future<void> linkDevice(String server, String code) async {
    await connect(server);
    await _signIn('/api/v1/auth/device-link/redeem', {'code': code});
  }

  /// Called when the server rejected the session (sync reports loginRequired).
  Future<void> sessionExpired() async {
    final s = state;
    if (s is SignedIn) state = SignedOut(s.serverUrl);
  }

  /// The device was signed out elsewhere: remove all local data (docs/08 §7).
  Future<void> deviceRevoked() async {
    final url = switch (state) {
      SignedIn(:final serverUrl) => serverUrl,
      SignedOut(:final serverUrl) => serverUrl,
      _ => null,
    };
    await _store.writeRefresh(null);
    await _store.write('user', null);
    _api?.setAccessToken(null);
    _db.wipe();
    await clearReminders().catchError((Object _) {});
    if (url != null) {
      final s = await _signedOut(url);
      state = s is SignedOut
          ? SignedOut(
              url,
              setupRequired: s.setupRequired,
              instanceName: s.instanceName,
              notice: 'Dieses Gerät wurde abgemeldet. Die lokalen Daten wurden entfernt.',
            )
          : s;
    }
  }

  Future<void> logout({bool keepData = false}) async {
    final s = state;
    await cancelBackgroundSync().catchError((Object _) {});
    await clearReminders().catchError((Object _) {});
    try {
      await _api?.post('/api/v1/auth/logout');
    } on Exception {
      // offline – the server session expires on its own
    }
    await _store.writeRefresh(null);
    await _store.write('user', null);
    _api?.setAccessToken(null);
    if (!keepData) _db.wipe();
    if (s is SignedIn) state = await _signedOut(s.serverUrl);
  }

  /// Forget the server (Android): signs out and deletes local data.
  Future<void> changeServer() async {
    await logout();
    await _store.write('server_url', null);
    state = const NeedsServer();
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Sync engine of the signed-in user (null otherwise).
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final auth = ref.watch(authProvider);
  if (auth is! SignedIn) return null;
  final db = ref.read(databaseProvider);
  final ctrl = ref.read(authProvider.notifier);
  final engine = SyncEngine(
    db: db,
    api: ctrl.api,
    userId: auth.user.id,
    uploadAllowed: uploadPolicy(db),
    device: DeviceIdentity(
      id: deviceIdOf(db),
      name: deviceNameOf(db),
      platform: kIsWeb ? 'web' : 'android',
      appVersion: appVersion,
    ),
  );
  final sub = engine.status.listen((s) {
    if (s.phase == SyncPhase.loginRequired) ctrl.sessionExpired();
    if (s.phase == SyncPhase.deviceRevoked) ctrl.deviceRevoked();
  });
  engine.start();
  ref.onDispose(() {
    sub.cancel();
    engine.dispose();
  });
  return engine;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final engine = ref.watch(syncEngineProvider);
  if (engine == null) return const Stream.empty();
  return Stream.value(engine.current).followedBy(engine.status);
});

extension<T> on Stream<T> {
  Stream<T> followedBy(Stream<T> other) async* {
    yield* this;
    yield* other;
  }
}
