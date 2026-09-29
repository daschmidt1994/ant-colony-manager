/// Nuptial flight months from the care sheet text („Juni – August“,
/// „Mai-Juli“, „Juli“, „June – August“, „Mai – Juni, September“). Vague
/// texts („Herbst, nach den ersten Regenfällen“, „Regenzeit“) give null –
/// the calendar only shows what the sheet states as months.
List<int>? flightMonths(String? text) {
  if (text == null) return null;
  final parts = text.toLowerCase().split(RegExp(r'\s*(?:,|/|;|\bund\b|\band\b)\s*'));
  final months = <int>{};
  for (final part in parts) {
    final tokens = part.trim().split(RegExp(r'\s*(?:–|—|-|\bbis\b|\bto\b)\s*|\s+')).where((t) => t.isNotEmpty).toList();
    final nums = [for (final t in tokens) _month(t)];
    if (nums.isEmpty || nums.length > 2 || nums.contains(null)) return null;
    final from = nums.first!, to = nums.last!;
    for (var m = from; ; m = m % 12 + 1) {
      months.add(m);
      if (m == to) break;
    }
  }
  return months.isEmpty ? null : (months.toList()..sort());
}

int? _month(String t) {
  final w = t.replaceAll('.', '');
  for (final (i, names) in _names.indexed) {
    if (names.any((n) => w == n || (w.length >= 3 && n.startsWith(w)))) return i + 1;
  }
  return null;
}

const _names = [
  ['januar', 'j\u00e4nner', 'january', 'jan', 'j\u00e4n'], // patterns, not display text
  ['februar', 'feber', 'february', 'feb'],
  ['m\u00e4rz', 'march', 'm\u00e4r', 'mar'],
  ['april', 'apr'],
  ['mai', 'may'],
  ['juni', 'june', 'jun'],
  ['juli', 'july', 'jul'],
  ['august', 'aug'],
  ['september', 'sept', 'sep'],
  ['oktober', 'october', 'okt', 'oct'],
  ['november', 'nov'],
  ['dezember', 'december', 'dez', 'dec'],
];

/// First months of flight periods (a period over the new year starts in
/// its first month, e.g. [11, 12, 1] → 11).
List<int> flightStarts(List<int> months) => [
  for (final m in months)
    if (!months.contains(m == 1 ? 12 : m - 1)) m,
];
