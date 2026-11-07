import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usity/domain/group_setup.dart';
import 'package:usity/domain/schedule.dart';
import 'package:usity/main.dart';

void main() {
  test('first partial week is odd; inclusive semester bounds and subject subgroups', () {
    final draft = GroupSetup(DateTime(2026, 9, 2))
      ..end = DateTime(2026, 9, 21)
      ..alternating = true;
    draft.subjects.add(
      const SetupSubject(0, 'Алгебра', {LessonKind.lecture}, 2),
    );
    SetupSlot rule(WeekPattern w) => SetupSlot(
      subjectId: 0,
      weekday: 1,
      kind: LessonKind.lecture,
      start: 540,
      end: 630,
      teacher: 'Преподаватель',
      room: 'Онлайн',
      pattern: w,
      subgroup: 2,
    );
    expect(draft.dates(rule(WeekPattern.odd)), [DateTime(2026, 9, 14)]);
    expect(draft.dates(rule(WeekPattern.even)), [
      DateTime(2026, 9, 7),
      DateTime(2026, 9, 21),
    ]);
    draft.slots.add(rule(WeekPattern.all));
    final plan = draft.createPlan();
    expect(plan.availableSubgroups['Алгебра'], {'1', '2'});
    expect(plan.visibleLessons.length, 3);
    plan.chooseSubgroup('Алгебра', '1');
    expect(plan.visibleLessons, isEmpty);
    plan.chooseSubgroup('Алгебра', '2');
    expect(plan.visibleLessons.length, 3);
    expect(draft.firstDay(plan, DateTime(2026, 9, 9)), DateTime(2026, 9, 14));
    draft.alternating = false;
    expect(draft.dates(rule(WeekPattern.odd)).length, 3);
    plan.dispose();
  });
  testWidgets(
    'owner completes wizard, skips Telegram and sees entered lesson; student session survives',
    (t) async {
      await t.pumpWidget(const UsityApp());
      Future<void> tap(String label) async {
        await t.pump();
        final f = find.text(label).last;
        await t.ensureVisible(f);
        await t.tap(f);
        await t.pumpAndSettle();
      }

      await tap('Настройки');
      await tap('Демо старосты');
      FilledButton next() =>
          t.widget(find.widgetWithText(FilledButton, 'Далее'));
      expect(next().onPressed, isNull);
      await t.enterText(find.byKey(const Key('group-name')), 'Учебная группа');
      await tap('Далее');
      expect(next().onPressed, isNull);
      await tap('Добавить предмет');
      await t.enterText(
        find.byKey(const Key('subject-name')),
        'Линейная алгебра',
      );
      await tap('Сохранить');
      await tap('Далее');
      expect(next().onPressed, isNull);
      await tap('Добавить пару');
      await t.enterText(find.byKey(const Key('slot-teacher')), 'Иванова А. П.');
      await t.enterText(find.byKey(const Key('slot-room')), '401');
      await tap('Сохранить');
      await tap('Далее');
      expect(find.text('Подключите Telegram'), findsOneWidget);
      await t.tap(find.byTooltip('Назад'));
      await t.pumpAndSettle();
      expect(find.text('Линейная алгебра'), findsOneWidget);
      await tap('Далее');
      await tap('Пропустить, подключу позже');
      expect(
        find.textContaining('https://usity.example/join/'),
        findsOneWidget,
      );
      await tap('Готово');
      expect(find.text('Линейная алгебра'), findsOneWidget);
      expect(find.text('Дискретная математика'), findsNothing);
      await tap('Настройки');
      expect(find.text('Староста · 1 участник'), findsOneWidget);
      expect(find.text('Подключение пропущено'), findsOneWidget);
      await tap('Выйти из демо');
      await tap('Выйти');
      await tap('Расписание');
      expect(find.text('Дискретная математика'), findsOneWidget);
    },
  );
}
