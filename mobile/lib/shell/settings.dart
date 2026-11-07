import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../design/gallery.dart';

const themeLabels = {
  ThemeMode.system: 'Как в системе',
  ThemeMode.light: 'Светлая',
  ThemeMode.dark: 'Тёмная',
};

class ThemePreference extends InheritedWidget {
  const ThemePreference({
    super.key,
    required this.mode,
    required this.select,
    required super.child,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> select;
  @override
  bool updateShouldNotify(ThemePreference oldWidget) => mode != oldWidget.mode;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.onReview, this.pending = 0});
  final VoidCallback? onReview;
  final int pending;
  @override
  Widget build(BuildContext context) {
    final pref = context.dependOnInheritedWidgetOfExactType<ThemePreference>();
    final mode = pref?.mode ?? ThemeMode.system;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(Metrics.space5),
        children: [
          if (onReview != null)
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('Проверка ДЗ'),
              trailing: Text('$pending'),
              onTap: onReview,
            ),
          ListTile(
            tileColor: Palette.of(context).surface,
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Тема'),
            subtitle: Text(themeLabels[mode]!),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final next = await showModalBottomSheet<ThemeMode>(
                context: context,
                showDragHandle: true,
                builder: (context) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in themeLabels.entries)
                        ListTile(
                          title: Text(entry.value),
                          selected: entry.key == mode,
                          trailing: entry.key == mode
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () => Navigator.pop(context, entry.key),
                        ),
                    ],
                  ),
                ),
              );
              if (next != null && context.mounted) pref?.select(next);
            },
          ),
          if (kDebugMode)
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Галерея компонентов'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const DesignGallery()),
              ),
            ),
        ],
      ),
    );
  }
}
