import 'package:ant_colony_manager/app/router.dart';
import 'package:ant_colony_manager/core/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const out = SignedOut('https://ants.test');

  // follows the redirects like go_router until a page stays
  String settle(AuthState auth, String start) {
    var at = start;
    for (var i = 0; i < 10; i++) {
      final next = authRedirect(auth, Uri.parse(at));
      if (next == null) return at;
      at = next;
    }
    fail('redirect loop from $start');
  }

  test('the SSO code survives the splash screen while the session loads', () {
    final splash = settle(const AuthLoading(), '/sso?code=abc');
    expect(splash, startsWith('/splash'));
    expect(settle(out, splash), '/sso?code=abc');
  });

  test('an SSO error from the provider survives too', () {
    final splash = settle(const AuthLoading(), '/sso?error=access_denied');
    expect(settle(out, splash), '/sso?error=access_denied');
  });

  test('signed out: other pages lead to the login, the target is kept', () {
    expect(settle(out, '/colonies/1'), '/login?from=${Uri.encodeComponent('/colonies/1')}');
    expect(settle(out, settle(const AuthLoading(), '/')), '/login');
  });
}
