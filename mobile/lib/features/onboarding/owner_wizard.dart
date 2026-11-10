import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../design/components.dart';
import '../../design/lesson_appearance.dart';
import '../../domain/day_plan.dart';
import '../../domain/group_setup.dart';
import '../../theme/tokens.dart';
import 'setup_forms.dart';

class OwnerWizard extends StatefulWidget {
  const OwnerWizard({super.key, required this.today, this.server = false});
  final bool server;
  final DateTime today;
  @override
  State<OwnerWizard> createState() => _OwnerWizardState();
}

class _OwnerWizardState extends State<OwnerWizard> {
  late final draft = GroupSetup(widget.today);
  int step = 0;
  late int weekday = widget.today.weekday.clamp(1, 6);
  static const titles = [
    'Создайте группу',
    'Предметы и подгруппы',
    'Расписание',
    'Подключите Telegram',
    'Пригласите студентов',
  ];
  static const hints = [
    'Вы станете старостой и сможете проверять домашние задания.',
    'Добавьте предметы и отметьте, какие занятия по ним бывают.',
    'Заполните пары на неделю. Время, преподаватель и аудитория.',
    'Бот читает только одну тему и предлагает черновики заданий.',
    'Приглашение для демонстрационной группы действует только в этом примере.',
  ];
  void go(int next) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => step = next);
  }

  void back() {
    if (step > 0) {
      go(step - 1);
    } else {
      Navigator.pop(context);
    }
  }

  bool get valid => switch (step) {
    0 => draft.name.trim().isNotEmpty && !draft.end.isBefore(draft.start),
    1 => draft.subjects.isNotEmpty,
    2 =>
      draft.slots.isNotEmpty &&
          draft.slots.every((s) => draft.dates(s).isNotEmpty),
    _ => true,
  };
  Future<void> date(bool first) async {
    final pick = await showDatePicker(
      context: context,
      initialDate: first ? draft.start : draft.end,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (pick == null || !mounted) return;
    setState(() {
      if (first) {
        draft.start = pick;
      } else {
        draft.end = pick;
      }
    });
  }

  Future<void> subject([SetupSubject? old]) async {
    final result = await showModalBottomSheet<SetupSubject>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SubjectForm(setup: draft, original: old),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (old == null) {
        draft.subjects.add(result);
      } else {
        draft.subjects[draft.subjects.indexOf(old)] = result;
      }
    });
  }

  Future<void> slot([SetupSlot? old]) async {
    final result = await showModalBottomSheet<SetupSlot>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SlotForm(setup: draft, weekday: weekday, original: old),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (old == null) {
        draft.slots.add(result);
      } else {
        draft.slots[draft.slots.indexOf(old)] = result;
      }
    });
  }

  Future<void> copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Скопировано')));
    }
  }

  Future<void> share(BuildContext anchor) async {
    final box = anchor.findRenderObject()! as RenderBox;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: 'Демонстрационное приглашение USITY: ${draft.invite}',
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть меню. Скопируйте ссылку.'),
          ),
        );
      }
    }
  }

  Widget card(Widget child, {Color? fill}) => Card(
    color: fill ?? Palette.of(context).surface,
    elevation: 0,
    margin: const EdgeInsets.only(bottom: Metrics.space2),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Metrics.space5),
    ),
    child: child,
  );

  List<Widget> content(Palette p) {
    final loc = MaterialLocalizations.of(context);
    switch (step) {
      case 0:
        return [
          TextFormField(
            initialValue: draft.name,
            key: const Key('group-name'),
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: 'Название группы',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => draft.name = v),
          ),
          const SizedBox(height: Metrics.space5),
          Row(
            children: [
              for (final first in [true, false])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: first ? Metrics.space2 : 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          first ? 'Начало семестра' : 'Конец семестра',
                          style: TypeScale.caption,
                        ),
                        OutlinedButton(
                          onPressed: () => date(first),
                          child: Text(
                            loc.formatShortDate(
                              first ? draft.start : draft.end,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (draft.end.isBefore(draft.start))
            Text(
              'Конец семестра раньше начала',
              style: TextStyle(color: p.dangerInk),
            ),
          const SizedBox(height: Metrics.space3),
          const Text('Недели', style: TypeScale.caption),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Одинаковые')),
              ButtonSegment(value: true, label: Text('Чётная / нечётная')),
            ],
            selected: {draft.alternating},
            onSelectionChanged: (v) =>
                setState(() => draft.alternating = v.single),
          ),
        ];
      case 1:
        return [
          for (final s in draft.subjects)
            card(
              ListTile(
                title: Text(s.name, style: TypeScale.bodyStrong),
                onTap: () => subject(s),
                subtitle: Wrap(
                  spacing: Metrics.space1,
                  runSpacing: Metrics.space1,
                  children: [
                    for (final k in s.kinds)
                      Tag(k.label, fill: k.tint(p), ink: k.ink(p)),
                    if (s.groups > 0)
                      Tag(
                        'Подгрупп: ${s.groups}',
                        fill: p.surfaceMuted,
                        ink: p.inkMuted,
                      ),
                  ],
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed: subject,
            icon: const Icon(Icons.add),
            label: const Text('Добавить предмет'),
          ),
        ];
      case 2:
        final slots = draft.slots.where((s) => s.weekday == weekday).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
        return [
          Row(
            children: [
              for (var d = 1; d <= 6; d++)
                Expanded(
                  child: Semantics(
                    selected: d == weekday,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: d == weekday
                            ? p.accent
                            : p.surfaceMuted,
                      ),
                      onPressed: () => setState(() => weekday = d),
                      child: Text(DayStrip.names[d - 1]),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Metrics.space4),
          for (final s in slots)
            card(
              ListTile(
                onTap: () => slot(s),
                leading: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(clockTime(s.start), style: TypeScale.time),
                    Text(clockTime(s.end), style: TypeScale.code),
                  ],
                ),
                title: Text(
                  draft.subject(s.subjectId).name,
                  style: TypeScale.bodyStrong,
                ),
                subtitle: Text(
                  [
                    s.room,
                    if (s.subgroup != null) 'Подгруппа ${s.subgroup}',
                    if (draft.alternating) s.pattern.label,
                  ].join(' · '),
                ),
                trailing: IconButton(
                  tooltip: 'Убрать пару',
                  onPressed: () => setState(() => draft.slots.remove(s)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
              fill: s.kind.tint(p),
            ),
          OutlinedButton.icon(
            onPressed: slot,
            icon: const Icon(Icons.add),
            label: const Text('Добавить пару'),
          ),
          if (draft.slots.any((s) => draft.dates(s).isEmpty))
            Text(
              'Проверьте дни занятий: некоторые пары не попадают в семестр.',
              style: TextStyle(color: p.dangerInk),
            ),
        ];
      case 3:
        return [
          for (final (index, label) in [
            'Добавьте бота USITY в чат группы.',
            'Откройте тему, где пишут домашние задания.',
            'Отправьте в этой теме команду подключения.',
          ].indexed)
            card(
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: p.accentTint,
                  child: Text('${index + 1}'),
                ),
                title: Text(label),
                subtitle: index == 2
                    ? Text('/connect ${draft.code}', style: TypeScale.code)
                    : null,
                trailing: index == 2
                    ? IconButton(
                        tooltip: 'Копировать команду',
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () => copy('/connect ${draft.code}'),
                      )
                    : null,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Tag(
              draft.telegramDemoConnected
                  ? 'Демо · подключено'
                  : 'Демо · ждём подключения',
              fill: draft.telegramDemoConnected ? p.lectureTint : p.warningTint,
              ink: draft.telegramDemoConnected ? p.lectureInk : p.warningInk,
            ),
          ),
        ];
      default:
        return [
          card(
            Padding(
              padding: const EdgeInsets.all(Metrics.space5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Ссылка-приглашение', style: TypeScale.caption),
                  const SizedBox(height: Metrics.space2),
                  SelectableText(
                    draft.invite,
                    style: TypeScale.code.copyWith(color: p.accentInk),
                  ),
                  const SizedBox(height: Metrics.space3),
                  Wrap(
                    spacing: Metrics.space2,
                    children: [
                      TextButton.icon(
                        onPressed: () => copy(draft.invite),
                        icon: const Icon(Icons.copy),
                        label: const Text('Копировать'),
                      ),
                      Builder(
                        builder: (c) => FilledButton(
                          onPressed: () => share(c),
                          child: const Text('Поделиться'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            fill: p.accentTint,
          ),
          card(
            ListTile(
              leading: CircleAvatar(
                backgroundColor: p.accent,
                child: const Text('Я'),
              ),
              title: const Text('Вы'),
              subtitle: const Text('Староста'),
              trailing: Tag('1 в группе', fill: p.accentTint, ink: p.accentInk),
            ),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopScope<GroupSetup>(
      canPop: step == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && step > 0) go(step - 1);
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Metrics.space5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Назад',
                      onPressed: back,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    const SizedBox(width: Metrics.space3),
                    for (var i = 0; i < (widget.server ? 3 : 5); i++)
                      Expanded(
                        child: Container(
                          height: 6,
                          margin: const EdgeInsets.only(right: Metrics.space1),
                          decoration: BoxDecoration(
                            color: i <= step ? p.accentInk : p.border,
                            borderRadius: BorderRadius.circular(
                              Metrics.radiusFull,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Metrics.space5),
                Expanded(
                  child: ListView(
                    key: ValueKey(step),
                    children: [
                      Text(titles[step], style: TypeScale.titleLg),
                      const SizedBox(height: Metrics.space1),
                      Text(
                        hints[step],
                        style: TypeScale.callout.copyWith(color: p.inkMuted),
                      ),
                      const SizedBox(height: Metrics.space6),
                      ...content(p),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: !valid
                      ? null
                      : () {
                          if (step == 4 || (widget.server && step == 2)) {
                            Navigator.pop(context, draft);
                          } else if (step == 3 &&
                              !draft.telegramDemoConnected) {
                            setState(() => draft.telegramDemoConnected = true);
                          } else {
                            go(step + 1);
                          }
                        },
                  child: Text(
                    step == 2 && widget.server
                        ? 'Подтвердить расписание'
                        : step == 4
                        ? 'Готово'
                        : step == 3 && !draft.telegramDemoConnected
                        ? 'Проверить подключение'
                        : 'Далее',
                  ),
                ),
                if (step == 3 && !draft.telegramDemoConnected)
                  TextButton(
                    onPressed: () => go(4),
                    child: const Text('Пропустить, подключу позже'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
