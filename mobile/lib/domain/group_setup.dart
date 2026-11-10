import 'dart:math';

import 'day_plan.dart';
import 'schedule.dart';

enum WeekPattern {
  all('Каждую неделю'),
  odd('Нечётная'),
  even('Чётная');

  const WeekPattern(this.label);
  final String label;
}

class SetupSubject {
  const SetupSubject(this.id, this.name, this.kinds, this.groups);
  final int id, groups;
  final String name;
  final Set<LessonKind> kinds;
}

class SetupSlot {
  const SetupSlot({
    required this.subjectId,
    required this.weekday,
    required this.kind,
    required this.start,
    required this.end,
    required this.teacher,
    required this.room,
    required this.pattern,
    this.subgroup,
  });
  final int subjectId, weekday, start, end;
  final LessonKind kind;
  final String teacher, room;
  final WeekPattern pattern;
  final int? subgroup;
}

/// Local wizard state. Occurrences are materialized only when the owner finishes.
class GroupSetup {
  GroupSetup(DateTime today)
    : start = DateTime(today.year, today.month, today.day),
      end = DateTime(today.year, today.month + 4, today.day);
  String name = '';
  DateTime start, end;
  bool alternating = false, telegramDemoConnected = false;
  final subjects = <SetupSubject>[], slots = <SetupSlot>[];
  final code =
      'USITY-${Random.secure().nextInt(0x1000000).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  String get invite => 'https://usity.example/join/$code';
  SetupSubject subject(int id) => subjects.firstWhere((s) => s.id == id);

  Iterable<DateTime> dates(SetupSlot slot) sync* {
    // School weeks begin on Monday. Use UTC calendar dates for arithmetic across DST.
    final first = DateTime.utc(start.year, start.month, start.day);
    final last = DateTime.utc(end.year, end.month, end.day);
    final monday = first.subtract(Duration(days: first.weekday - 1));
    for (
      var day = first.add(
        Duration(days: (slot.weekday - first.weekday + 7) % 7),
      );
      !day.isAfter(last);
      day = day.add(const Duration(days: 7))
    ) {
      final week = 1 + day.difference(monday).inDays ~/ 7;
      if (!alternating ||
          slot.pattern == WeekPattern.all ||
          (slot.pattern == WeekPattern.even) == week.isEven) {
        yield DateTime(day.year, day.month, day.day);
      }
    }
  }

  DemoPlan createPlan() {
    final lessons = <LessonOccurrence>[];
    for (final (i, slot) in slots.indexed) {
      for (final date in dates(slot)) {
        lessons.add(
          LessonOccurrence(
            id: 'local-$i-${date.toIso8601String()}',
            date: date,
            startTime: clockTime(slot.start),
            endTime: clockTime(slot.end),
            subject: subject(slot.subjectId).name,
            teacher: slot.teacher,
            location: slot.room,
            kind: slot.kind,
            subgroup: slot.subgroup?.toString(),
            homework: const [],
          ),
        );
      }
    }
    lessons.sort((a, b) {
      final day = a.date.compareTo(b.date);
      return day == 0 ? a.startTime.compareTo(b.startTime) : day;
    });
    return DemoPlan(
      lessons,
      [],
      subjectGroups: {
        for (final s in subjects)
          if (s.groups > 0) s.name: [for (var i = 1; i <= s.groups; i++) '$i'],
      },
    );
  }

  DateTime firstDay(DemoPlan plan, DateTime today) {
    final days = plan.visibleLessons.map((l) => l.date);
    final day = DateTime(today.year, today.month, today.day);
    return days.where((d) => !d.isBefore(day)).firstOrNull ??
        days.firstOrNull ??
        start;
  }
}
