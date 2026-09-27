import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/database.dart';
import '../data/repositories/colony_repository.dart';
import '../domain/scan.dart';
import 'ndef_uri.dart';
import 'nfc_driver.dart';

final nfcDriverProvider = Provider<NfcDriver>((ref) => PluginNfcDriver());

/// Public address for links on tags and labels (PUBLIC_APP_URL of the
/// instance), falling back to the address this device uses.
String publicUrl(AppDatabase db, String serverUrl) {
  final p = db.getMeta('public_url');
  return (p == null || p.isEmpty) ? serverUrl : p.replaceAll(RegExp(r'/+$'), '');
}

String? tagUidHash(AppDatabase db, NfcTagHandle tag) {
  final key = db.getMeta('nfc_uid_key');
  if (key == null || tag.uidHex.isEmpty) return null;
  return uidHash(key, tag.uidHex);
}

/// Owns the NFC reader session. While the app is in the foreground every tag
/// is routed to the current handler: the default one opens the colony, the
/// „assign tag“ screen temporarily takes over.
class NfcController extends Notifier<NfcState> {
  late final NfcDriver _driver = ref.read(nfcDriverProvider);
  void Function(NfcTagHandle tag)? _default;
  void Function(NfcTagHandle tag)? _override;
  bool _active = false;

  @override
  NfcState build() {
    Future.microtask(refresh);
    ref.onDispose(pause);
    return NfcState.unsupported;
  }

  Future<void> refresh() async {
    try {
      state = await _driver.state();
    } on Exception {
      state = NfcState.unsupported;
    }
  }

  void setDefaultHandler(void Function(NfcTagHandle tag) h) => _default = h;

  Future<void> resume() async {
    await refresh();
    if (state != NfcState.ready || _active) return;
    _active = true;
    try {
      await _driver.start(_dispatch);
    } on Exception {
      _active = false;
    }
  }

  Future<void> pause() async {
    if (!_active) return;
    _active = false;
    try {
      await _driver.stop();
    } on Exception {
      // session already gone
    }
  }

  void takeOver(void Function(NfcTagHandle tag) handler) => _override = handler;
  void release() => _override = null;

  void _dispatch(NfcTagHandle tag) {
    HapticFeedback.mediumImpact();
    (_override ?? _default)?.call(tag);
  }
}

final nfcControllerProvider = NotifierProvider<NfcController, NfcState>(NfcController.new);

// -----------------------------------------------------------------------------
// Assigning a tag to a colony

sealed class AssignOutcome {}

class Assigned extends AssignOutcome {
  Assigned({
    required this.uri,
    required this.tagType,
    required this.bytes,
    required this.capacity,
    required this.locked,
  });
  final String uri;
  final String? tagType;
  final int bytes, capacity;
  final bool locked;
}

class AlreadyAssigned extends AssignOutcome {}

class BelongsToOther extends AssignOutcome {
  BelongsToOther(this.colonyName);
  final String colonyName;
}

/// Not writable (read-only or no NDEF) – can still be registered by serial number.
class ReadOnlyTag extends AssignOutcome {
  ReadOnlyTag({required this.canUseSerial});
  final bool canUseSerial;
}

class AssignFailed extends AssignOutcome {
  AssignFailed(this.message);
  final String message;
}

/// The decision logic of „NFC-Tag zuweisen“ (docs/06 §3), hardware-independent.
class NfcAssigner {
  NfcAssigner({required this.repo, required this.baseUrl, required this.uidKey, required this.colonyId});

  final ColonyRepository repo;
  final String baseUrl;
  final String? uidKey;
  final String colonyId;

  /// Set after the user confirmed moving a tag from another colony.
  bool allowReassign = false;
  bool lockAfterWrite = false;
  String? label;

  String? _hash(NfcTagHandle t) => uidKey == null || t.uidHex.isEmpty ? null : uidHash(uidKey!, t.uidHex);

  Future<AssignOutcome> handle(NfcTagHandle tag) async {
    final hash = _hash(tag);
    List<String> uris;
    try {
      uris = await tag.readUris();
    } on Exception {
      uris = const [];
    }
    for (final u in uris) {
      final token = parseScanInput(u);
      final link = token == null ? null : repo.linkByToken(token);
      if (link == null || !link.active) continue;
      if (link.colonyId == colonyId) {
        // Written earlier – make sure the serial number is known too.
        if (hash != null && repo.colonyByUidHash(hash) == null) {
          repo.assignNfc(colonyId, uidHashValue: hash, tagType: tag.tagType, label: label);
        }
        return AlreadyAssigned();
      }
      if (!allowReassign) return BelongsToOther(repo.colony(link.colonyId)?.name ?? 'eine andere Kolonie');
      repo.deactivateScanLink(link.id);
    }
    if (!tag.isNdef || !tag.writable) return ReadOnlyTag(canUseSerial: hash != null);

    final token = newScanToken();
    final uri = '$baseUrl/c/$token';
    if (ndefMessageSize(uri) > tag.maxSize && tag.maxSize > 0) {
      return AssignFailed('Der Tag ist zu klein (${tag.maxSize} Byte).');
    }
    try {
      await tag.writeUri(uri);
      final check = await tag.readUris();
      if (!check.contains(uri)) {
        return AssignFailed('Prüfung nach dem Schreiben fehlgeschlagen – bitte nochmal halten.');
      }
    } on NfcWriteException catch (e) {
      return AssignFailed(e.message);
    } on Exception {
      return AssignFailed('Tag zu früh entfernt – bitte nochmal ruhig an das Handy halten.');
    }
    var locked = false;
    if (lockAfterWrite && tag.canLock) {
      try {
        await tag.lock();
        locked = true;
      } on Exception {
        // written but not locked – still usable
      }
    }
    repo.assignNfc(colonyId, uidHashValue: hash, token: token, tagType: tag.tagType, locked: locked, label: label);
    return Assigned(uri: uri, tagType: tag.tagType, bytes: ndefMessageSize(uri), capacity: tag.maxSize, locked: locked);
  }

  /// Registers a tag only by its serial number (read-only tags). Works while
  /// the app is open; the system cannot open the app from such a tag.
  bool registerSerial(NfcTagHandle tag) {
    final hash = _hash(tag);
    if (hash == null) return false;
    repo.assignNfc(colonyId, uidHashValue: hash, tagType: tag.tagType, label: label);
    return true;
  }
}
