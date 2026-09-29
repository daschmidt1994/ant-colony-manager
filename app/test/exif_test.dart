import 'dart:typed_data';

import 'package:ant_colony_manager/domain/exif.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal JPEG: SOI, APP1 with a TIFF (IFD0 → Exif IFD → DateTimeOriginal), SOS.
Uint8List jpegWithDate(String date, {Endian e = Endian.little, bool withExifPointer = true}) {
  final t = ByteData(200);
  if (e == Endian.little) {
    t.setUint8(0, 0x49);
    t.setUint8(1, 0x49);
  } else {
    t.setUint8(0, 0x4D);
    t.setUint8(1, 0x4D);
  }
  t.setUint16(2, 42, e);
  t.setUint32(4, 8, e); // IFD0 at 8
  t.setUint16(8, 1, e); // one entry
  t.setUint16(10, withExifPointer ? 0x8769 : 0x0112, e);
  t.setUint16(12, 4, e); // LONG
  t.setUint32(14, 1, e);
  t.setUint32(18, 26, e); // Exif IFD at 26
  t.setUint16(26, 1, e);
  t.setUint16(28, 0x9003, e); // DateTimeOriginal
  t.setUint16(30, 2, e); // ASCII
  t.setUint32(32, 20, e);
  t.setUint32(36, 44, e); // string at 44
  for (var k = 0; k < date.length; k++) {
    t.setUint8(44 + k, date.codeUnitAt(k));
  }
  final tiff = t.buffer.asUint8List(0, 64);
  final app1 = [...'Exif\x00\x00'.codeUnits, ...tiff];
  final len = app1.length + 2;
  return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, len >> 8, len & 0xFF, ...app1, 0xFF, 0xDA, 0, 2]);
}

void main() {
  test('reads DateTimeOriginal as local time (both byte orders)', () {
    expect(exifDateTaken(jpegWithDate('2026:08:14 17:32:05')), DateTime(2026, 8, 14, 17, 32, 5));
    expect(exifDateTaken(jpegWithDate('2025:12:31 23:59:59', e: Endian.big)), DateTime(2025, 12, 31, 23, 59, 59));
  });

  test('no or broken EXIF → null, never an exception', () {
    expect(exifDateTaken(jpegWithDate('2026:08:14 17:32:05', withExifPointer: false)), isNull);
    expect(exifDateTaken(jpegWithDate('kein datum hier da')), isNull);
    expect(exifDateTaken(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 1, 2])), isNull);
    expect(exifDateTaken(Uint8List.fromList([1, 2, 3])), isNull);
    final full = jpegWithDate('2026:08:14 17:32:05');
    for (var cut = 0; cut < full.length; cut += 7) {
      exifDateTaken(Uint8List.sublistView(full, 0, cut)); // truncated files must not throw
    }
  });

  test('plausible capture dates only', () {
    final now = DateTime(2026, 9, 29, 12);
    expect(plausibleTaken(DateTime(2026, 8, 14), now), DateTime(2026, 8, 14));
    expect(plausibleTaken(DateTime(1999, 1, 1), now), isNull); // camera clock never set
    expect(plausibleTaken(DateTime(2027, 1, 1), now), isNull);
    expect(plausibleTaken(null, now), isNull);
  });
}
