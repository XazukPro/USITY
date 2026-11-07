import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../domain/day_plan.dart';
import '../../domain/schedule.dart';
import '../../theme/tokens.dart';
import 'day_axis.dart';
import 'lesson_detail.dart';
import 'task_sheet.dart';

class PlannerPage extends StatefulWidget {
  const PlannerPage({
    super.key,
    required this.today,
    required this.plan,
    this.initialDay,
  });
  final DateTime? initialDay;
  final DateTime today;
  final DemoPlan plan;
  @override
  State<PlannerPage> createState() => _PlannerPageState();
}

const months = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];
const weekdays = [
  'Понедельник',
  'Вторник',
  'Среда',
  'Четверг',
  'Пятница',
  'Суббота',
  'Воскресенье',
];
String pairCount(int n) {
  final last = n % 10;
  if (n % 100 >= 11 && n % 100 <= 14) return '$n пар';
  return '$n ${last == 1
      ? 'пара'
      : last >= 2 && last <= 4
      ? 'пары'
      : 'пар'}';
}

class _PlannerPageState extends State<PlannerPage> {
  late DateTime selected = DateUtils.dateOnly(
    widget.initialDay ?? widget.today,
  );
  bool week = false;
  final anchors = List.generate(7, (_) => GlobalKey());
  late final Timer timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  void focusDay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !week) return;
      final c = anchors[selected.weekday - 1].currentContext;
      if (c != null) {
        Scrollable.ensureVisible(
          c,
          duration: const Duration(milliseconds: 220),
        );
      }
    });
  }

  void select(DateTime day) {
    setState(() => selected = DateUtils.dateOnly(day));
    if (week) focusDay();
  }

  void lesson(LessonOccurrence l) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => LessonDetail(lesson: l, plan: widget.plan),
    ),
  );
  Future<void> edit([PersonalPlanTask? task]) async {
    final result = await editPlanTask(context, selected, task: task);
    if (!mounted || result == null) return;
    widget.plan.save(result, previous: task);
    if (result.start != null) {
      select(result.day);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавлено во вкладку «Задачи»')),
      );
    }
  }

  Future<void> calendar() async {
    final result = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (mounted && result != null) select(result);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final heading = TextButton(
      onPressed: calendar,
      child: Wrap(
        spacing: Metrics.space1,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            months[selected.month - 1],
            style: TypeScale.titleLg.copyWith(color: p.ink),
          ),
          Text(
            '${selected.year}',
            style: TypeScale.caption.copyWith(color: p.inkMuted),
          ),
          Icon(Icons.expand_more, color: p.inkMuted, size: Metrics.space4),
        ],
      ),
    );
    final mode = Material(
      color: p.surfaceMuted,
      borderRadius: BorderRadius.circular(Metrics.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(Metrics.space1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final w in [false, true])
              Semantics(
                selected: w == week,
                button: true,
                child: InkWell(
                  onTap: () {
                    setState(() => week = w);
                    if (w) focusDay();
                  },
                  child: Ink(
                    decoration: BoxDecoration(
                      color: w == week ? p.surface : p.surfaceMuted,
                      borderRadius: BorderRadius.circular(Metrics.radiusSm),
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: Metrics.space3,
                      horizontal: Metrics.space3,
                    ),
                    child: Text(
                      w ? 'Неделя' : 'День',
                      style: TypeScale.caption,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.space5,
                Metrics.space3,
                Metrics.space5,
                Metrics.space3,
              ),
              child: LayoutBuilder(
                builder: (c, b) =>
                    b.maxWidth < 330 ||
                        MediaQuery.textScalerOf(c).scale(16) > 20
                    ? Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        children: [heading, mode],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: heading,
                            ),
                          ),
                          mode,
                        ],
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Metrics.space5),
              child: DayStrip(selected: selected, onSelect: select),
            ),
            const SizedBox(height: Metrics.space3),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.plan,
                builder: (_, _) => week
                    ? _week(p)
                    : DayAxis(
                        day: selected,
                        now: DateTime.now(),
                        plan: widget.plan,
                        openLesson: lesson,
                        editTask: edit,
                      ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        tooltip: 'Новая задача',
        onPressed: edit,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _week(Palette p) {
    final monday = DateTime(
      selected.year,
      selected.month,
      selected.day - selected.weekday + 1,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Metrics.space5, 0, Metrics.space5, 96),
      child: Column(
        children: [
          for (var i = 0; i < 7; i++)
            _weekDay(DateTime(monday.year, monday.month, monday.day + i), i, p),
        ],
      ),
    );
  }

  Widget _weekDay(DateTime day, int i, Palette p) {
    final entries = widget.plan.entriesOn(day);
    final count = entries.where((e) => e.lesson != null).length;
    return Column(
      key: anchors[i],
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Metrics.space3),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(
                '${weekdays[i]} · ${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}',
                style: TypeScale.heading,
              ),
              Text(
                pairCount(count),
                style: TypeScale.caption.copyWith(color: p.inkMuted),
              ),
              if (DateUtils.isSameDay(day, widget.today))
                Tag('сегодня', fill: p.accentTint, ink: p.accentInk),
            ],
          ),
        ),
        if (entries.isEmpty)
          Text('Пар нет', style: TypeScale.callout.copyWith(color: p.inkMuted)),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: Metrics.space2),
            child: Material(
              color: entry.lesson?.kind.tint(p) ?? p.surface,
              borderRadius: BorderRadius.circular(Metrics.space5),
              child: ListTile(
                onTap: () => entry.lesson != null
                    ? lesson(entry.lesson!)
                    : edit(entry.task!),
                leading: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(clockTime(entry.start), style: TypeScale.time),
                    Text(clockTime(entry.end), style: TypeScale.code),
                  ],
                ),
                title: Text(
                  entry.lesson?.subject ?? entry.task!.title,
                  style: TypeScale.bodyStrong,
                ),
                subtitle: Text(
                  entry.lesson?.location ??
                      'Задача · ${formatGap(entry.task!.duration)}',
                  style: TypeScale.code,
                ),
                trailing: entry.task != null
                    ? TaskCheck(
                        label: 'Выполнить: ${entry.task!.title}',
                        done: false,
                        onTap: () => widget.plan.toggleTask(entry.task!),
                      )
                    : widget.plan.remaining(entry.lesson!) == 0
                    ? null
                    : Tag(
                        '${widget.plan.remaining(entry.lesson!)}',
                        fill: p.accent,
                        ink: p.onFill,
                        icon: Icons.menu_book_outlined,
                      ),
              ),
            ),
          ),
      ],
    );
  }
}
