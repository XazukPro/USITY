import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usity/domain/day_plan.dart';
import 'package:usity/main.dart';
import 'package:usity/design/components.dart';
import 'package:usity/features/schedule/day_axis.dart';

void main() {
  final day = DateTime(2026, 11, 7);
  test('compact gaps and boundaries of teaching intervals', () {
    expect([0, -1, 10, 80, 60, 125].map(formatGap), [
      '',
      '',
      '10мин.',
      '1ч. 20мин.',
      '1ч.',
      '2ч. 5мин.',
    ]);
    final l = PlanEntry.lesson(samplePlan(day).lessons.first);
    expect(l.isCurrent(day, DateTime(2026, 11, 7, 8, 30)), true);
    expect(l.isCurrent(day, DateTime(2026, 11, 7, 10, 5)), false);
    expect(l.isCurrent(day, DateTime(2026, 11, 8, 8, 30)), false);
  });
  test(
    'transitive overlaps form one interval, touching endpoints are separate',
    () {
      PlanEntry e(int from, int duration) =>
          PlanEntry.task(PersonalPlanTask('Пример', day, from, duration));
      final groups = groupEntries([
        e(75, 20),
        e(50, 25),
        e(10, 25),
        e(30, 25),
        e(10, 5),
      ]);
      expect(groups.map((g) => g.entries.length), [4, 1]);
      expect(groups.first.end, 75);
      expect(snapStart(663, 30), 665);
      expect(snapStart(1438, 30), 1410);
    },
  );
  testWidgets('homework toggled in detail updates both schedule counters', (
    t,
  ) async {
    await t.pumpWidget(const UsityApp());
    await t.tap(find.text('Дискретная математика'));
    await t.pumpAndSettle();
    expect(find.text('1 из 3 выполнено'), findsOneWidget);
    final check = find.byWidgetPredicate(
      (w) => w is TaskCheck && w.label == 'Решить задачи 4.12–4.18',
    );
    await t.ensureVisible(check);
    await t.tap(check);
    await t.pump();
    expect(find.text('2 из 3 выполнено'), findsOneWidget);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('ДЗ · 2'), findsNothing);
    await t.tap(find.text('Неделя'));
    await t.pumpAndSettle();
    expect(find.text('Дискретная математика'), findsOneWidget);
    await t.tap(find.text('Дискретная математика'));
    await t.pumpAndSettle();
    expect(find.text('2 из 3 выполнено'), findsOneWidget);
  });
  testWidgets(
    'creating without time saves to Tasks only and can be scheduled later',
    (t) async {
      await t.pumpWidget(const UsityApp());
      await t.tap(find.byTooltip('Новая задача'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Купить тетрадь');
      await t.tap(find.text('Без времени'));
      await t.pumpAndSettle();
      await t.tap(find.text('Добавить'));
      await t.pumpAndSettle();
      expect(find.text('Купить тетрадь'), findsNothing);
      await t.tap(find.text('Задачи').last);
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('Купить тетрадь').hitTestable(),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Купить тетрадь'), findsOneWidget);
      await t.tap(find.text('Купить тетрадь'));
      await t.pumpAndSettle();
      await t.tap(find.text('Время'));
      await t.pumpAndSettle();
      await t.tap(
        find.text(
          MaterialLocalizations.of(t.element(find.byType(TimePickerDialog)))
              .okButtonLabel,
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Сохранить'));
      await t.tap(find.text('Сохранить'));
      await t.pumpAndSettle();
      await t.tap(find.text('Расписание').last);
      await t.pumpAndSettle();
      expect(find.text('Купить тетрадь'), findsOneWidget);
    },
  );
  testWidgets(
    'long-press drag moves only the personal interval and snaps its start',
    (t) async {
      final plan = samplePlan(day);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: plan,
              builder: (_, _) => DayAxis(
                day: day,
                now: day,
                plan: plan,
                openLesson: (_) {},
                editTask: (_) {},
              ),
            ),
          ),
        ),
      );
      final target = find.text('Позвонить в деканат');
      await t.ensureVisible(target);
      final gesture = await t.startGesture(t.getCenter(target));
      await t.pump(const Duration(milliseconds: 650));
      await gesture.moveBy(const Offset(0, -90));
      await t.pump();
      await gesture.up();
      await t.pumpAndSettle();
      expect(plan.tasks.first.start, lessThan(750));
      expect(plan.tasks.first.start! % 5, 0);
      expect(plan.tasks.first.duration, 30);
      expect(plan.lessons.first.startTime, '08:30');
      expect(plan.tasks.last.start, 750);
    },
  );
}
