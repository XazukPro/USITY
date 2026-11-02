import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usity/features/schedule/schedule_page.dart';

void main() {
  testWidgets('homework appears inside its lesson card', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SchedulePage(
          today: DateTime(2026, 11, 2),
          lessons: [
            LessonOccurrence(
              id: 'math-1',
              date: DateTime(2026, 11, 2),
              startTime: '09:00',
              endTime: '10:30',
              subject: 'Математика',
              teacher: 'И. А. Иванова',
              location: 'Аудитория 401',
              homework: const ['Решить номера 4 и 5'],
            ),
          ],
        ),
      ),
    );

    expect(find.text('Математика'), findsOneWidget);
    expect(find.text('Решить номера 4 и 5'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Решить номера 4 и 5'),
        matching: find.byType(LessonCard),
      ),
      findsOneWidget,
    );
  });

  testWidgets('changing day updates visible lessons', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SchedulePage(
          today: DateTime(2026, 11, 2),
          lessons: [
            LessonOccurrence(
              id: 'math-1',
              date: DateTime(2026, 11, 2),
              startTime: '09:00',
              endTime: '10:30',
              subject: 'Математика',
              teacher: 'И. А. Иванова',
              location: '401',
              homework: const [],
            ),
            LessonOccurrence(
              id: 'history-1',
              date: DateTime(2026, 11, 3),
              startTime: '11:00',
              endTime: '12:30',
              subject: 'История',
              teacher: 'П. П. Петров',
              location: '205',
              homework: const [],
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('day-2026-11-03')));
    await tester.pumpAndSettle();

    expect(find.text('История'), findsOneWidget);
    expect(find.text('Математика'), findsNothing);
  });
}
