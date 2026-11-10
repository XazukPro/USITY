class HomeworkItem {
  const HomeworkItem({
    required this.text,
    this.id = '',
    this.version = 1,
    this.completed = false,
  });
  final bool completed;
  final String id;
  final String text;
  final int version;
}

enum LessonKind { lecture, seminar, lab }

enum ResourceKind { note, pdf, link }

class StudyMaterial {
  const StudyMaterial(this.title, this.kind, this.value, this.category);
  final String title, value, category;
  final ResourceKind kind;
}

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
    this.materials = const [],
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
  final List<StudyMaterial> materials;
}
