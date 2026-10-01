import 'package:ant_colony_manager/features/settings/feeds_screen.dart';
import 'package:ant_colony_manager/features/settings/offsite_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calendar filter: from everything to one type and back', () {
    final all = calendarTypes.keys.toList();
    final noWinter = toggleCalendarType(null, 'winter')!;
    expect(noWinter, isNot(contains('winter')));
    expect(noWinter.length, all.length - 1);
    expect(toggleCalendarType(noWinter, 'winter'), isNull); // everything again

    var only = <String>['winter'];
    expect(toggleCalendarType(only, 'winter'), same(only)); // never empty
    only = toggleCalendarType(only, 'feeding')!;
    expect(only, ['feeding', 'winter']); // fixed order
  });

  test('calendar colonies: all, some, never none', () {
    const all = ['a', 'b', 'c'];
    final noB = toggleCalendarColony(null, 'b', all)!;
    expect(noB, ['a', 'c']);
    expect(toggleCalendarColony(noB, 'b', all), isNull);
    final onlyA = ['a'];
    expect(toggleCalendarColony(onlyA, 'a', all), same(onlyA));
    expect(calendarSummary({'calendar_types': null, 'colony_ids': null}, {}), contains('alle Kolonien'));
    expect(
      calendarSummary({
        'calendar_types': ['winter'],
        'colony_ids': ['x', 'y'],
      }, {}),
      'Winterruhe · 2 Kolonien',
    );
  });

  test('off-site body: type, no user for a mounted folder', () {
    expect(offsiteBody(enabled: true, type: 'folder', url: ' /offsite ', user: 'x', keep: '7'), {
      'enabled': true,
      'type': 'folder',
      'url': '/offsite',
      'keep': 7,
      'encrypt': false,
    });
    final smb = offsiteBody(enabled: true, type: 'smb', url: 'smb://nas/b', user: ' anna ', keep: '3', password: 'pw');
    expect(smb['user'], 'anna');
    expect(smb['password'], 'pw');
    expect(smb['encrypt'], isFalse);
    expect(smb.containsKey('passphrase'), isFalse);
    final enc = offsiteBody(
      enabled: true,
      url: 'u',
      user: '',
      keep: '7',
      encrypt: true,
      passphrase: 'lange Passphrase',
    );
    expect(enc['encrypt'], isTrue);
    expect(enc['passphrase'], 'lange Passphrase');
    expect(offsiteAddress('smb').$2, startsWith('smb://'));
    expect(offsiteAddress('folder').$2, '/offsite');
  });

  test('NFS compose snippet from address and path', () {
    final y = nfsComposeSnippet(server: ' 192.168.178.20 ', export: 'mnt/user/backup', version: '3');
    expect(y, contains('- offsite:/offsite'));
    expect(y, contains('o: "addr=192.168.178.20,rw,nfsvers=3"'));
    expect(y, contains('device: ":/mnt/user/backup"'));
    expect(y, isNot(contains('\t')));
    expect(nfsComposeSnippet(server: '', export: ''), contains('addr=192.168.178.10'));
  });
}
