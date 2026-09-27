import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../nfc/nfc_screens.dart';
import 'sync_triggers.dart';

/// Navigation: bottom bar on phones, rail on wide screens (web/tablet).
/// Scanning is the main navigation, so it sits in the middle.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _items = [
    (Icons.home_outlined, Icons.home, 'Übersicht'),
    (Icons.pest_control_outlined, Icons.pest_control, 'Kolonien'),
    (Icons.qr_code_scanner, Icons.qr_code_scanner, 'Scannen'),
    (Icons.route_outlined, Icons.route, 'Rundgang'),
    (Icons.menu, Icons.menu, 'Mehr'),
  ];

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context) => SyncTriggers(child: NfcScope(child: _layout(context)));

  Widget _layout(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: _go,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Icon(Icons.hive_outlined, color: Theme.of(context).colorScheme.primary, size: 32),
              ),
              destinations: [
                for (final (icon, sel, label) in _items)
                  NavigationRailDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: Text(label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: shell),
          ],
        ),
      );
    }
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: _go,
        destinations: [
          for (final (icon, sel, label) in _items)
            NavigationDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: label),
        ],
      ),
    );
  }
}
