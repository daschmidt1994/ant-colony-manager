import 'package:ant_colony_manager/app/strings.dart';
import 'package:ant_colony_manager/features/settings/users_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('invitation body: e-mail only when given', () {
    expect(invitationBody('  ', 7), {'valid_days': 7});
    expect(invitationBody(' anna@ants.test ', 30), {'email': 'anna@ants.test', 'valid_days': 30});
  });

  test('sizes', () {
    expect(S.bytes(512), '512 B');
    expect(S.bytes(1536), '1,5 KB');
    expect(S.bytes(3 * 1024 * 1024 * 1024), '3,0 GB');
  });
}
