import 'package:ant_colony_manager/features/settings/smtp_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SMTP request body: password only when typed or removed', () {
    final base = smtpBody(host: ' smtp.x.at ', port: '465', tls: 'tls', user: ' a@x.at ', from: 'a@x.at');
    expect(base, {'host': 'smtp.x.at', 'port': 465, 'tls': 'tls', 'user': 'a@x.at', 'from': 'a@x.at'});
    expect(
      smtpBody(host: 'h', port: '587', tls: 'starttls', user: '', from: 'a@b.c', password: 'pw')['password'],
      'pw',
    );
    expect(smtpBody(host: 'h', port: 'x', tls: 'starttls', user: '', from: 'a@b.c', removePassword: true), {
      'host': 'h',
      'port': 0,
      'tls': 'starttls',
      'user': '',
      'from': 'a@b.c',
      'password': '',
    });
    expect(smtpSecurity['tls']!.$2, 465);
  });
}
