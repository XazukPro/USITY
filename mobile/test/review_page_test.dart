import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:usity/data/usity_api.dart';
import 'package:usity/domain/schedule.dart';
import 'package:usity/features/review/review_page.dart';

void main() {
  testWidgets('admin edits homework and selects lesson before publishing', (
    tester,
  ) async {
    Map<String, dynamic>? decision;
    final api = UsityApi(
      baseUrl: 'https://example.test',
      token: 'test',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          decision = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"status":"approved"}', 200);
        }
        return http.Response(
          jsonEncode(
            decision == null
                ? [
                    {
                      'id': 'd',
                      'text': 'ДЗ из модели',
                      'version': 1,
                      'source_context': {
                        'messages': [
                          {'text': 'К математике номера 4 и 5'},
                        ],
                      },
                    },
                  ]
                : [],
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewPage(
          api: api,
          groupId: 'g',
          lessons: [
            LessonOccurrence(
              id: 'lesson',
              date: DateTime(2030, 1, 1),
              startTime: '10:00',
              endTime: '11:30',
              subject: 'Математика',
              teacher: '',
              location: '',
              homework: const [],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ДЗ из модели'));
    await tester.pumpAndSettle();
    expect(find.text('К математике номера 4 и 5'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Опубликовать'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextFormField), 'Решить номера 4 и 5');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Математика · 1.1 · 10:00').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Опубликовать'));
    await tester.pumpAndSettle();
    expect(decision, {
      'action': 'approve',
      'expected_version': 1,
      'text': 'Решить номера 4 и 5',
      'lesson_id': 'lesson',
    });
    expect(find.text('Всё проверено'), findsOneWidget);
  });

  testWidgets('expired selection is cleared without crashing the editor', (
    tester,
  ) async {
    var now = DateTime(2030, 1, 1, 9);
    final api = UsityApi(
      baseUrl: 'https://example.test',
      token: 'test',
      client: MockClient((r) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewEditor(
          api: api,
          groupId: 'g',
          draft: const ReviewDraft(
            id: 'd',
            text: 'ДЗ',
            version: 1,
            messages: [],
          ),
          now: () => now,
          lessons: [
            for (final hour in [10, 12])
              LessonOccurrence(
                id: '$hour',
                date: DateTime(2030, 1, 1),
                startTime: '$hour:00',
                endTime: '13:00',
                subject: 'Математика',
                teacher: '',
                location: '',
                homework: const [],
              ),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Математика · 1.1 · 10:00').last);
    await tester.pumpAndSettle();
    now = DateTime(2030, 1, 1, 11);
    await tester.enterText(find.byType(TextFormField), 'Правки');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Опубликовать'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('review editor shows all five AI-agent results', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewEditor(
          api: UsityApi(baseUrl: 'https://example.test', token: 'test'),
          groupId: 'g',
          draft: const ReviewDraft(
            id: 'd',
            text: 'Черновики',
            version: 1,
            messages: [],
            agents: [
              ReviewAgentRun('homework_detection', 'proposed'),
              ReviewAgentRun('schedule_binding', 'proposed'),
              ReviewAgentRun('duplicate_conflict', 'not_found'),
              ReviewAgentRun('material_proposal', 'not_found'),
              ReviewAgentRun('assignment_change', 'not_found'),
            ],
          ),
          lessons: const [],
        ),
      ),
    );

    expect(find.text('5 AI-агентов'), findsOneWidget);
    expect(find.text('Новое ДЗ'), findsOneWidget);
    expect(find.text('Привязка к расписанию'), findsOneWidget);
    expect(find.text('Дубли и противоречия'), findsOneWidget);
    expect(find.text('Учебные материалы'), findsOneWidget);
    expect(find.text('Изменения и отмены'), findsOneWidget);
  });
}
