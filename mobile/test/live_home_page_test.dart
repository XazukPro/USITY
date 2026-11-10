import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:usity/data/usity_api.dart';
import 'package:usity/features/schedule/live_home_page.dart';

void main() {
  testWidgets('completion keeps selected day after reload', (tester) async {
    final today = DateTime.now();
    // Choose another day of the same displayed week, independently of weekday.
    final day = DateTime(
      today.year,
      today.month,
      today.day,
    ).add(Duration(days: today.weekday == 7 ? -1 : 1));
    var done = false;
    final api = UsityApi(
      baseUrl: 'https://example.test',
      token: 'test',
      client: MockClient((r) async {
        if (r.method == 'PUT') {
          done = true;
          return http.Response('{}', 200);
        }
        final Object body = switch (r.url.path) {
          '/me' => {'user_id': 'u', 'group_id': 'g', 'role': 'student'},
          '/groups/g/lessons' => [
            {
              'id': 'l',
              'subject': 'Предмет выбранного дня',
              'starts_at': DateTime(
                day.year,
                day.month,
                day.day,
                10,
              ).toUtc().toIso8601String(),
              'ends_at': DateTime(
                day.year,
                day.month,
                day.day,
                11,
              ).toUtc().toIso8601String(),
              'teacher': '',
              'location': '',
            },
          ],
          '/groups/g/assignments' =>
            done
                ? []
                : [
                    {
                      'id': 'a',
                      'lesson_id': 'l',
                      'text': 'Выполнить',
                      'version': 1,
                    },
                  ],
          _ => throw StateError(r.url.path),
        };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await tester.pumpWidget(MaterialApp(home: LiveHomePage(api: api)));
    await tester.pumpAndSettle();
    final finder = find.byKey(
      Key(
        'day-${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
      ),
    );
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Выполнить задание'));
    await tester.tap(find.byTooltip('Выполнить задание'));
    await tester.pumpAndSettle();
    expect(find.text('Предмет выбранного дня'), findsOneWidget);
    expect(find.text('Выполнить'), findsNothing);
  });
}
