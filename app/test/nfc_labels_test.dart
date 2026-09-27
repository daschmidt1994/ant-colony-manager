import 'dart:io';

import 'package:ant_colony_manager/data/local/database.dart';
import 'package:ant_colony_manager/data/repositories/colony_repository.dart';
import 'package:ant_colony_manager/domain/scan.dart';
import 'package:ant_colony_manager/features/labels/labels.dart';
import 'package:ant_colony_manager/nfc/ndef_uri.dart';
import 'package:ant_colony_manager/nfc/nfc_controller.dart';
import 'package:ant_colony_manager/nfc/nfc_driver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'helpers.dart';

/// Simulated tag: an NTAG213 with 137 usable bytes.
class FakeTag implements NfcTagHandle {
  FakeTag(this.uidHex, {this.uris = const [], this.writable = true, this.isNdef = true, this.failWrite = false});
  @override
  final String uidHex;
  List<String> uris;
  @override
  bool writable;
  @override
  bool isNdef;
  bool failWrite;
  bool locked = false;
  bool corruptOnWrite = false;

  @override
  String? get tagType => 'NTAG213';
  @override
  int get maxSize => 137;
  @override
  bool get canLock => true;
  @override
  Future<List<String>> readUris() async => uris;
  @override
  Future<void> writeUri(String uri) async {
    if (failWrite) throw Exception('Tag was lost');
    uris = [corruptOnWrite ? '${uri}x' : uri];
  }

  @override
  Future<void> lock() async => locked = true;
}

