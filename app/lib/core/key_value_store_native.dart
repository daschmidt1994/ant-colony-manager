import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _s = FlutterSecureStorage();

Future<String?> kvRead(String key) => _s.read(key: key);
Future<void> kvWrite(String key, String value) => _s.write(key: key, value: value);
Future<void> kvDelete(String key) => _s.delete(key: key);
