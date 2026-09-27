import 'package:flutter/foundation.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

import 'ndef_uri.dart';

enum NfcState { unsupported, disabled, ready }

/// A tag held to the phone. Abstract so the assign/scan logic can be tested
/// without hardware.
abstract class NfcTagHandle {
  String get uidHex;
  String? get tagType;
  bool get isNdef;
  bool get writable;
  int get maxSize;
  bool get canLock;

  /// URIs stored on the tag (usually one).
  Future<List<String>> readUris();
  Future<void> writeUri(String uri);
  Future<void> lock();
}

abstract class NfcDriver {
  Future<NfcState> state();
  Future<void> start(void Function(NfcTagHandle tag) onTag);
  Future<void> stop();
}

/// Android implementation (reader mode while the app is in the foreground).
class PluginNfcDriver implements NfcDriver {
  bool _running = false;

  @override
  Future<NfcState> state() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return NfcState.unsupported;
    return switch (await NfcManager.instance.checkAvailability()) {
      NfcAvailability.enabled => NfcState.ready,
      NfcAvailability.disabled => NfcState.disabled,
      NfcAvailability.unsupported => NfcState.unsupported,
    };
  }

  @override
  Future<void> start(void Function(NfcTagHandle tag) onTag) async {
    if (_running) await stop();
    _running = true;
    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      onDiscovered: (tag) async => onTag(_PluginTag(tag)),
    );
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await NfcManager.instance.stopSession();
  }
}

class _PluginTag implements NfcTagHandle {
  _PluginTag(NfcTag tag) : _ndef = Ndef.from(tag), _android = NfcTagAndroid.from(tag);

  final Ndef? _ndef;
  final NfcTagAndroid? _android;

  @override
  String get uidHex => formatUid(_android?.id ?? const []);

  @override
  String? get tagType => _ndef?.additionalData['type'] as String?;
  @override
  bool get isNdef => _ndef != null;
  @override
  bool get writable => _ndef?.isWritable ?? false;
  @override
  int get maxSize => _ndef?.maxSize ?? 0;
  @override
  bool get canLock => _ndef?.additionalData['canMakeReadOnly'] == true;

  @override
  Future<List<String>> readUris() async {
    final msg = await _ndef?.read() ?? _ndef?.cachedMessage;
    if (msg == null) return const [];
    return [
      for (final r in msg.records)
        if (r.typeNameFormat == TypeNameFormat.wellKnown && r.type.length == 1 && r.type[0] == uriRecordType[0])
          ?decodeUriPayload(r.payload),
    ];
  }

  @override
  Future<void> writeUri(String uri) async {
    final ndef = _ndef;
    if (ndef == null) throw const NfcWriteException('Dieser Tag unterstützt kein NDEF.');
    if (!ndef.isWritable) throw const NfcWriteException('Der Tag ist schreibgeschützt.');
    if (ndefMessageSize(uri) > ndef.maxSize) throw const NfcWriteException('Der Tag ist zu klein.');
    await ndef.write(
      message: NdefMessage(
        records: [
          NdefRecord(
            typeNameFormat: TypeNameFormat.wellKnown,
            type: uriRecordType,
            identifier: Uint8List(0),
            payload: encodeUriPayload(uri),
          ),
        ],
      ),
    );
  }

  @override
  Future<void> lock() async => _ndef?.writeLock();
}

class NfcWriteException implements Exception {
  const NfcWriteException(this.message);
  final String message;
  @override
  String toString() => message;
}