void main() {
  group('NDEF URI records', () {
    test('https:// is abbreviated to one byte and round-trips', () {
      final p = encodeUriPayload('https://ants.example.com/c/7Kq2mZr9XbT4pLwA');
      expect(p.first, 0x04);
      expect(decodeUriPayload(p), 'https://ants.example.com/c/7Kq2mZr9XbT4pLwA');
      expect(encodeUriPayload('http://www.x.at/').first, 0x01);
      expect(encodeUriPayload('http://192.168.1.50:8080/c/x').first, 0x03);
      expect(decodeUriPayload(encodeUriPayload('custom:thing')), 'custom:thing');
    });

    test('a typical colony link fits even on the smallest tag', () {
      expect(ndefMessageSize('https://ants.example.com/c/7Kq2mZr9XbT4pLwA'), lessThan(64));
    });

    test('uid hash is stable, lower-case hex and key-dependent', () {
      final a = uidHash('c2VjcmV0LWtleQ==', formatUid([0x04, 0xa2, 0xb3]));
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(uidHash('c2VjcmV0LWtleQ==', '04A2B3'), a);
      expect(uidHash('b3RoZXIta2V5', '04A2B3'), isNot(a));
    });
  });

  group('assigning tags', () {
    late AppDatabase db;
    late ColonyRepository repo;
    late String a, b;
    const key = 'c2VjcmV0LWtleQ==';
    NfcAssigner assigner(String colony) =>
        NfcAssigner(repo: repo, baseUrl: 'https://ants.test', uidKey: key, colonyId: colony);

    setUp(() {
      db = memoryDb();
      repo = ColonyRepository(db, userId: 'u1', onChanged: () {});
      a = repo.createColony({'name': 'Messor #1', 'species_text': 'Messor barbarus'});
      b = repo.createColony({'name': 'Lasius #2', 'species_text': 'Lasius niger'});
    });
    tearDown(() => db.dispose());

    test('blank tag: written, verified, registered – and resolves offline by link and by serial', () async {
      final tag = FakeTag('04A2B3C4D5E680');
      final r = await (assigner(a)..lockAfterWrite = true).handle(tag);
      expect(r, isA<Assigned>());
      expect(tag.uris.single, startsWith('https://ants.test/c/'));
      expect(tag.locked, isTrue);
      final token = parseScanInput(tag.uris.single)!;
      expect(repo.linkByToken(token)!.kind, 'nfc');
      expect(repo.nfcTags(a).single['locked'], true);
      // NFC → right colony, via the link on the tag …
      expect((repo.resolveTag(tag.uris, null, parseScanInput) as ScanFound).colonyId, a);
      // … and via the serial number alone (tag content overwritten by someone)
      expect((repo.resolveTag(const [], uidHash(key, tag.uidHex), parseScanInput) as ScanFound).colonyId, a);
      // server stores bytea – pulled rows come back as "\x…": still found
      final rec = db.records('nfc_tags').single;
      db.putRecord('nfc_tags', {...rec.json, 'uid_hash': '\\x${uidHash(key, tag.uidHex)}'});
      expect(repo.colonyByUidHash(uidHash(key, tag.uidHex)), a);
    });

    test('tag already on this colony is recognised', () async {
      final tag = FakeTag('01');
      await assigner(a).handle(tag);
      expect(await assigner(a).handle(tag), isA<AlreadyAssigned>());
      expect(repo.nfcTags(a), hasLength(1));
    });

    test('tag of another colony needs confirmation, then moves over', () async {
      final tag = FakeTag('02');
      await assigner(a).handle(tag);
      final oldToken = parseScanInput(tag.uris.single)!;
      final second = assigner(b);
      final r = await second.handle(tag);
      expect(r, isA<BelongsToOther>());
      expect((r as BelongsToOther).colonyName, 'Messor #1');
      second.allowReassign = true;
      expect(await second.handle(tag), isA<Assigned>());
      expect(repo.linkByToken(oldToken)!.active, isFalse);
      expect(repo.nfcTags(a), isEmpty, reason: 'same serial moved to the new colony');
      expect((repo.resolveTag(tag.uris, uidHash(key, '02'), parseScanInput) as ScanFound).colonyId, b);
    });

    test('read-only tags can be registered by serial number', () async {
      final tag = FakeTag('03', writable: false);
      final x = assigner(a);
      final r = await x.handle(tag);
      expect(r, isA<ReadOnlyTag>());
      expect((r as ReadOnlyTag).canUseSerial, isTrue);
      expect(x.registerSerial(tag), isTrue);
      expect(repo.nfcTags(a).single['scan_link_id'], isNull);
      expect((repo.resolveTag(const [], uidHash(key, '03'), parseScanInput) as ScanFound).colonyId, a);
    });

    test('removed too early or bad write: nothing is registered', () async {
      expect(await assigner(a).handle(FakeTag('04', failWrite: true)), isA<AssignFailed>());
      expect(await assigner(a).handle(FakeTag('05')..corruptOnWrite = true), isA<AssignFailed>());
      expect(repo.nfcTags(a), isEmpty);
    });

    test('deactivated tag link is reported as revoked', () async {
      final tag = FakeTag('06');
      await assigner(a).handle(tag);
      repo.removeNfcTag(repo.nfcTags(a).single['id'] as String);
      expect(repo.resolveTag(tag.uris, null, parseScanInput), isA<ScanRevoked>());
    });

    test('regenerating the QR code deactivates the old one', () {
      final old = repo.scanLinks(a).single.token;
      final fresh = repo.regenerateQr(a);
      expect(repo.resolveToken(old), isA<ScanRevoked>());
      expect((repo.resolveToken(fresh) as ScanFound).colonyId, a);
    });
  });

  test('device link QR payload', () {
    final l = parseDeviceLink('https://ants.example.com/link#code=abc_DEF-123')!;
    expect(l.server, 'https://ants.example.com');
    expect(l.code, 'abc_DEF-123');
    expect(parseDeviceLink('http://192.168.1.50:8080/link#code=x')!.server, 'http://192.168.1.50:8080');
    expect(parseDeviceLink('https://ants.example.com/c/7Kq2mZr9XbT4pLwA'), isNull);
  });

  group('labels', () {
    test('sheet layout honours the start field and paginates', () {
      final t = labelTemplates.firstWhere((t) => t.id == 'a4-38x21');
      final slots = layoutLabels(t, 70, startAt: 3);
      expect(slots.first.page, 0);
      expect(slots.first.x, closeTo(4.75 + 3 * (38.1 + 2.5), .001));
      expect(slots.first.y, closeTo(10.7, .001));
      expect(slots[61].page, 0, reason: '65 per sheet, starting at field 4: 62 labels fit on sheet 1');
      expect(slots[62].page, 1);
      expect(slots.last.page, 1);
      // every label fits on the page
      for (final s in slots) {
        expect(s.x + t.labelWidth, lessThanOrEqualTo(t.pageW));
        expect(s.y + t.labelHeight, lessThanOrEqualTo(t.pageH));
      }
      final single = layoutLabels(labelTemplates.first, 3);
      expect(single.map((s) => s.page), [0, 1, 2]);
    });

    test('single labels on A4 keep their real size, centred on the page', () {
      final t = labelTemplates.firstWhere((t) => t.id == 'single-25x25').onA4();
      expect((t.pageW, t.pageH, t.labelWidth, t.labelHeight), (210, 297, 25, 25));
      expect((t.cols, t.rows), (6, 10));
      final slots = layoutLabels(t, t.perPage);
      expect(slots.first.x, closeTo(210 - slots.last.x - 25, .001), reason: 'centred horizontally');
      expect(slots.first.y, closeTo(297 - slots.last.y - 25, .001), reason: 'centred vertically');
      for (final single in labelTemplates.where((t) => !t.isSheet)) {
        final a4 = single.onA4();
        final last = layoutLabels(a4, a4.perPage).last;
        expect(last.x + a4.labelWidth, lessThanOrEqualTo(200), reason: single.name);
        expect(last.y + a4.labelHeight, lessThanOrEqualTo(287), reason: single.name);
      }
    });

    test('labels show the end of the location path', () {
      expect(shortLocation('Ameisenraum/Regal A/Fach 3'), 'Regal A / Fach 3');
      expect(shortLocation('Wohnzimmer'), 'Wohnzimmer');
    });

    test('all templates fit their pages', () {
      for (final t in labelTemplates) {
        final s = layoutLabels(t, t.perPage).last;
        expect(s.x + t.labelWidth, lessThanOrEqualTo(t.pageW + .01), reason: t.name);
        expect(s.y + t.labelHeight, lessThanOrEqualTo(t.pageH + .01), reason: t.name);
      }
    });

    test('PDF is generated with the bundled font (umlauts, italics)', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final fonts = await LabelFonts.load();
      final labels = [
        for (var i = 1; i <= 7; i++)
          LabelData(
            url: 'https://ants.example.com/c/7Kq2mZr9XbT4pLw$i',
            name: i.isEven ? 'Lasius #$i' : 'Messor #$i',
            number: i,
            species: i.isEven ? 'Lasius niger' : 'Messor barbarus',
            location: 'Ameisenraum/Regal Ä/Fach $i',
            code: 'MB-$i',
          ),
      ];
      for (final t in [...labelTemplates, for (final s in labelTemplates.where((s) => !s.isSheet)) s.onA4()]) {
        final bytes = await buildLabelsPdf(
          t,
          labels,
          fonts: fonts,
          startAt: 2,
          options: const LabelOptions(code: true, nfcHint: true),
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-', reason: t.name);
        Directory('build/label-previews').createSync(recursive: true);
        File('build/label-previews/${t.id}.pdf').writeAsBytesSync(bytes);
      }
      // Built-in fallback font also works.
      final fb = LabelFonts(pw.Font.helvetica(), pw.Font.helveticaBold(), pw.Font.helveticaOblique());
      expect((await buildLabelsPdf(labelTemplates[3], labels.take(1).toList(), fonts: fb)).length, greaterThan(500));
    });
  });
}
