import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:usity/main.dart';
import 'package:usity/design/components.dart';
import 'package:usity/shell/tabs.dart';

void main() {
  testWidgets('theme choice survives rebuilding the application', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(UsityApp(preferences: prefs));
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тема'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная'));
    await tester.pumpAndSettle();
    expect(prefs.getString('themeMode'), 'dark');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(UsityApp(preferences: prefs));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(UsityTabs))).brightness,
      Brightness.dark,
    );
  });

  testWidgets('gallery completion changes only the selected sample', (
    tester,
  ) async {
    await tester.pumpWidget(const UsityApp());
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Галерея компонентов'));
    await tester.pumpAndSettle();
    final action = find.byWidgetPredicate(
      (w) => w is TaskCheck && w.label == 'Забрать справку',
    );
    await tester.scrollUntilVisible(
      action.hitTestable(),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('Забрать справку'), findsNothing);
    expect(find.text('Позвонить в деканат'), findsOneWidget);
    expect(find.text('Задачи пересекаются'), findsNothing);
  });
}
