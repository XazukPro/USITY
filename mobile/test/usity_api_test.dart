import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:usity/data/usity_api.dart';

void main() {
  test('snapshot attaches homework only to the matching lesson', () async {
    final api = UsityApi(
      baseUrl: 'https://example.test',
      token: 'test',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test');
        final Object body = switch (request.url.path) {
          '/me' => {'user_id': 'u', 'group_id': 'g', 'role': 'student'},
          '/groups/g/lessons' => [
            for (final id in ['a', 'b'])
              {
                'id': id,
                'subject': id,
                'starts_at': '2026-11-02T10:00:00Z',
                'ends_at': '2026-11-02T11:30:00Z',
                'teacher': 'Учитель',
                'location': '401',
              },
          ],
          '/groups/g/assignments' => [
            {'id': 'hw', 'lesson_id': 'b', 'text': 'Решить 4', 'version': 2},
          ],
          _ => throw StateError(request.url.path),
        };
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final snapshot = await api.loadSchedule();
    expect(snapshot.canReview, false);
    expect(snapshot.lessons[0].homework, isEmpty);
    expect(snapshot.lessons[1].homework.single.text, 'Решить 4');
    expect(snapshot.lessons[1].homework.single.version, 2);
  });

  test(
    'decision sends admin edits and selected lesson with draft version',
    () async {
      Map<String, dynamic>? sent;
      final api = UsityApi(
        baseUrl: 'https://example.test',
        token: 'test',
        client: MockClient((r) async {
          expect(r.url.path, '/groups/g/review/d/decision');
          sent = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response(
            '{"status":"approved","assignment_id":"a"}',
            200,
          );
        }),
      );
      await api.decide(
        groupId: 'g',
        draftId: 'd',
        version: 3,
        approve: true,
        text: 'Правки старосты',
        lessonId: 'lesson',
      );
      expect(sent, {
        'action': 'approve',
        'expected_version': 3,
        'text': 'Правки старосты',
        'lesson_id': 'lesson',
      });
    },
  );

  test(
    'unauthorized and conflict remain errors rather than empty snapshots',
    () async {
      for (final code in [401, 409, 500]) {
        final api = UsityApi(
          baseUrl: 'https://example.test',
          token: 'test',
          client: MockClient(
            (r) async =>
                http.Response('{"detail":{"current_status":"approved"}}', code),
          ),
        );
        await expectLater(
          api.loadSchedule(),
          throwsA(isA<ApiException>().having((e) => e.status, 'status', code)),
        );
      }
    },
  );
}
