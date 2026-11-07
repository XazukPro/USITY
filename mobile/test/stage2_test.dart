import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usity/main.dart';
import 'package:usity/shell/tabs.dart';
import 'package:usity/domain/day_plan.dart';
import 'package:usity/design/components.dart';
import 'package:usity/features/schedule/demo_tasks.dart';

Future<void> tab(WidgetTester t, String name) async {
  await t.tap(
    find.descendant(of: find.byType(UsityTabs), matching: find.text(name)),
  );
  await t.pumpAndSettle();
}

Finder check(String label) =>
    find.byWidgetPredicate((w) => w is TaskCheck && w.label == label);

void main() {
  testWidgets(
    'task filters, restoration and homework badges share schedule state',
    (t) async {
      await t.pumpWidget(const UsityApp());
      await tab(t, 'Задачи');
      await t.tap(find.byKey(const ValueKey('tasks-filter-homework')));
      await t.pumpAndSettle();
      expect(find.byTooltip('Новая задача'), findsNothing);
      const hw = 'Решить задачи 4.12–4.18', personal = 'Позвонить в деканат';
      await t.tap(check(hw));
      await t.pumpAndSettle();
      await t.tap(find.text(hw));
      await t.pumpAndSettle();
      expect(find.text('2 из 3 выполнено'), findsOneWidget);
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('tasks-filter-personal')));
      await t.pumpAndSettle();
      expect(find.text(hw), findsNothing);
      await t.tap(check(personal));
      await t.pumpAndSettle();
      expect(
        t.widget<Text>(find.text(personal)).style!.decoration,
        TextDecoration.lineThrough,
      );
      await tab(t, 'Расписание');
      expect(find.text('ДЗ · 2'), findsNothing);
      expect(find.text(personal), findsNothing);
      await t.tap(find.text('Неделя'));
      await t.pumpAndSettle();
      expect(find.text(personal), findsNothing);
      await tab(t, 'Задачи');
      await t.tap(check(personal));
      await t.pumpAndSettle();
      await tab(t, 'Расписание');
      expect(find.text(personal), findsOneWidget);
    },
  );
  testWidgets(
    'expired personal entries disappear while completed homework remains',
    (t) async {
      final now = DateTime.now(), plan = samplePlan(DateTime.now());
      plan.tasks.first.completed = now.subtract(
        const Duration(days: 3, seconds: 1),
      );
      await t.pumpWidget(MaterialApp(home: DemoTasks(plan: plan)));
      expect(find.text('Позвонить в деканат'), findsNothing);
      expect(find.text('Прочитать конспект лекции 7'), findsOneWidget);
    },
  );
  testWidgets('materials search combines with subject and opens the note', (
    t,
  ) async {
    await t.pumpWidget(const UsityApp());
    await tab(t, 'Материалы');
    await t.tap(find.widgetWithText(ChoiceChip, 'Математический анализ'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'МНОЖЕСТВА');
    await t.pumpAndSettle();
    expect(find.text('Материалы не найдены'), findsOneWidget);
    await t.tap(find.widgetWithText(ChoiceChip, 'Все'));
    await t.pumpAndSettle();
    expect(find.text('Множества и операции'), findsOneWidget);
    await t.tap(find.byTooltip('Очистить поиск'));
    await t.pumpAndSettle();
    await t.tap(find.text('Конспект к семинару'));
    await t.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
  });
  testWidgets(
    'choosing a subject subgroup updates its lessons and homework only',
    (t) async {
      await t.pumpWidget(const UsityApp());
      await tab(t, 'Настройки');
      await t.tap(find.text('Подгруппы'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(ChoiceChip, 'Подгруппа 2'));
      await t.pumpAndSettle();
      await t.tap(find.text('Готово'));
      await t.pumpAndSettle();
      await tab(t, 'Задачи');
      await t.tap(find.byKey(const ValueKey('tasks-filter-homework')));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('Прочитать диалог к занятию'),
        140,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Выполнить упражнение 8'), findsNothing);
      await tab(t, 'Расписание');
      expect(find.text('Б-314'), findsOneWidget);
    },
  );
}
