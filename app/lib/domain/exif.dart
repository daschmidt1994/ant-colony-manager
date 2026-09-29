/// Capture date from a JPEG's EXIF (DateTimeOriginal) – so a photo picked
/// from the gallery lands on the day it was taken, not today. The same small,
/// defensive parser as the server's readEXIF; malformed data yields null.
library;

import 'dart:typed_data';

DateTime? exifDateTaken(Uint8List data) {
  try {
    if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) return null;
    var i = 2;
    while (i + 4 <= data.length) {
      if (data[i] != 0xFF) return null;
      final marker = data[i + 1];
      if (marker == 0xDA || marker == 0xD9) return null; // start of scan / end
      final size = (data[i + 2] << 8) | data[i + 3];
      if (size < 2 || i + 2 + size > data.length) return null;
      if (marker == 0xE1 && size > 16 && String.fromCharCodes(data.sublist(i + 4, i + 10)) == 'Exif\x00\x00') {
        return _tiffDate(ByteData.sublistView(data, i + 10, i + 2 + size));
      }
      i += 2 + size;
    }
  } on RangeError {
    return null;
  }
  return null;
}

DateTime? _tiffDate(ByteData t) {
  final Endian e = switch ((t.getUint8(0), t.getUint8(1))) {
    (0x49, 0x49) => Endian.little, // II
    (0x4D, 0x4D) => Endian.big, // MM
    _ => throw RangeError('no TIFF header'),
  };
  int? exifIfd;
  void readIfd(int off, void Function(int tag, int type, int count, int value) fn) {
    if (off + 2 > t.lengthInBytes) return;
    final n = t.getUint16(off, e);
    for (var k = 0; k < n && k < 512; k++) {
      final p = off + 2 + k * 12;
      if (p + 12 > t.lengthInBytes) return;
      fn(t.getUint16(p, e), t.getUint16(p + 2, e), t.getUint32(p + 4, e), t.getUint32(p + 8, e));
    }
  }

  readIfd(t.getUint32(4, e), (tag, type, count, value) {
    if (tag == 0x8769) exifIfd = value;
  });
  if (exifIfd == null) return null;
  DateTime? taken;
  readIfd(exifIfd!, (tag, type, count, value) {
    if (tag != 0x9003 || type != 2 || count < 19 || value + 19 > t.lengthInBytes) return;
    final s = String.fromCharCodes(List.generate(19, (k) => t.getUint8(value + k)));
    // "2026:08:14 17:32:05" – local time of the camera
    final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$').firstMatch(s);
    if (m == null) return;
    final v = [for (var g = 1; g <= 6; g++) int.parse(m.group(g)!)];
    taken = DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  });
  return taken;
}

/// A capture date worth using: not before 2000, not in the future.
DateTime? plausibleTaken(DateTime? t, DateTime now) =>
    t == null || t.year < 2000 || t.isAfter(now.add(const Duration(days: 1))) ? null : t;
