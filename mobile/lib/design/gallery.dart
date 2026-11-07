import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../shell/tabs.dart';
import 'components.dart';

/// Synthetic component specimens, accessible from debug settings.
class DesignGallery extends StatefulWidget {
  const DesignGallery({super.key});
  @override
  State<DesignGallery> createState() => _GalleryState();
}

class _GalleryState extends State<DesignGallery> {
  DateTime day = DateTime(2026, 11, 6);
  int view = 0, filter = 1, duration = 30;
  bool personalDone = false, homeworkDone = false, notify = true;
  final completedSamples = <String>{};
  static const gap = SizedBox(height: Metrics.space4);

  Widget choice(List<String> labels, int selected, ValueChanged<int> select) =>
      SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          for (var i = 0; i < labels.length; i++)
            ButtonSegment(value: i, label: Text(labels[i])),
        ],
        selected: {selected},
        onSelectionChanged: (v) => select(v.single),
      );

  Widget lesson(Palette p) => TimelineEntry(
    start: '08:30',
    end: '10:05',
    icon: Icons.groups_outlined,
    fill: p.seminarTint,
    ink: p.seminarInk,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Дискретная математика', style: TypeScale.heading),
        Text(
          'Соколова А. В.',
          style: TypeScale.callout.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: Metrics.space2),
        Wrap(
          spacing: Metrics.space2,
          runSpacing: Metrics.space1,
          children: [
            Tag('К-1010', fill: p.seminarTint, ink: p.seminarInk, mono: true),
            if (!homeworkDone)
              Tag(
                'ДЗ · 1',
                fill: p.accentTint,
                ink: p.accentInk,
                icon: Icons.menu_book_outlined,
              ),
          ],
        ),
      ],
    ),
  );

  Widget task(Palette p, String title, String start, String end) =>
      TimelineEntry(
        start: start,
        end: end,
        fill: p.surfaceMuted,
        ink: p.accentInk,
        icon: Icons.checklist,
        minimumHeight: 76,
        content: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$start–$end',
                    style: TypeScale.caption.copyWith(color: p.inkMuted),
                  ),
                  Text(title, style: TypeScale.bodyStrong),
                ],
              ),
            ),
            TaskCheck(
              label: title,
              done: completedSamples.contains(title),
              onTap: () => setState(() => completedSamples.add(title)),
            ),
          ],
        ),
      );

  Widget taskRow(String title, bool personal) {
    final done = personal ? personalDone : homeworkDone;
    return ListTile(
      tileColor: Palette.of(context).surface,
      leading: Icon(personal ? Icons.checklist : Icons.menu_book_outlined),
      title: Text(
        title,
        style: TypeScale.body.copyWith(
          decoration: done ? TextDecoration.lineThrough : null,
        ),
      ),
      trailing: TaskCheck(
        label: title,
        done: done,
        personal: personal,
        onTap: () => setState(() {
          if (personal) {
            personalDone = !personalDone;
          } else {
            homeworkDone = !homeworkDone;
          }
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Галерея компонентов')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Metrics.space5,
          Metrics.space5,
          Metrics.space5,
          96,
        ),
        children: [
          choice(
            ['День', 'Неделя', 'Элементы'],
            view,
            (v) => setState(() => view = v),
          ),
          gap,
          if (view < 2) ...[
            DayStrip(selected: day, onSelect: (v) => setState(() => day = v)),
            gap,
            if (view == 0) ...[
              lesson(p),
              gap,
              TimelineEntry(
                start: '10:15',
                end: '11:50',
                icon: Icons.co_present_outlined,
                fill: p.lecture,
                ink: p.onFill,
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Основы программирования',
                      style: TypeScale.heading,
                    ),
                    Tag(
                      'Л-204',
                      fill: p.lectureTint,
                      ink: p.lectureInk,
                      mono: true,
                    ),
                  ],
                ),
              ),
              gap,
              if (!completedSamples.contains('Позвонить в деканат'))
                task(p, 'Позвонить в деканат', '12:30', '13:00'),
              if (completedSamples.isEmpty)
                Text(
                  'Задачи пересекаются',
                  textAlign: TextAlign.end,
                  style: TypeScale.caption.copyWith(color: p.dangerInk),
                ),
              if (!completedSamples.contains('Забрать справку'))
                task(p, 'Забрать справку', '12:45', '13:15'),
            ] else ...[
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Metrics.space5),
                ),
                tileColor: p.lectureTint,
                leading: const Text('08:30', style: TypeScale.time),
                title: const Text('Математика'),
                trailing: Tag(
                  '1',
                  fill: p.accent,
                  ink: p.onFill,
                  icon: Icons.menu_book_outlined,
                ),
              ),
              gap,
              taskRow('Подготовить доклад', true),
            ],
          ] else ...[
            choice(
              ['ДЗ', 'Всё', 'Задачи'],
              filter,
              (v) => setState(() => filter = v),
            ),
            gap,
            if (filter != 2) taskRow('Решить № 4–12', false),
            if (filter != 0) taskRow('Подготовить доклад', true),
            gap,
            Wrap(
              spacing: Metrics.space2,
              runSpacing: Metrics.space2,
              children: [
                Tag(
                  'Лабораторная',
                  fill: p.labTint,
                  ink: p.labInk,
                  icon: Icons.science_outlined,
                ),
                Tag('На проверке', fill: p.warningTint, ink: p.warningInk),
              ],
            ),
            gap,
            Row(
              children: [
                for (var i = 0; i < 5; i++)
                  Expanded(
                    child: Container(
                      height: 6,
                      margin: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: i < 2 ? p.accentInk : p.border,
                        borderRadius: BorderRadius.circular(Metrics.radiusFull),
                      ),
                    ),
                  ),
              ],
            ),
            gap,
            SwitchListTile(
              title: const Text('Уведомления'),
              value: notify,
              onChanged: (v) => setState(() => notify = v),
            ),
            gap,
            FilledButton(
              onPressed: () => _sheet(context),
              child: const Text('Новая задача'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => homeworkDone = false),
              child: const Text('Восстановить ДЗ'),
            ),
            FilledButton.tonal(
              onPressed: () => setState(() => personalDone = true),
              style: FilledButton.styleFrom(
                backgroundColor: p.dangerTint,
                foregroundColor: p.dangerInk,
              ),
              child: const Text('Отклонить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Назад'),
            ),
            const FilledButton(onPressed: null, child: Text('Добавить')),
            gap,
            UsityTabs(
              index: 3,
              pending: 2,
              onSelect: (v) => setState(() => view = v == 0 ? 0 : 2),
            ),
          ],
        ],
      ),
      floatingActionButton: view < 2
          ? FloatingActionButton(
              tooltip: 'Новая задача',
              onPressed: () => _sheet(context),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Future<void> _sheet(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            Metrics.space5,
            0,
            Metrics.space5,
            MediaQuery.viewInsetsOf(context).bottom + Metrics.space5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Новая задача', style: TypeScale.title),
              gap,
              const TextField(
                decoration: InputDecoration(
                  labelText: 'Что нужно сделать',
                  border: OutlineInputBorder(),
                ),
              ),
              gap,
              Wrap(
                spacing: Metrics.space2,
                children: [
                  for (final m in [15, 30, 60])
                    ChoiceChip(
                      label: Text('$m мин.'),
                      selected: duration == m,
                      onSelected: (_) => update(() => duration = m),
                    ),
                ],
              ),
              gap,
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Готово'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
