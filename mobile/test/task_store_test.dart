import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:usity/data/task_store.dart';
import 'package:usity/data/usity_api.dart';

typedef Json = Map<String, dynamic>;

const id = '11df1635-0375-4d77-ad46-3c5e48bb5627';
const otherId = 'd20e7036-83dc-4f5a-a10d-dfb13e206eb3';
final uuidV4 = matches(
  RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ),
);
const fields = {
  'title': 'Прочитать главу',
  'day': '2026-11-09',
  'start': null,
  'duration': 45,
  'remind': true,
  'completed_at': null,
};

Json row(String title, int version) => {
  ...fields,
  'title': title,
  'id': id,
  'version': version,
};

http.Response response(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

UsityApi taskApi({
  String taskId = id,
  required FutureOr<List<Json>> Function() get,
  FutureOr<http.Response> Function(Json)? put,
}) {
  final api = UsityApi(
    baseUrl: 'https://example.test',
    token: 'test',
    client: MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/account/tasks') {
        return response(await get());
      }
      if (request.method == 'PUT' &&
          request.url.path == '/account/tasks/$taskId' &&
          put != null) {
        return put(jsonDecode(request.body) as Json);
      }
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }),
  );
  addTearDown(api.close);
  return api;
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late Directory dir;
  late TaskStore store;

  Future<void> open() async {
    db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/account.db',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => TaskStore.createTables(db),
      ),
    );
    store = TaskStore(db, 'alice');
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('usity_tasks_');
    await open();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'offline edits survive reopening and accounts can share a task ID',
    () async {
      await store.save(id, fields);
      await store.save(id, {...fields, 'start': 540, 'remind': false});
      final bob = TaskStore(db, 'bob');
      expect(await bob.rows(), isEmpty);
      await bob.save(id, {...fields, 'title': 'Private'});
      await db.close();
      await open();
      expect(await store.rows(), [
        {...fields, 'start': 540, 'remind': false, 'id': id, 'version': 0},
      ]);
      expect(await store.pending(), 1);
      expect((await TaskStore(db, 'bob').rows()).single['title'], 'Private');
    },
  );

  test(
    'replays a lost acknowledgement after reopening, then sends the newer edit',
    () async {
      await store.save(id, fields);
      final requests = <Json>[];
      final ack = row(fields['title'] as String, 1);
      final latest = row('Later edit', 2);
      final api = taskApi(
        get: () => [latest],
        put: (body) {
          requests.add(body);
          if (requests.length == 1) throw http.ClientException('lost response');
          return response(requests.length == 2 ? ack : latest);
        },
      );
      await expectLater(store.sync(api), throwsA(isA<ApiException>()));
      await db.close();
      await open();
      await store.save(id, {
        ...fields,
        'title': 'Later edit',
      }, editingVersion: 0);
      await store.sync(api);
      expect(requests, hasLength(3));
      final op = requests.first['mutation_id'];
      expect(op, uuidV4);
      expect(requests.first, {
        ...fields,
        'expected_version': 0,
        'mutation_id': op,
      });
      expect(requests[1], requests.first);
      expect(requests.last, {
        ...fields,
        'title': 'Later edit',
        'expected_version': 1,
        'mutation_id': allOf(uuidV4, isNot(op)),
      });
      expect(await store.rows(), [latest]);
      expect(await store.pending(), 0);
    },
  );

  test('saves during a PUT are durable before the network resumes', () async {
    await store.save(id, fields);
    final started = Completer<void>();
    final resume = Completer<void>();
    final requests = <Json>[];
    var current = row(fields['title'] as String, 1);
    final api = taskApi(
      get: () => [current],
      put: (body) async {
        requests.add(body);
        if (requests.length == 1) {
          started.complete();
          await resume.future;
        }
        current = row(body['title'] as String, requests.length);
        return response(current);
      },
    );
    final syncing = store.sync(api);
    await started.future;
    final sameAccount = TaskStore(db, 'alice');
    await sameAccount.save(id, {...fields, 'title': 'Edited during upload'});
    expect((await store.rows()).single['title'], 'Edited during upload');
    final again = sameAccount.sync(api);
    resume.complete();
    await Future.wait([syncing, again]);
    expect(requests.map((r) => r['expected_version']), [0, 1]);
    expect(await store.rows(), [row('Edited during upload', 2)]);
    expect(await store.pending(), 0);
  });

  for (final expired in [false, true]) {
    test(
      'saving a stale editor immediately records the refreshed row (expired=$expired)',
      () async {
        final original = row('Original', 3);
        final remote = expired ? null : row('Newer remote', 4);
        await store.sync(taskApi(get: () => [original]));
        final opened = (await store.rows()).single;
        await store.sync(taskApi(get: () => [?remote]));
        final local = {...opened, 'title': 'Edited while open'};
        await store.save(id, local, editingVersion: opened['version'] as int);
        expect(await store.conflicts(), [
          {'id': id, 'local': local, 'remote': remote},
        ]);
        expect(await store.pending(), 0);
        await store.sync(taskApi(get: () => [?remote]));
        expect(await store.rows(), [local]);
        await store.resolve(id, false);
        expect(await store.rows(), [?remote]);
      },
    );
  }

  test('a current editor and an offline creation can queue edits normally', () async {
    await store.sync(taskApi(get: () => [row('Initial', 5)]));
    await store.save(id, fields, editingVersion: 5);
    await store.save(otherId, fields, editingVersion: 0);
    // A second editor cannot discard the existing outbox or rebase its version.
    await store.save(id, {
      ...fields,
      'title': 'Another edit',
    }, editingVersion: 4);
    expect(await store.conflicts(), isEmpty);
    expect(await store.pending(), 2);
    expect(
      (await store.rows()).singleWhere((task) => task['id'] == id),
      row('Another edit', 5),
    );
  });

  test(
    'a validation failure can be retried unchanged or corrected offline',
    () async {
      final rejected = <Json>[];
      final api = taskApi(
        get: () => [],
        put: (body) {
          rejected.add(body);
          return response({'detail': 'invalid title'}, 422);
        },
      );
      await store.save(id, {...fields, 'title': ''});
      for (var retry = 0; retry < 2; retry++) {
        await expectLater(store.sync(api), throwsA(isA<ApiException>()));
      }
      expect(rejected.last, rejected.first);
      expect(await store.pending(), 1);
      await store.save(id, fields);
      final accepted = row(fields['title'] as String, 1);
      await store.sync(
        taskApi(
          get: () => [accepted],
          put: (body) {
            expect(body['title'], fields['title']);
            expect(body['mutation_id'], isNot(rejected.first['mutation_id']));
            return response(accepted);
          },
        ),
      );
      expect(await store.rows(), [accepted]);
      expect(await store.pending(), 0);
    },
  );

  test(
    'expired completions are hidden offline without losing queued writes',
    () async {
      final now = DateTime.now().toUtc();
      await store.save(id, {
        ...fields,
        'completed_at': now.subtract(const Duration(days: 4)).toIso8601String(),
      });
      await store.save(otherId, {
        ...fields,
        'completed_at': now.subtract(const Duration(days: 2)).toIso8601String(),
      });
      expect((await store.rows()).single['id'], otherId);
      expect(await store.pending(), 2);
    },
  );

  test('a full snapshot expires clean rows and preserves edits made during the GET', () async {
    final original = row('Original', 3);
    await store.sync(
      taskApi(
        get: () => [
          original,
          {...original, 'id': otherId},
        ],
      ),
    );
    final bob = TaskStore(db, 'bob');
    await bob.sync(taskApi(get: () => [original]));
    final started = Completer<void>();
    final result = Completer<List<Json>>();
    final syncing = store.sync(
      taskApi(
        get: () {
          started.complete();
          return result.future;
        },
      ),
    );
    await started.future;
    await store.save(id, {...fields, 'title': 'Offline restore'});
    result.complete([]);
    await syncing;
    expect(await store.rows(), [row('Offline restore', 3)]);
    expect(await store.pending(), 1);
    expect(await bob.rows(), [original]);
  });

  for (final expired in [false, true]) {
    for (final keepLocal in [false, true]) {
      test(
        'version conflict persists and resolves (expired=$expired, keepLocal=$keepLocal)',
        () async {
          final original = row('Initial', 3);
          final current = expired ? null : row('Changed on server', 4);
          final local = row('Changed offline', 3);
          await store.sync(taskApi(get: () => [original]));
          await store.save(id, {...fields, 'title': 'Changed offline'});
          final writes = <Json>[];
          final conflictApi = taskApi(
            get: () => [?current],
            put: (body) {
              writes.add(body);
              return response({
                'detail': {'current': current},
              }, 409);
            },
          );
          await store.sync(conflictApi);
          await db.close();
          await open();
          await store.sync(conflictApi);
          expect(writes, hasLength(1));
          expect(writes.single['expected_version'], 3);
          expect(await store.rows(), [local]);
          expect(await store.conflicts(), [
            {'id': id, 'local': local, 'remote': current},
          ]);
          expect(await TaskStore(db, 'bob').conflicts(), isEmpty);
          expect(await store.pending(), 0);
          await store.resolve(id, keepLocal);
          expect(await store.conflicts(), isEmpty);
          if (keepLocal) {
            final base = expired ? 0 : 4;
            expect(await store.pending(), 1);
            final queued = (await store.rows()).single;
            final taskId = queued['id'] as String;
            expect(taskId, expired ? allOf(uuidV4, isNot(id)) : id);
            expect(queued['version'], base);
            final accepted = {
              ...row('Changed offline', base + 1),
              'id': taskId,
            };
            await store.sync(
              taskApi(
                taskId: taskId,
                get: () => [accepted],
                put: (body) {
                  expect(body['expected_version'], base);
                  expect(body['title'], 'Changed offline');
                  expect(
                    body['mutation_id'],
                    isNot(writes.single['mutation_id']),
                  );
                  return response(accepted);
                },
              ),
            );
            expect(await store.rows(), [accepted]);
          } else {
            expect(await store.rows(), [?current]);
          }
          expect(await store.pending(), 0);
        },
      );
    }
  }
}
