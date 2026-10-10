import 'package:flutter/material.dart';

import 'core/config.dart';

void main() {
  runApp(const KupiIDariApp());
}

class KupiIDariApp extends StatelessWidget {
  const KupiIDariApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Купи и Дари',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0175C2)),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: PlaceholderScreen(),
      ),
    );
  }
}

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.volunteer_activism, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Купи и Дари', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          const Text('Скелет на приложението — Фаза 1'),
          const SizedBox(height: 24),
          Text(
            'API: ${ApiConfig.baseUrl}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
