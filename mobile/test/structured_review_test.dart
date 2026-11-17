import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:usity/data/usity_api.dart';
import 'package:usity/domain/schedule.dart';
import 'package:usity/features/review/review_page.dart';
import 'package:usity/theme/app_theme.dart';

Map<String, dynamic> draftJson({
  Object? summary,
  List<Object?> runs = const [],
}) => {
  'id': 'draft',
  'text': 'Служебный текст старого формата',
  'version': 4,
  'source_context': {
    'messages': [
      {
        'id': 17,
        'text': 'Задание пришлю позже',
        'attachments': [
          {'id': 'file', 'kind': 'link', 'url': 'https://example.test/lecture'},
        ],
      },
    ],
  },
  'proposal_set': {'schema_version': 2, 'summary': summary, 'runs': runs},
};

Map<String, dynamic> summaryJson({
  String state = 'ready',
  String? text = 'Решить номера 4 и 5',
  String? lessonId = 'future',
  bool? homework = true,
}) => {
  'state': state,
  'homework': ?homework,
  'text': text,
  'subject': 'Математика',
  'lesson_id': lessonId,
  'due_at': '2030-01-02T10:00:00',
  'subgroups': [2],
  'missing_fields': state == 'waiting' ? ['text', 'lesson_id'] : [],
};

Map<String, dynamic> runJson(String type, Map<String, dynamic> fields) => {
  'agent_id': type == 'new_homework' ? 'homework_detection' : type,
  'status': 'proposed',
  'proposals': [
    {
      'proposal_type': type,
      'fields': fields,
      'source_ids': [17, 18],
      'reason': 'Найдено в сообщениях учебной темы',
      'uncertainty': ['model_uncertain'],
    },
  ],
};

final lessons = [
  for (final entry in {'past': 1, 'future': 2}.entries)
    LessonOccurrence(
      id: entry.key,
      date: DateTime(2030, 1, entry.value),
      startTime: '10:00',
      endTime: '11:30',
      subject: 'Математика',
      teacher: '',
      location: '',
      homework: const [],
    ),
];

