class HomeworkItem {
  const HomeworkItem({required this.text, this.id = '', this.version = 1});
  final String id;
  final String text;
  final int version;
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
  });

  final String id;
  final DateTime date;
  final String startTime;
  final String endTime;
  final String subject;
  final String teacher;
  final String location;
  final List<HomeworkItem> homework;
}
