import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/day_plan.dart';
import '../../design/catalog_card.dart';
import '../../design/components.dart';
import '../../theme/tokens.dart';
import 'lesson_detail.dart';
import 'task_sheet.dart';

enum _Filter {
  homework('ДЗ'),
  all('Всё'),
  personal('Задачи');

  const _Filter(this.label);
  final String label;
}

typedef _TimedCard = ({int minute, int order, Widget card});

class DemoTasks extends StatefulWidget {
  const DemoTasks({super.key, required this.plan});
  final DemoPlan plan;
  @override
  State<DemoTasks> createState() => _TasksState();
}

class _TasksState extends State<DemoTasks> {
  _Filter filter = _Filter.all;
  Timer? expiry;
  @override
  void dispose() {
    expiry?.cancel();
    super.dispose();
  }

  Future<void> edit([PersonalPlanTask? task]) async {
    final next = await editPlanTask(context, DateTime.now(), task: task);
    if (mounted && next != null) widget.plan.save(next, previous: task);
  }

  List<Widget> cards(Palette p) {
    final plan = widget.plan, now = DateTime.now();
    final groups = <DateTime?, List<_TimedCard>>{};
    var order = 0;
    void add(DateTime? date, int minute, Widget card) {
      (groups[date == null ? null : DateUtils.dateOnly(date)] ??= []).add((
        minute: minute,
        order: order++,
        card: card,
      ));
    }

    if (filter != _Filter.personal) {
      for (final lesson in plan.visibleLessons) {
        for (final h in lesson.homework) {
          final done = plan.done(h);
          add(
            lesson.date,
            minutesOf(lesson.startTime),
            CatalogCard(
              title: h.text,
              done: done,
              subtitle: [
                lesson.subject,
                lesson.startTime,
                if (lesson.subgroup != null) 'подгруппа ${lesson.subgroup}',
              ].join(' · '),
              subtitleColor: lesson.kind.ink(p),
              icon: Icons.menu_book_outlined,
              iconColor: lesson.kind.ink(p),
              tint: lesson.kind.tint(p),
              trailing: TaskCheck(
                label: h.text,
                done: done,
                personal: false,
                onTap: () => plan.toggleHomework(h),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => LessonDetail(lesson: lesson, plan: plan),
                ),
              ),
            ),
          );
        }
      }
    }
    DateTime? nextExpiry;
    final overlapByDay = <DateTime, Set<PersonalPlanTask>>{};
    if (filter != _Filter.homework) {
      for (final t in plan.tasks) {
        final start = t.start, completed = t.completed;
        if (completed != null) {
          final until = completed.add(const Duration(days: 3));
          if (!now.isBefore(until)) continue;
          if (nextExpiry == null || until.isBefore(nextExpiry)) {
            nextExpiry = until;
          }
        }
        final date = DateUtils.dateOnly(t.day);
        final conflicts =
            start != null &&
            completed == null &&
            overlapByDay
                .putIfAbsent(
                  date,
                  () => {
                    for (final g in groupEntries(plan.entriesOn(date)))
                      if (g.entries.length > 1)
                        for (final e in g.entries)
                          if (e.task != null) e.task!,
                  },
                )
                .contains(t);
        add(
          start == null ? null : date,
          start ?? 0,
          CatalogCard(
            title: t.title,
            done: completed != null,
            subtitle: start == null
                ? 'Без времени'
                : '${clockTime(start)}–${clockTime(start + t.duration)} · ${formatGap(t.duration)}',
            warning: conflicts ? 'Пересекается с другим событием' : null,
            icon: Icons.checklist,
            iconColor: p.accentInk,
            tint: p.surfaceMuted,
            trailing: TaskCheck(
              label: t.title,
              done: completed != null,
              onTap: () => plan.toggleTask(t),
            ),
            onTap: () => edit(t),
          ),
        );
      }
    }
    expiry?.cancel();
    if (nextExpiry != null) {
      expiry = Timer(nextExpiry.difference(now), () {
        if (mounted) setState(() {});
      });
    }
    final dates = groups.keys.nonNulls.toList()..sort();
    final result = <Widget>[];
    for (final date in [...dates, if (groups.containsKey(null)) null]) {
      final title = date == null
          ? 'Без срока'
          : '${DateUtils.isSameDay(date, now) ? 'Сегодня, ' : ''}${MaterialLocalizations.of(context).formatMediumDate(date)}';
      result.add(SectionCaption(title));
      final rows = groups[date]!
        ..sort(
          (a, b) => a.minute != b.minute
              ? a.minute.compareTo(b.minute)
              : a.order.compareTo(b.order),
        );
      result.addAll(rows.map((r) => r.card));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg,
        title: const Text('Задачи', style: TypeScale.titleLg),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Metrics.space5,
              vertical: Metrics.space2,
            ),
            child: Material(
              color: p.surfaceMuted,
              borderRadius: BorderRadius.circular(Metrics.radiusMd),
              child: Padding(
                padding: const EdgeInsets.all(Metrics.space1),
                child: Row(
                  children: [
                    for (final f in _Filter.values)
                      Expanded(
                        child: Semantics(
                          selected: f == filter,
                          button: true,
                          child: InkWell(
                            key: ValueKey('tasks-filter-${f.name}'),
                            onTap: () => setState(() => filter = f),
                            child: Ink(
                              decoration: BoxDecoration(
                                color: f == filter ? p.surface : p.surfaceMuted,
                                borderRadius: BorderRadius.circular(
                                  Metrics.radiusSm,
                                ),
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: Metrics.hitMin,
                                ),
                                child: Center(
                                  child: Text(
                                    f.label,
                                    style: TypeScale.bodyStrong,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.plan,
              builder: (context, _) {
                final rows = cards(p);
                return rows.isEmpty
                    ? const Center(child: Text('Задач пока нет'))
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(
                          Metrics.space5,
                          0,
                          Metrics.space5,
                          96,
                        ),
                        children: rows,
                      );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: filter == _Filter.homework
          ? null
          : FloatingActionButton(
              heroTag: null,
              tooltip: 'Новая задача',
              onPressed: edit,
              child: const Icon(Icons.add),
            ),
    );
  }
}
