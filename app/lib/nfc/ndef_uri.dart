import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// URI identifier codes of the NFC Forum URI record type (RTD-URI).
const _prefixes = <String>[
  '',
  'http://www.',
  'https://www.',
  'http://',
  'https://',
  'tel:',
  'mailto:',
  'ftp://anonymous:anonymous@',
  'ftp://ftp.',
  'ftps://',
  'sftp://',
  'smb://',
  'nfs://',
  'ftp://',
  'dav://',
  'news:',
  'telnet://',
  'imap:',
  'rtsp://',
  'urn:',
  'pop:',
  'sip:',
  'sips:',
  'tftp:',
  'btspp://',
  'btl2cap://',
  'btgoep://',
  'tcpobex://',
  'irdaobex://',
  'file://',
  'urn:epc:id:',
  'urn:epc:tag:',
  'urn:epc:pat:',
  'urn:epc:raw:',
  'urn:epc:',
  'urn:nfc:',
];

/// Record type of a well-known URI record ("U").
final uriRecordType = Uint8List.fromList([0x55]);

/// Payload of a URI record: one prefix byte + the rest of the URI (UTF-8).
/// "https://" is abbreviated to one byte – keeps the tag small (NTAG213: 137 bytes).
Uint8List encodeUriPayload(String uri) {
  var code = 0;
  for (var i = _prefixes.length - 1; i > 0; i--) {
    if (uri.startsWith(_prefixes[i]) && _prefixes[i].length > _prefixes[code].length) code = i;
  }
  return Uint8List.fromList([code, ...utf8.encode(uri.substring(_prefixes[code].length))]);
}

String? decodeUriPayload(Uint8List payload) {
  if (payload.isEmpty) return null;
  final code = payload[0];
  final prefix = code < _prefixes.length ? _prefixes[code] : '';
  try {
    return prefix + utf8.decode(payload.sublist(1));
  } on FormatException {
    return null;
  }
}

/// Size of a single short NDEF record containing [uri] (header 4 bytes).
int ndefMessageSize(String uri) => 4 + encodeUriPayload(uri).length;

/// Hardware UID as upper-case hex without separators, e.g. "04A2B3C4D5E680".
String formatUid(List<int> id) => id.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// Hash under which a tag UID is stored: hex(HMAC-SHA256(key, UID-hex)).
/// The key comes from the server (`nfc_uid_key` in /api/v1/me), so every device
/// of an instance computes the same value and raw UIDs are never stored.
String uidHash(String base64Key, String uid) =>
    Hmac(sha256, base64.decode(base64Key)).convert(utf8.encode(uid)).toString();
