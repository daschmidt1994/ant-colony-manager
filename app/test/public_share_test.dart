import 'package:ant_colony_manager/features/colonies/public_share.dart';
import 'package:ant_colony_manager/features/settings/oidc_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('publicPath keeps only the path of a share link', () {
    expect(publicPath('https://ants.example.com/p/abc123'), '/p/abc123');
    expect(publicPath('http://192.168.1.5:8080/p/xyz'), '/p/xyz');
    expect(publicPath('/p/xyz'), '/p/xyz');
  });

  test('oidcBody sends the secret only when typed or removed', () {
    Map<String, dynamic> body({String secret = '', bool remove = false}) => oidcBody(
      enabled: true,
      issuer: ' https://auth.example.com ',
      clientId: 'acm',
      label: 'Authentik',
      allowSignup: false,
      secret: secret,
      removeSecret: remove,
    );
    expect(body().containsKey('client_secret'), isFalse);
    expect(body()['issuer'], 'https://auth.example.com');
    expect(body(secret: ' s3 ')['client_secret'], 's3');
    expect(body(secret: 'x', remove: true)['client_secret'], '');
  });
}
