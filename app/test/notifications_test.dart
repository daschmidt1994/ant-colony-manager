import 'dart:math';

import 'package:ant_colony_manager/core/session.dart';
import 'package:ant_colony_manager/features/settings/notifications_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('random ntfy topic is long and hard to guess', () {
    final a = randomTopic(Random(1)), b = randomTopic(Random(2));
    expect(RegExp(r'^ameisen-[a-z2-9]{12}$').hasMatch(a), isTrue);
    expect(a, isNot(b));
  });

  test('server and topic ⇄ topic address (own server, sub path, default ntfy.sh)', () {
    expect(joinNtfyUrl('ntfy.meinedomain.at/', ' ameisen '), 'https://ntfy.meinedomain.at/ameisen');
    expect(joinNtfyUrl('http://192.168.1.10:8090', 'ameisen'), 'http://192.168.1.10:8090/ameisen');
    expect(joinNtfyUrl('', 'x'), 'https://ntfy.sh/x');
    expect(joinNtfyUrl('https://ntfy.sh', ''), '');
    expect(splitNtfyUrl('https://example.com/ntfy/ameisen'), ('https://example.com/ntfy', 'ameisen'));
    expect(splitNtfyUrl(''), ('https://ntfy.sh', ''));
    expect(splitNtfyUrl('https://host'), ('https://ntfy.sh', ''));
    expect(ntfyTopicPattern.hasMatch('ameisen_1-a'), isTrue);
    expect(ntfyTopicPattern.hasMatch('ameisen/x'), isFalse);
  });

  test('request body sends the token only when changed or removed', () {
    final p = {
      'ntfy_url': 'https://ntfy.sh/x',
      'ntfy_token_set': true,
      'email_available': true,
      'overdue_ntfy': true,
      'overdue_repeat_hours': 6,
      'quiet_start': '',
    };
    final keep = notifyPrefsBody(p);
    expect(keep.containsKey('ntfy_token'), isFalse);
    expect(keep.containsKey('ntfy_token_set'), isFalse); // read-only fields stay out
    expect(keep.containsKey('email_available'), isFalse);
    expect(keep['overdue_repeat_hours'], 6);
    expect(notifyPrefsBody(p, newToken: '  tk_abc ')['ntfy_token'], 'tk_abc');
    expect(notifyPrefsBody(p, newToken: '   ').containsKey('ntfy_token'), isFalse);
    expect(notifyPrefsBody(p, removeToken: true)['ntfy_token'], '');
  });

  test('app and server version belong together', () {
    expect(versionsMatch('1.2.0', '1.2.0'), isTrue);
    expect(versionsMatch('1.2.0', '1.1.0'), isFalse);
    expect(versionsMatch('1.2.0-dev.abc1234', '1.2.0-dev.abc1234'), isTrue);
    expect(versionsMatch('1.2.0-dev.abc1234', '1.2.0'), isFalse);
    expect(versionsMatch('1.2.0', null), isTrue); // server unknown (offline)
    expect(versionsMatch('lokal', '1.2.0'), isTrue); // local development build
  });
}
