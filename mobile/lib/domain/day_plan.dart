import 'package:flutter/material.dart';

import 'schedule.dart';

int minutesOf(String time) {
  final parts = time.split(':');
  return int.parse(parts.first) * 60 + int.parse(parts.last);
}

String clockTime(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
String formatGap(int minutes) {
  if (minutes <= 0) return '';
  return [
    if (minutes >= 60) '${minutes ~/ 60}ч.',
    if (minutes % 60 != 0) '${minutes % 60}мин.',
  ].join(' ');
}

int snapStart(double minutes, int duration) =>
    ((minutes / 5).round() * 5).clamp(0, 1440 - duration);

class PersonalPlanTask {
  PersonalPlanTask(
    this.title,
    this.day,
    this.start,
    this.duration, {
    this.remind = false,
  });
  String title;
  DateTime day;
  int? start;
  int duration;
  bool remind;
  DateTime? completed;
}

class PlanEntry {
  PlanEntry.lesson(LessonOccurrence value)
    : lesson = value,
      task = null,
      start = minutesOf(value.startTime),
      end = minutesOf(value.endTime);
  PlanEntry.task(PersonalPlanTask value)
    : task = value,
      lesson = null,
      start = value.start!,
      end = value.start! + value.duration;
  final LessonOccurrence? lesson;
  final PersonalPlanTask? task;
  final int start, end;
  bool isCurrent(DateTime day, DateTime now) =>
      lesson != null &&
      DateUtils.isSameDay(day, now) &&
      now.hour * 60 + now.minute >= start &&
      now.hour * 60 + now.minute < end;
}

class PlanGroup {
  PlanGroup(PlanEntry first)
    : entries = [first],
      start = first.start,
      end = first.end;
  final List<PlanEntry> entries;
  final int start;
  int end;
}

List<PlanGroup> groupEntries(Iterable<PlanEntry> entries) {
  final sorted = entries.toList()
    ..sort((a, b) {
      final time = a.start.compareTo(b.start);
      if (time != 0) return time;
      if ((a.lesson == null) != (b.lesson == null)) {
        return a.lesson == null ? 1 : -1;
      }
      return a.end.compareTo(b.end);
    });
  final groups = <PlanGroup>[];
  for (final entry in sorted) {
    if (groups.isEmpty || entry.start >= groups.last.end) {
      groups.add(PlanGroup(entry));
      continue;
    }
    groups.last.entries.add(entry);
    if (entry.end > groups.last.end) groups.last.end = entry.end;
  }
  return groups;
}

/// In-memory data for the design stage; the authenticated API has its own store.
class DemoPlan extends ChangeNotifier {
  DemoPlan(this.lessons, this.tasks);
  final List<LessonOccurrence> lessons;
  final List<PersonalPlanTask> tasks;
  final _completedHomework = <HomeworkItem>{};
  bool done(HomeworkItem item) => _completedHomework.contains(item);
  int remaining(LessonOccurrence lesson) =>
      lesson.homework.where((h) => !done(h)).length;
  void toggleHomework(HomeworkItem item) {
    if (!_completedHomework.remove(item)) _completedHomework.add(item);
    notifyListeners();
  }

  void toggleTask(PersonalPlanTask task) {
    task.completed = task.completed == null ? DateTime.now() : null;
    notifyListeners();
  }

  void move(PersonalPlanTask task, int start) {
    task.start = snapStart(start.toDouble(), task.duration);
    notifyListeners();
  }

  void save(PersonalPlanTask next, {PersonalPlanTask? previous}) {
    if (previous == null) {
      tasks.add(next);
    } else {
      next.completed = previous.completed;
      tasks[tasks.indexOf(previous)] = next;
    }
    notifyListeners();
  }

  List<PlanEntry> entriesOn(DateTime day) => [
    for (final lesson in lessons)
      if (DateUtils.isSameDay(day, lesson.date)) PlanEntry.lesson(lesson),
    for (final task in tasks)
      if (task.start != null &&
          task.completed == null &&
          DateUtils.isSameDay(day, task.day))
        PlanEntry.task(task),
  ]..sort((a, b) => a.start.compareTo(b.start));
}

DemoPlan samplePlan(DateTime day) {
  LessonOccurrence lesson(
    String id,
    String subject,
    String start,
    String end,
    LessonKind kind,
    String teacher,
    String room,
    List<String> work, {
    int offset = 0,
    String? subgroup,
    Map<String, String> notes = const {},
  }) => LessonOccurrence(
    id: id,
    date: DateTime(day.year, day.month, day.day + offset),
    subject: subject,
    startTime: start,
    endTime: end,
    kind: kind,
    teacher: teacher,
    location: room,
    subgroup: subgroup,
    notes: notes,
    homework: [
      for (final text in work) HomeworkItem(text: text, id: '$id-$text'),
    ],
  );
  final plan = DemoPlan(
    [
      lesson(
        'math',
        'Дискретная математика',
        '08:30',
        '10:05',
        LessonKind.seminar,
        'Орлов П. А.',
        'К-1010',
        [
          'Решить задачи 4.12–4.18',
          'Подготовить доказательство теоремы 3',
          'Прочитать конспект лекции 7',
        ],
        notes: const {
          'Конспект к семинару': 'Принцип включения и исключения\n\nДля двух конечных множеств число элементов в объединении равно сумме их мощностей за вычетом мощности пересечения.\n\nК семинару подготовьте пример с пересекающимися множествами.',
        },
      ),
      lesson(
        'analysis',
        'Математический анализ',
        '10:15',
        '11:50',
        LessonKind.lecture,
        'Громов А. И.',
        'Онлайн',
        [],
      ),
      lesson(
        'english',
        'Иностранный язык',
        '13:10',
        '14:45',
        LessonKind.seminar,
        'Рахимова Н. М.',
        'Б-312',
        ['Выполнить упражнение 8'],
        subgroup: '1',
      ),
      lesson(
        'lab',
        'Основы программирования',
        '10:15',
        '11:50',
        LessonKind.lab,
        'Соколов И. А.',
        'Л-204',
        ['Подготовить отчёт'],
        offset: 1,
      ),
    ],
    [
      PersonalPlanTask('Позвонить в деканат', day, 750, 30),
      PersonalPlanTask('Забрать справку', day, 750, 30),
    ],
  );
  plan.toggleHomework(plan.lessons.first.homework.last);
  return plan;
}
