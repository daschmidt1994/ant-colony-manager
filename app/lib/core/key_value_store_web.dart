import 'package:web/web.dart' as web;

// Plain localStorage: flutter_secure_storage needs crypto.subtle, which browsers
// only offer on HTTPS or localhost – on http://<LAN-IP> every write threw and
// the app hung on /splash. Its key also lived in localStorage, so the encryption
// added no protection; the refresh token is an HttpOnly cookie anyway.

Future<String?> kvRead(String key) async => web.window.localStorage.getItem(key);
Future<void> kvWrite(String key, String value) async => web.window.localStorage.setItem(key, value);
Future<void> kvDelete(String key) async => web.window.localStorage.removeItem(key);
