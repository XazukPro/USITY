import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../design/gallery.dart';
import '../design/catalog_card.dart';
import '../domain/day_plan.dart';

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
    required this.notifications,
    required this.setNotifications,
    required super.child,
  });
  final ThemeMode mode;
  final bool notifications;
  final ValueChanged<bool> setNotifications;
  final ValueChanged<ThemeMode> select;
  @override
  bool updateShouldNotify(ThemePreference oldWidget) =>
      mode != oldWidget.mode || notifications != oldWidget.notifications;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    this.onReview,
    this.pending = 0,
    this.plan,
    this.onExit,
  });
  final VoidCallback? onReview, onExit;
  final DemoPlan? plan;
  final int pending;

  Future<void> _theme(BuildContext context, ThemePreference? pref) async {
    final mode = pref?.mode ?? ThemeMode.system;
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
                trailing: entry.key == mode ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (next != null && context.mounted) pref?.select(next);
  }

  void _subgroups(BuildContext context, DemoPlan plan) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListenableBuilder(
          listenable: plan,
          builder: (context, _) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(Metrics.space5),
            children: [
              const Text('Подгруппы по предметам', style: TypeScale.title),
              for (final subject in plan.subgroupChoices.keys) ...[
                SectionCaption(subject),
                Wrap(
                  spacing: Metrics.space2,
                  children: [
                    for (final group in {
                      for (final l in plan.lessons)
                        if (l.subject == subject && l.subgroup != null)
                          l.subgroup!,
                    })
                      ChoiceChip(
                        label: Text('Подгруппа $group'),
                        selected: plan.subgroupChoices[subject] == group,
                        onSelected: (_) => plan.chooseSubgroup(subject, group),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: Metrics.space4),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Готово'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exit(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из демо?'),
        content: const Text(
          'Задачи и отметки этой учебной сессии будут сброшены.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (yes == true && context.mounted) onExit?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pref = context.dependOnInheritedWidgetOfExactType<ThemePreference>();
    final p = Palette.of(context);
    Widget group(List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(bottom: Metrics.space3),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(Metrics.space6),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 64, color: p.border),
              rows[i],
            ],
          ],
        ),
      ),
    );
    Widget row(
      IconData icon,
      String name, {
      VoidCallback? tap,
      String? value,
      Widget? trailing,
      bool danger = false,
    }) => ListTile(
      leading: Container(
        width: Metrics.space10,
        height: Metrics.space10,
        decoration: BoxDecoration(
          color: danger ? p.dangerTint : p.accentTint,
          borderRadius: BorderRadius.circular(Metrics.radiusSm),
        ),
        child: Icon(
          icon,
          color: danger ? p.dangerInk : p.accentInk,
          size: Metrics.space5,
        ),
      ),
      title: Text(
        name,
        style: TypeScale.bodyStrong.copyWith(
          color: danger ? p.dangerInk : p.ink,
        ),
      ),
      trailing:
          trailing ??
          (value == null
              ? Icon(Icons.chevron_right, color: p.inkMuted)
              : Text(
                  value,
                  style: TypeScale.caption.copyWith(color: p.inkMuted),
                )),
      onTap: tap,
    );
    final isDemo = plan != null;
    Widget content() => ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: Metrics.space5,
        vertical: Metrics.space2,
      ),
      children: [
        Container(
          padding: const EdgeInsets.all(Metrics.space5),
          decoration: BoxDecoration(
            color: p.accentTint,
            borderRadius: BorderRadius.circular(Metrics.space6),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: p.accent,
                foregroundColor: p.onFill,
                child: const Icon(Icons.person_outline),
              ),
              const SizedBox(width: Metrics.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isDemo ? 'Алексей Петров' : 'Учебный профиль',
                      style: TypeScale.heading,
                    ),
                    Text(
                      isDemo
                          ? 'Студент · демогруппа'
                          : onReview == null
                          ? 'Студент'
                          : 'Администратор',
                      style: TypeScale.callout,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Metrics.space4),
        if (onReview != null)
          group([
            row(
              Icons.fact_check_outlined,
              'Проверка ДЗ',
              value: '$pending',
              tap: onReview,
            ),
          ]),
        group([
          if (plan != null && plan!.subgroupChoices.isNotEmpty)
            row(
              Icons.people_outline,
              'Подгруппы',
              value: plan!.subgroupChoices.length == 1
                  ? 'Подгруппа ${plan!.subgroupChoices.values.single}'
                  : null,
              tap: () => _subgroups(context, plan!),
            ),
          if (isDemo)
            row(
              Icons.notifications_outlined,
              'Уведомления',
              trailing: Switch(
                value: pref?.notifications ?? true,
                onChanged: pref?.setNotifications,
              ),
            ),
          row(
            Icons.dark_mode_outlined,
            'Тема',
            value: themeLabels[pref?.mode ?? ThemeMode.system],
            tap: () => _theme(context, pref),
          ),
        ]),
        if (onExit != null)
          group([
            row(
              Icons.logout,
              'Выйти из демо',
              danger: true,
              tap: () => _exit(context),
            ),
          ]),
        if (kDebugMode)
          group([
            row(
              Icons.palette_outlined,
              'Галерея компонентов',
              tap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const DesignGallery()),
              ),
            ),
          ]),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки', style: TypeScale.titleLg),
        backgroundColor: p.bg,
      ),
      body: plan == null
          ? content()
          : ListenableBuilder(listenable: plan!, builder: (_, _) => content()),
    );
  }
}
