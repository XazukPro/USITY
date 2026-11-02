import 'package:flutter/material.dart';

class LessonOccurrence {
  const LessonOccurrence({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.subject,
    required this.teacher,
    required this.location,
    required this.homework,
  });

  final String id;
  final DateTime date;
  final String startTime;
  final String endTime;
  final String subject;
  final String teacher;
  final String location;
  final List<String> homework;
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key, required this.today, required this.lessons});
  final DateTime today;
  final List<LessonOccurrence> lessons;

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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final monday = selectedDay.subtract(
      Duration(days: selectedDay.weekday - 1),
    );
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
                  Icon(Icons.calendar_month_outlined, color: colors.primary),
                ],
              ),
            ),
            SizedBox(
              height: 76,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: 7,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final day = monday.add(Duration(days: index));
                  final selected = DateUtils.isSameDay(day, selectedDay);
                  final key =
                      'day-${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
                  return Semantics(
                    selected: selected,
                    button: true,
                    label:
                        '${weekdays[index]}, ${day.day} ${months[day.month - 1]}',
                    child: InkWell(
                      key: Key(key),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => setState(() => selectedDay = day),
                      child: Container(
                        width: 48,
                        decoration: BoxDecoration(
                          color: selected
                              ? colors.primary
                              : colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              weekdays[index],
                              style: TextStyle(
                                color: selected
                                    ? colors.onPrimary
                                    : colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${day.day}',
                              style: TextStyle(
                                color: selected
                                    ? colors.onPrimary
                                    : colors.onSurface,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Text(
                '${weekdays[selectedDay.weekday - 1]}, ${selectedDay.day} ${months[selectedDay.month - 1]}',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
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
                      itemBuilder: (context, index) =>
                          LessonCard(lesson: dayLessons[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class LessonCard extends StatelessWidget {
  const LessonCard({super.key, required this.lesson});
  final LessonOccurrence lesson;

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
                  child: Text(
                    item,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
