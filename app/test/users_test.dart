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

  test('admin users: shapes of the server answers, open server invitations only', () {
    final now = DateTime.utc(2026, 10, 1);
    final d = parseAdminUsers(
      {
        'users': [
          {'id': 'u1', 'email': 'a@ants.test'},
        ],
      },
      {
        'invitations': [
          {'id': 'open', 'expires_at': '2026-10-05T00:00:00Z', 'accepted_at': null},
          {'id': 'used', 'expires_at': '2026-10-05T00:00:00Z', 'accepted_at': '2026-09-30T00:00:00Z'},
          {'id': 'old', 'expires_at': '2026-09-01T00:00:00Z', 'accepted_at': null},
          {'id': 'colony', 'expires_at': '2026-10-05T00:00:00Z', 'colony_id': 'c1'},
        ],
      },
      now,
    );
    expect(d.users.single['email'], 'a@ants.test');
    expect(d.invitations.map((i) => i['id']), ['open']);
    expect(parseAdminUsers({'users': null}, {'invitations': null}, now).invitations, isEmpty);
  });

  test('sizes', () {
    expect(S.bytes(512), '512 B');
    expect(S.bytes(1536), '1,5 KB');
    expect(S.bytes(3 * 1024 * 1024 * 1024), '3,0 GB');
  });
}
