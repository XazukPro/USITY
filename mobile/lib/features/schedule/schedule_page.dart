import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../theme/tokens.dart';

import '../../domain/schedule.dart';
export '../../domain/schedule.dart';

class SchedulePage extends StatefulWidget {
  const SchedulePage({
    super.key,
    required this.today,
    required this.lessons,
    this.actions = const [],
    this.onComplete,
    this.onDaySelected,
  });
  final ValueChanged<DateTime>? onDaySelected;
  final DateTime today;
  final List<LessonOccurrence> lessons;
  final List<Widget> actions;
  final void Function(HomeworkItem)? onComplete;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  static const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
  static const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  late DateTime selectedDay = DateUtils.dateOnly(widget.today);
  void selectDay(DateTime day) {
    setState(() => selectedDay = DateUtils.dateOnly(day));
    widget.onDaySelected?.call(selectedDay);
  }

  void changeWeek(int offset) => selectDay(
    DateTime(selectedDay.year, selectedDay.month, selectedDay.day + offset * 7),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dayLessons =
        widget.lessons
            .where((lesson) => DateUtils.isSameDay(lesson.date, selectedDay))
            .toList()
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Расписание',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  ...widget.actions,
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Metrics.space5),
              child: DayStrip(selected: selectedDay, onSelect: selectDay),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${weekdays[selectedDay.weekday - 1]}, ${selectedDay.day} ${months[selectedDay.month - 1]} ${selectedDay.year}',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Предыдущая неделя',
                    onPressed: () => changeWeek(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: 'Следующая неделя',
                    onPressed: () => changeWeek(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            Expanded(
              child: dayLessons.isEmpty
                  ? Center(
                      child: Text(
                        'На этот день занятий нет',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      itemCount: dayLessons.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 16),
                      itemBuilder: (context, index) => LessonCard(
                        lesson: dayLessons[index],
                        onComplete: widget.onComplete,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class LessonCard extends StatelessWidget {
  const LessonCard({super.key, required this.lesson, this.onComplete});
  final LessonOccurrence lesson;
  final void Function(HomeworkItem)? onComplete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${lesson.startTime}–${lesson.endTime}',
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              lesson.subject,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (lesson.subgroup != null) Text('Подгруппа ${lesson.subgroup}'),
            Text(
              lesson.teacher,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              lesson.location,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (lesson.homework.isNotEmpty) ...[
              const SizedBox(height: 16),
              Divider(color: colors.outlineVariant, height: 1),
              const SizedBox(height: 14),
              Text(
                'Домашнее задание',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              for (final item in lesson.homework)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      if (onComplete != null)
                        IconButton(
                          tooltip: 'Выполнить задание',
                          onPressed: () => onComplete!(item),
                          icon: const Icon(Icons.radio_button_unchecked),
                        ),
                      Expanded(
                        child: Text(
                          item.text,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
