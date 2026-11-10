import 'package:flutter/material.dart';

import '../domain/schedule.dart';
import '../theme/tokens.dart';

extension LessonAppearance on LessonKind {
  String get label => switch (this) {
    LessonKind.lecture => 'Лекция',
    LessonKind.seminar => 'Семинар',
    LessonKind.lab => 'Лабораторная',
  };
  IconData get icon => switch (this) {
    LessonKind.lecture => Icons.co_present_outlined,
    LessonKind.seminar => Icons.people_outline,
    LessonKind.lab => Icons.science_outlined,
  };
  Color tint(Palette p) => switch (this) {
    LessonKind.lecture => p.lectureTint,
    LessonKind.seminar => p.seminarTint,
    LessonKind.lab => p.labTint,
  };
  Color ink(Palette p) => switch (this) {
    LessonKind.lecture => p.lectureInk,
    LessonKind.seminar => p.seminarInk,
    LessonKind.lab => p.labInk,
  };
  Color fill(Palette p) => switch (this) {
    LessonKind.lecture => p.lecture,
    LessonKind.seminar => p.seminar,
    LessonKind.lab => p.lab,
  };
}
