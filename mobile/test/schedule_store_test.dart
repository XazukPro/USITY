import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:usity/data/usity_api.dart';
import 'package:usity/data/schedule_store.dart';

void main() {
  test(
    'offline completion survives reopening and newer homework wins on replay',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await ScheduleStore.createTables(db);
      final store = ScheduleStore(db, 'scope', 'u', 'g');
      var version = 1;
      final sent = <Map>[];
      final api = UsityApi(
        baseUrl: 'https://example.test',
        token: 'example',
        client: MockClient((r) async {
          if (r.method == 'PUT') {
            sent.add(jsonDecode(r.body) as Map);
            return http.Response('{"detail":"revision changed"}', 409);
          }
          final result = switch (r.url.path) {
            '/me' => {'user_id': 'u', 'group_id': 'g', 'role': 'student'},
            '/groups/g/lessons' => [
              {
                'id': 'l',
                'subject': 'Math',
                'teacher': '',
                'location': '',
                'starts_at': '2026-11-09T07:00:00Z',
                'ends_at': '2026-11-09T08:00:00Z',
              },
            ],
            '/groups/g/assignments' => [
              {
                'id': 'hw',
                'lesson_id': 'l',
                'text': 'problem',
                'version': version,
                'completed': false,
              },
            ],
            _ => throw StateError('unexpected request'),
          };
          return http.Response(jsonEncode(result), 200);
        }),
      );
      await store.sync(api);
      final item = (await store.read())!.lessons.single.homework.single;
      await store.mark(item, true);
      final reopened = ScheduleStore(db, 'scope', 'u', 'g');
      expect(
        (await reopened.read())!.lessons.single.homework.single.completed,
        isTrue,
      );
      expect(await ScheduleStore(db, 'other', 'other', 'g').read(), isNull);
      version = 2;
      await reopened.sync(api);
      final updated = (await reopened.read())!.lessons.single.homework.single;
      expect(updated.version, 2);
      expect(updated.completed, isFalse);
      expect(sent.single, {'version': 1, 'completed': true});
      expect(await reopened.pending(), 0);
    },
  );
}
