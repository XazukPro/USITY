class HomeworkItem {
  const HomeworkItem({required this.text, this.id = '', this.version = 1});
  final String id;
  final String text;
  final int version;
}

enum LessonKind { lecture, seminar, lab }

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
    this.kind = LessonKind.lecture,
    this.subgroup,
    this.notes = const {},
  });

  final String id;
  final DateTime date;
  final String startTime;
  final String endTime;
  final String subject;
  final String teacher;
  final String location;
  final List<HomeworkItem> homework;
  final LessonKind kind;
  final String? subgroup;
  final Map<String, String> notes;
}
