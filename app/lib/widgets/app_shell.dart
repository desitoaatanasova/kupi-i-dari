import 'package:flutter/material.dart';

import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/app_user.dart';
import '../screens/admin_users_screen.dart';
import '../screens/locations_screen.dart';
import '../screens/shifts_screen.dart';
import '../screens/start_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  static const routeName = '/home';

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _baseTabs =
      <({IconData icon, IconData selectedIcon, String label})>[
        (
          icon: Icons.store_mall_directory_outlined,
          selectedIcon: Icons.store_mall_directory,
          label: 'Локации',
        ),
        (icon: Icons.event_outlined, selectedIcon: Icons.event, label: 'Смени'),
      ];

  static const _adminTab = (
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
    label: 'Потребители',
  );

  List<({IconData icon, IconData selectedIcon, String label})> _tabsFor(
    UserRole role,
  ) {
    if (role != UserRole.admin) return _baseTabs;
    return const [..._baseTabs, _adminTab];
  }

  Future<void> _signOut() async {
    final session = SessionScope.maybeOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Изход'),
            content: const Text('Сигурни ли сте, че искате да излезете?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Отказ'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Изход'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    if (session != null) await session.signOut();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const StartScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final roleLabel = session.user?.role.label ?? 'Демо';
    final tabs = _tabsFor(session.role);
    final effectiveIndex = _index < tabs.length ? _index : 0;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.volunteer_activism,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Text(tabs[effectiveIndex].label),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: AppTokens.spaceXs),
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceMd,
              vertical: AppTokens.spaceXs,
            ),
            decoration: BoxDecoration(
              color: AppColors.backgroundSecondary,
              borderRadius: BorderRadius.circular(AppTokens.radiusPill),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              roleLabel,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.logout_outlined),
            tooltip: 'Изход',
          ),
        ],
      ),
      body: IndexedStack(
        index: effectiveIndex,
        children: [
          const LocationsScreen(),
          const ShiftsScreen(),
          if (session.role == UserRole.admin) const AdminUsersScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: effectiveIndex,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: [
          for (var i = 0; i < tabs.length; i++)
            NavigationDestination(
              key: Key('app-tab-$i'),
              icon: Icon(tabs[i].icon),
              selectedIcon: Icon(tabs[i].selectedIcon),
              label: tabs[i].label,
            ),
        ],
      ),
    );
  }
}
