import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import '../features/auth/auth_screens.dart';
import '../features/colonies/colony_detail_screen.dart';
import '../features/colonies/colony_form_screen.dart';
import '../features/colonies/colony_list_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/labels/labels_screen.dart';
import '../features/nfc/nfc_screens.dart';
import '../features/photos/photos.dart';
import '../features/round/round_screens.dart';
import '../features/scan/scan_screens.dart';
import '../features/sensors/sensors_screen.dart';
import '../features/settings/devices_screen.dart';
import '../features/settings/notifications_screen.dart';
import '../features/settings/smtp_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/shell.dart';
import '../features/species/species_screens.dart';
import '../features/stats/stats_screens.dart';
import '../features/timeline/timeline_screen.dart';

/// Paths reachable without an account.
const _publicPaths = {'/connect', '/connect/scan', '/login', '/setup', '/register', '/reset-password', '/splash'};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final path = state.uri.path;
      final target = state.uri.queryParameters['from'] ?? (_publicPaths.contains(path) ? null : state.uri.toString());
      String withFrom(String p) => target == null || target == '/' ? p : '$p?from=${Uri.encodeComponent(target)}';
      switch (auth) {
        case AuthLoading():
          return path == '/splash' ? null : withFrom('/splash');
        case NeedsServer():
          return path == '/connect' || path == '/connect/scan' ? null : withFrom('/connect');
        case SignedOut(:final setupRequired):
          if (path == '/register' || path == '/reset-password' || path == '/connect/scan') return null;
          final want = setupRequired ? '/setup' : '/login';
          return path == want ? null : withFrom(want);
        case SignedIn():
          if (_publicPaths.contains(path)) return target ?? '/';
          return null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/connect', builder: (_, _) => const ServerScreen()),
      GoRoute(path: '/connect/scan', builder: (_, _) => const ConnectScanScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
      GoRoute(
        path: '/register',
        builder: (_, s) => RegisterScreen(invite: s.uri.queryParameters['invite']),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (_, s) => ResetPasswordScreen(token: s.uri.queryParameters['token']),
      ),
      GoRoute(
        path: '/c/:token',
        builder: (_, s) => ScanLandingScreen(token: s.pathParameters['token']!),
      ),
      GoRoute(path: '/link', builder: (_, _) => const DeviceLinkLandingScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/', builder: (_, _) => const DashboardScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/colonies',
                builder: (_, _) => const ColonyListScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    builder: (_, s) => ColonyFormScreen(speciesId: s.uri.queryParameters['species']),
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => ColonyDetailScreen(colonyId: s.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (_, s) => ColonyFormScreen(colonyId: s.pathParameters['id']),
                      ),
                      GoRoute(
                        path: 'timeline',
                        builder: (_, s) => TimelineScreen(colonyId: s.pathParameters['id']!),
                      ),
                      GoRoute(
                        path: 'stats',
                        builder: (_, s) => ColonyStatsScreen(colonyId: s.pathParameters['id']!),
                      ),
                      GoRoute(
                        path: 'photos',
                        builder: (_, s) => GalleryScreen(colonyId: s.pathParameters['id']!),
                      ),
                      GoRoute(
                        path: 'nfc',
                        builder: (_, s) => NfcAssignScreen(colonyId: s.pathParameters['id']!),
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(
                path: '/species',
                builder: (_, _) => const SpeciesListScreen(),
                routes: [
                  GoRoute(path: 'new', builder: (_, _) => const SpeciesFormScreen()),
                  GoRoute(path: 'food', builder: (_, _) => const FoodGuideScreen()),
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => SpeciesDetailScreen(speciesId: s.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        builder: (_, s) => SpeciesFormScreen(speciesId: s.pathParameters['id']),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/scan', builder: (_, _) => const ScanScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/round',
                builder: (_, s) =>
                    RoundScreen(colonyId: s.uri.queryParameters['colony'], nonce: s.uri.queryParameters['t']),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => RoundSummaryScreen(roundId: s.pathParameters['id']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsScreen(),
                routes: [
                  GoRoute(path: 'sync', builder: (_, _) => const SyncDetailsScreen()),
                  GoRoute(path: 'stats', builder: (_, _) => const CollectionStatsScreen()),
                  GoRoute(path: 'sensors', builder: (_, _) => const SensorsScreen()),
                  GoRoute(path: 'notifications', builder: (_, _) => const NotificationsScreen()),
                  GoRoute(path: 'smtp', builder: (_, _) => const SmtpScreen()),
                  GoRoute(path: 'devices', builder: (_, _) => const DevicesScreen()),
                  GoRoute(
                    path: 'labels',
                    builder: (_, s) => LabelsScreen(preselected: {...?s.uri.queryParameters['colony']?.split(',')}),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
    debugLogDiagnostics: kDebugMode,
  );
});
