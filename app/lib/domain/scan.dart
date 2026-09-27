final _tokenRe = RegExp(r'^[0-9A-Za-z]{16}$');

bool isScanToken(String s) => _tokenRe.hasMatch(s);

/// Extracts the scan token from a link (…/c/`token`) or a bare 16-character code.
String? parseScanInput(String input) {
  final s = input.trim();
  if (isScanToken(s)) return s;
  final m = RegExp(r'/c/([0-9A-Za-z]{16})(?:[/?#]|$)').firstMatch(s);
  return m?.group(1);
}

/// „Android-App verbinden“ QR payload: `https://host/link#code=XYZ`.
({String server, String code})? parseDeviceLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !uri.hasScheme || !uri.path.endsWith('/link')) return null;
  final code = Uri.splitQueryString(uri.fragment)['code'];
  if (code == null || code.isEmpty) return null;
  final base = uri.replace(path: uri.path.substring(0, uri.path.length - '/link'.length), fragment: '', query: '');
  var server = base.toString();
  while (server.endsWith('/') || server.endsWith('#') || server.endsWith('?')) {
    server = server.substring(0, server.length - 1);
  }
  return (server: server, code: code);
}