Future<void> showEditor(
  WidgetTester tester,
  Map<String, dynamic> json, {
  Brightness brightness = Brightness.light,
  void Function(Map<String, dynamic>)? onDecision,
  void Function(http.Request)? onRequest,
  int responseStatus = 200,
}) async {
  if (const bool.fromEnvironment('USITY_REVIEW_CAPTURE')) {
    for (final family in ['Onest', 'JetBrainsMono']) {
      await (FontLoader(
        family == 'Onest' ? family : 'JetBrains Mono',
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: usityTheme(brightness),
      home: ReviewEditor(
        api: UsityApi(
          baseUrl: 'https://example.test',
          token: 'test',
          client: MockClient((request) async {
            onRequest?.call(request);
            onDecision?.call(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('{}', responseStatus);
          }),
        ),
        groupId: 'g',
        draft: ReviewDraft.fromJson(json),
        lessons: lessons,
        subjectGroupCounts: const {'Математика': 2},
        now: () => DateTime(2030, 1, 1, 11),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get publish => find.widgetWithText(FilledButton, 'Опубликовать');

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final type in [
    'new_homework',
    'incomplete_homework',
    'schedule_binding',
  ]) {
    testWidgets('$type is reviewed only through the whole homework form', (
      tester,
    ) async {
      await showEditor(
        tester,
        draftJson(
          summary: summaryJson(),
          runs: [
            runJson(type, {'text': 'Текст предложения'}),
          ],
        ),
      );
      await reveal(tester, find.byType(ExpansionTile));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.text('Отклонить предложение'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ExpansionTile),
          matching: find.byType(FilledButton),
        ),
        findsNothing,
      );
      await reveal(tester, publish);
      expect(tester.widget<FilledButton>(publish).onPressed, isNotNull);
    });
  }

  testWidgets('cancellation requires confirmation with target evidence', (
    tester,
  ) async {
    http.Request? request;
    final json = draftJson(
      summary: summaryJson(homework: false),
      runs: [
        runJson('assignment_change', {'kind': 'cancel', 'assignment_id': 'a'}),
      ],
    );
    json['source_context']['active_assignments'] = [
      {'id': 'a', 'text': 'Исходное задание'},
    ];
    await showEditor(tester, json, onRequest: (value) => request = value);
    await reveal(tester, find.byType(ExpansionTile));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Подтвердить отмену ДЗ'));
    await tester.tap(find.text('Подтвердить отмену ДЗ'));
    await tester.pumpAndSettle();
    expect(find.text('Отменить ДЗ?'), findsOneWidget);
    expect(find.text('Исходное задание'), findsOneWidget);
    expect(request, isNull);
    await tester.tap(find.text('Назад'));
    await tester.pumpAndSettle();
    expect(request, isNull);
    await tester.tap(find.text('Подтвердить отмену ДЗ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отменить ДЗ'));
    await tester.pumpAndSettle();
    expect(request!.url.path, '/groups/g/review/draft/proposals/0/0/decision');
    expect(jsonDecode(request!.body), {
      'action': 'approve',
      'expected_version': 4,
    });
  });

  for (final type in ['material', 'assignment_change', 'duplicate_conflict']) {
    testWidgets('pending $type blocks whole homework publication', (
      tester,
    ) async {
      Map<String, dynamic>? decision;
      await showEditor(
        tester,
        draftJson(
          summary: summaryJson(),
          runs: [
            runJson(type, {'kind': 'update'}),
          ],
        ),
        onDecision: (body) => decision = body,
      );
      await reveal(tester, publish);
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      await reveal(tester, find.text('Отклонить все оставшиеся'));
      await tester.tap(find.text('Отклонить все оставшиеся'));
      await tester.pumpAndSettle();
      expect(decision, {'action': 'reject', 'expected_version': 4});
    });
  }

  testWidgets('decided ancillary proposals allow whole homework publication', (
    tester,
  ) async {
    final run = runJson('duplicate_conflict', {'assignment_id': 'a'});
    run['proposals'][0]['decision'] = {'status': 'reviewed'};
    await showEditor(tester, draftJson(summary: summaryJson(), runs: [run]));
    await reveal(tester, publish);
    expect(tester.widget<FilledButton>(publish).onPressed, isNotNull);
  });

  test('homework false always blocks publishing, including waiting', () {
    for (final state in ['waiting', 'ready', 'needs_review', 'no_action']) {
      final draft = ReviewDraft.fromJson(
        draftJson(summary: summaryJson(state: state, homework: false)),
      );
      expect(draft.canPublishHomework, isFalse);
    }
  });

  test('decision indices survive malformed entries in optional proposals', () {
    final valid = runJson('material', {'attachment_id': 'file'});
    valid['proposals'] = [null, ...(valid['proposals'] as List)];
    final draft = ReviewDraft.fromJson(draftJson(runs: [null, valid]));
    expect(draft.agents.single.index, 1);
    expect(draft.agents.single.proposals.single.index, 1);
  });

  for (final kind in ['file', 'legacy', 'decided']) {
    testWidgets('$kind has no unsupported proposal approval control', (
      tester,
    ) async {
      final run = runJson('material', {'attachment_id': 'file'});
      final json = draftJson(
        summary: summaryJson(homework: false),
        runs: [run],
      );
      if (kind == 'file') {
        json['source_context']['messages'][0]['attachments'][0]['kind'] =
            'file';
      }
      if (kind == 'legacy') json['proposal_set']['schema_version'] = 1;
      if (kind == 'decided') {
        run['proposals'][0]['decision'] = {'status': 'approved'};
      }
      await showEditor(tester, json);
      await reveal(tester, find.byType(ExpansionTile));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.text('Опубликовать материал'), findsNothing);
      expect(find.text('Подтвердить отмену ДЗ'), findsNothing);
      if (kind == 'decided') {
        expect(find.text('Предложение принято'), findsOneWidget);
      }
      if (kind == 'legacy' || kind == 'decided') {
        expect(find.text('Отклонить предложение'), findsNothing);
      } else {
        expect(find.text('Отклонить предложение'), findsOneWidget);
      }
    });
  }

  testWidgets(
    'duplicate approval acknowledges without sending assignment edits',
    (tester) async {
      Map<String, dynamic>? decision;
      await showEditor(
        tester,
        draftJson(
          summary: summaryJson(homework: false),
          runs: [
            runJson('duplicate_conflict', {'assignment_id': 'a'}),
          ],
        ),
        onDecision: (body) => decision = body,
      );
      await reveal(tester, find.byType(ExpansionTile));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Отметить просмотренным'));
      await tester.tap(find.text('Отметить просмотренным'));
      await tester.pumpAndSettle();
      expect(decision, {'action': 'approve', 'expected_version': 4});
    },
  );

  for (final action in ['approve', 'reject']) {
    testWidgets('material proposal $action targets its own endpoint', (
      tester,
    ) async {
      http.Request? request;
      await showEditor(
        tester,
        draftJson(
          summary: summaryJson(homework: false),
          runs: [
            runJson('material', {'attachment_id': 'file'}),
          ],
        ),
        onRequest: (value) => request = value,
      );
      await reveal(tester, find.byType(ExpansionTile));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      final button = find.text(
        action == 'approve' ? 'Опубликовать материал' : 'Отклонить предложение',
      );
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        request!.url.path,
        '/groups/g/review/draft/proposals/0/0/decision',
      );
      expect(jsonDecode(request!.body), {
        'action': action,
        'expected_version': 4,
      });
    });
  }

  testWidgets('update proposal edits text and validates a future lesson', (
    tester,
  ) async {
    http.Request? request;
    await showEditor(
      tester,
      draftJson(
        summary: summaryJson(homework: false),
        runs: [
          runJson('assignment_change', {
            'kind': 'update',
            'assignment_id': 'assignment',
            'new_text': 'Новый вариант',
          }),
        ],
      ),
      onRequest: (value) => request = value,
    );
    await reveal(tester, find.byType(ExpansionTile));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Проверить изменение'));
    await tester.tap(find.text('Проверить изменение'));
    await tester.pumpAndSettle();
    expect(find.text('Новый вариант'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, 'Применить изменение');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byType(TextFormField), 'Правки админа');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('Математика · 1.1 · 10:00'), findsNothing);
    await tester.tap(find.text('Математика · 2.1 · 10:00').last);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(request!.url.path, '/groups/g/review/draft/proposals/0/0/decision');
    expect(jsonDecode(request!.body), {
      'action': 'approve',
      'expected_version': 4,
      'text': 'Правки админа',
      'lesson_id': 'future',
    });
  });

  testWidgets('proposal conflicts block retries and return to the queue', (
    tester,
  ) async {
    var calls = 0;
    await showEditor(
      tester,
      draftJson(
        summary: summaryJson(homework: false),
        runs: [
          runJson('material', {'attachment_id': 'file'}),
        ],
      ),
      responseStatus: 409,
      onRequest: (_) => calls++,
    );
    await reveal(tester, find.byType(ExpansionTile));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Опубликовать материал'));
    await tester.tap(find.text('Опубликовать материал'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Опубликовать материал'),
          )
          .onPressed,
      isNull,
    );
    await reveal(tester, find.text('Вернуться к очереди'));
    expect(find.text('Данные изменились. Обновите экран.'), findsOneWidget);
  });

  test('summary parses the exact contract and keeps legacy drafts usable', () {
    final draft = ReviewDraft.fromJson(draftJson(summary: summaryJson()));
    expect(draft.summary!.state, 'ready');
    expect(draft.summary!.text, 'Решить номера 4 и 5');
    expect(draft.summary!.subject, 'Математика');
    expect(draft.summary!.lessonId, 'future');
    expect(draft.summary!.dueAt, DateTime(2030, 1, 2, 10));
    expect(draft.summary!.subgroups, [2]);
    expect(draft.summary!.missingFields, isEmpty);
    final legacy = ReviewDraft.fromJson(draftJson()..remove('proposal_set'));
    expect(legacy.summary, isNull);
    expect(legacy.text, 'Служебный текст старого формата');
  });

  test('optional structured data tolerates missing and malformed values', () {
    for (final summary in [
      null,
      false,
      [],
      {
        'state': 1,
        'text': 42,
        'subject': [],
        'lesson_id': true,
        'due_at': 'not a date',
        'subgroups': [2, '1', null, -1],
        'missing_fields': ['text', 1, null],
      },
    ]) {
      final draft = ReviewDraft.fromJson(
        draftJson(
          summary: summary,
          runs: [
            null,
            17,
            {'proposals': false},
          ],
        ),
      );
      if (summary is Map) {
        expect(draft.summary!.text, isNull);
        expect(draft.summary!.dueAt, isNull);
        expect(draft.summary!.subgroups, [2]);
        expect(draft.summary!.missingFields, ['text']);
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('ready summary preselects valid suggestions in $brightness', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Map<String, dynamic>? decision;
      await showEditor(
        tester,
        draftJson(summary: summaryJson()),
        brightness: brightness,
        onDecision: (body) => decision = body,
      );
      expect(find.text('Предмет: Математика'), findsOneWidget);
      expect(find.text('Срок: 02.01.2030, 10:00'), findsOneWidget);
      if (const bool.fromEnvironment('USITY_REVIEW_CAPTURE')) {
        await expectLater(
          find.byType(ReviewEditor),
          matchesGoldenFile(
            Uri.file('/tmp/usity-review-${brightness.name}.png'),
          ),
        );
      }
      await reveal(tester, find.byType(TextFormField));
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'Решить номера 4 и 5',
      );
      await reveal(tester, publish);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      expect(decision, {
        'action': 'approve',
        'expected_version': 4,
        'text': 'Решить номера 4 и 5',
        'lesson_id': 'future',
        'subgroups': [2],
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('waiting starts empty and requires both admin text and lesson', (
    tester,
  ) async {
    Map<String, dynamic>? decision;
    await showEditor(
      tester,
      draftJson(
        summary: summaryJson(state: 'waiting', text: null, lessonId: null),
      ),
      onDecision: (body) => decision = body,
    );
    expect(find.textContaining('Ожидаем продолжение'), findsWidgets);
    await reveal(tester, find.byType(TextFormField));
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      isEmpty,
    );
    await reveal(tester, publish);
    expect(tester.widget<FilledButton>(publish).onPressed, isNull);
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), '   ');
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Математика · 2.1 · 10:00').last);
    await tester.pumpAndSettle();
    await reveal(tester, publish);
    expect(tester.widget<FilledButton>(publish).onPressed, isNull);
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), '  Решить №6  ');
    await reveal(tester, publish);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    expect(decision!['text'], 'Решить №6');
    expect(decision!['lesson_id'], 'future');
  });

  for (final id in ['past', 'missing']) {
    testWidgets('suggested $id lesson is not selected', (tester) async {
      await showEditor(tester, draftJson(summary: summaryJson(lessonId: id)));
      await reveal(tester, publish);
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
    });
  }

  for (final type in [
    'no_action',
    'material',
    'assignment_change',
    'duplicate_conflict',
  ]) {
    testWidgets('$type cannot be published as new homework', (tester) async {
      Map<String, dynamic>? decision;
      await showEditor(
        tester,
        draftJson(
          summary: summaryJson(
            state: type == 'no_action' ? type : 'needs_review',
            homework: type == 'no_action',
          ),
          runs: type == 'no_action'
              ? []
              : [
                  runJson(type, {'text': 'Не новое ДЗ'}),
                ],
        ),
        onDecision: (body) => decision = body,
      );
      expect(find.text('Новое домашнее задание'), findsNothing);
      await reveal(tester, publish);
      expect(tester.widget<FilledButton>(publish).onPressed, isNull);
      final reject = find.text(
        type == 'no_action' ? 'Отклонить' : 'Отклонить все оставшиеся',
      );
      await reveal(tester, reject);
      await tester.tap(reject);
      await tester.pumpAndSettle();
      expect(decision, {'action': 'reject', 'expected_version': 4});
    });
  }

  testWidgets('agent details expose fields, evidence and uncertainty', (
    tester,
  ) async {
    await showEditor(
      tester,
      draftJson(
        summary: summaryJson(),
        runs: [
          runJson('schedule_binding', {
            'subject_id': 'math',
            'candidate_subject_ids': ['math', 'algebra'],
            'subgroup_ids': [2],
            'lesson_id': 'future',
            'due_at': '2030-01-02T10:00:00',
          }),
        ],
      ),
    );
    await reveal(tester, find.text('Привязка к расписанию'));
    await tester.tap(find.text('Привязка к расписанию'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Варианты предмета: math, algebra'));
    expect(find.text('Подгруппы: 2'), findsOneWidget);
    await reveal(tester, find.text('Источники: 17, 18'));
    expect(find.text('Источники: 17, 18'), findsOneWidget);
    await reveal(tester, find.text('Неопределённость: Модель не уверена'));
    expect(tester.takeException(), isNull);
  });
}
