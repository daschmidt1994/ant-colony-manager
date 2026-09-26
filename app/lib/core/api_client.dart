import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error answer of the server (RFC 9457 problem).
class ApiException implements Exception {
  ApiException(this.status, this.code, this.title, {this.field});
  final int status;
  final String code;
  final String title;
  final String? field;

  @override
  String toString() => 'ApiException($status $code: $title)';
}

/// Server not reachable (offline, DNS, timeout, TLS).
class NetworkException implements Exception {
  NetworkException(this.cause);
  final Object cause;
  @override
  String toString() => 'NetworkException($cause)';
}

/// Session is gone (refresh failed) – the user must log in again.
class SessionExpiredException implements Exception {}

class Tokens {
  Tokens({required this.access, required this.refresh});
  final String access;
  final String? refresh; // null on the web (HttpOnly cookie)
}

/// Stores the refresh token (Android: Keystore) – implemented in session.dart.
abstract class TokenStore {
  Future<String?> readRefresh();
  Future<void> writeRefresh(String? token);
}

/// HTTP client for `/api/v1`: adds the access token, refreshes it once on
/// 401 (single flight) and turns failures into typed exceptions.
class ApiClient {
  ApiClient({required this.baseUrl, required this.tokens, required this.isWeb, http.Client? client})
      : _http = client ?? http.Client();

  final String baseUrl;
  final TokenStore tokens;
  final bool isWeb;
  final http.Client _http;
  String? _access;
  Future<bool>? _refreshing;

  static const timeout = Duration(seconds: 20);

  bool get hasAccessToken => _access != null;
  void setAccessToken(String? t) => _access = t;

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (isWeb) 'X-ACM-Client': 'web',
        if (_access != null) 'Authorization': 'Bearer $_access',
      };

  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query?.isEmpty == true ? null : query);

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body, Map<String, String>? headers]) =>
      _send('POST', path, body: body, extraHeaders: headers);
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Unauthenticated request (instance info, login, setup).
  Future<dynamic> public(String method, String path, [Object? body]) =>
      _send(method, path, body: body, auth: false);

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, String>? query, Map<String, String>? extraHeaders, bool auth = true}) async {
    Future<http.Response> once() async {
      final req = http.Request(method, uri(path, query))..headers.addAll({..._headers(), ...?extraHeaders});
      if (!auth) req.headers.remove('Authorization');
      if (body != null) req.body = jsonEncode(body);
      try {
        return await http.Response.fromStream(await _http.send(req).timeout(timeout));
      } on TimeoutException catch (e) {
        throw NetworkException(e);
      } on http.ClientException catch (e) {
        throw NetworkException(e);
      } on Exception catch (e) {
        // SocketException / HandshakeException on native (dart:io is not imported for web)
        throw NetworkException(e);
      }
    }

    var res = await once();
    if (res.statusCode == 401 && auth) {
      if (await refresh()) {
        res = await once();
      } else {
        throw SessionExpiredException();
      }
    }
    return _decode(res);
  }

  static dynamic _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    final data = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    if (data is Map) {
      throw ApiException(res.statusCode, data['code'] as String? ?? 'error', data['title'] as String? ?? 'Fehler',
          field: data['field'] as String?);
    }
    throw ApiException(res.statusCode, 'http_${res.statusCode}', 'Serverfehler (${res.statusCode})');
  }

  /// Rotates the refresh token. Returns false if the session is gone.
  /// Concurrent callers share one request.
  Future<bool> refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final stored = isWeb ? null : await tokens.readRefresh();
    if (!isWeb && stored == null) return false;
    final http.Response res;
    try {
      final req = http.Request('POST', uri('/api/v1/auth/refresh'))
        ..headers.addAll({'Content-Type': 'application/json', if (isWeb) 'X-ACM-Client': 'web'});
      if (stored != null) req.body = jsonEncode({'refresh_token': stored});
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    } on Exception catch (e) {
      throw NetworkException(e);
    }
    if (res.statusCode == 200) {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      _access = j['access_token'] as String;
      if (!isWeb) await tokens.writeRefresh(j['refresh_token'] as String?);
      return true;
    }
    if (res.statusCode >= 500) throw NetworkException('refresh: HTTP ${res.statusCode}');
    // "token_rotated": another request refreshed in parallel – the stored
    // token is newer now, try once more with it.
    if (!isWeb && res.statusCode == 401 && res.body.contains('auth.token_rotated')) {
      final again = await tokens.readRefresh();
      if (again != null && again != stored) return _doRefresh();
    }
    _access = null;
    if (!isWeb) await tokens.writeRefresh(null);
    return false;
  }

  /// Applies a login/setup/refresh answer.
  Future<void> adopt(Map<String, dynamic> session) async {
    _access = session['access_token'] as String;
    if (!isWeb) await tokens.writeRefresh(session['refresh_token'] as String?);
  }

  void close() => _http.close();
}
