import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'usity_api.dart';

typedef _Json = Map<String, dynamic>;

/// Offline personal tasks for one account on one server. The caller owns [db].
class TaskStore {
  TaskStore(this.db, this.scope);

  final Database db;
  final String scope;

  static const _table = 'personal_tasks';
  static const _key = 'scope = ? AND id = ?';
  static const _pending =
      'scope = ? AND mutation_id IS NOT NULL AND conflict IS NULL';
  static final _syncs = <(String, String), Future<void>>{};

  static Future<void> createTables(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS $_table (
      scope TEXT NOT NULL,
      id TEXT NOT NULL,
      fields TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 0,
      mutation_id TEXT,
      attempt TEXT,
      conflict TEXT,
      PRIMARY KEY (scope, id)
    )
  ''');

  static _Json _fields(_Json task) => {
    'title': task['title'] as String,
    'day': task['day'] as String,
    'start': task['start'] as int?,
    'duration': task['duration'] as int,
    'remind': task['remind'] as bool,
    'completed_at': task['completed_at'] as String?,
  };

  static _Json _local(Map<String, Object?> record) => {
    ...jsonDecode(record['fields'] as String) as _Json,
    'id': record['id'],
    'version': record['version'],
  };

  static _Json _remote(_Json task, {String? expectedId}) {
    final id = task['id'] as String;
    final version = task['version'] as int;
    if (version < 1 || (expectedId != null && expectedId != id)) {
      throw const FormatException('Unexpected task identity or version');
    }
    return {..._fields(task), 'id': id, 'version': version};
  }

  /// Saves a full set of editable fields, even while a previous PUT is in flight.
  /// Pass the version seen when opening an editor to detect a refresh before
  /// Save. Version zero denotes a task that has never been published.
  Future<void> save(
    String id,
    Map<String, dynamic> fields, {
    int? editingVersion,
  }) {
    final changes = <String, Object?>{
      'fields': jsonEncode(_fields(fields)),
      'mutation_id': const Uuid().v4(),
    };
    return db.transaction((txn) async {
      final args = [scope, id];
      final cached = (await txn.query(
        _table,
        where: _key,
        whereArgs: args,
      )).firstOrNull;
      if (cached == null) {
        if (editingVersion != null && editingVersion > 0) {
          changes['version'] = editingVersion;
          changes['conflict'] = jsonEncode(null);
        }
        await txn.insert(_table, {'scope': scope, 'id': id, ...changes});
        return;
      }
      if (editingVersion != null &&
          cached['mutation_id'] == null &&
          (cached['version'] as int) > editingVersion) {
        changes['version'] = editingVersion;
        changes['conflict'] = jsonEncode(_local(cached));
      }
      await txn.update(_table, changes, where: _key, whereArgs: args);
    });
  }

  /// Visible tasks include local overrides and completions in the three-day recovery window.
  Future<List<Map<String, dynamic>>> rows() async {
    final records = await db.query(
      _table,
      where: 'scope = ?',
      whereArgs: [scope],
      orderBy: 'id',
    );
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 3));
    return records.map(_local).where((task) {
      final completed = task['completed_at'] as String?;
      return completed == null || DateTime.parse(completed).isAfter(cutoff);
    }).toList();
  }

  /// Number of tasks eligible for replay, excluding unresolved conflicts.
  Future<int> pending() async => Sqflite.firstIntValue(
    await db.rawQuery('SELECT COUNT(*) FROM $_table WHERE $_pending', [scope]),
  )!;

  /// Each entry is {id, local, remote}. Both copies include id and version.
  /// A null remote means the server no longer has a visible task with this ID.
  Future<List<Map<String, dynamic>>> conflicts() async {
    final records = await db.query(
      _table,
      where: 'scope = ? AND conflict IS NOT NULL',
      whereArgs: [scope],
      orderBy: 'id',
    );
    return [
      for (final record in records)
        {
          'id': record['id'],
          'local': _local(record),
          'remote': jsonDecode(record['conflict'] as String),
        },
    ];
  }

  /// Keeping a local copy of an expired task creates a new ID at version zero.
  Future<void> resolve(String id, bool keepLocal) => db.transaction((
    txn,
  ) async {
    final args = [scope, id];
    final records = await txn.query(
      _table,
      columns: ['conflict'],
      where: '$_key AND conflict IS NOT NULL',
      whereArgs: args,
    );
    if (records.isEmpty) return;
    final remote = jsonDecode(records.single['conflict'] as String) as _Json?;
    if (remote == null && !keepLocal) {
      await txn.delete(_table, where: _key, whereArgs: args);
      return;
    }
    await txn.update(
      _table,
      {
        if (remote == null) 'id': const Uuid().v4(),
        if (!keepLocal) 'fields': jsonEncode(_fields(remote!)),
        'version': remote?['version'] ?? 0,
        'mutation_id': keepLocal ? const Uuid().v4() : null,
        'conflict': null,
      },
      where: _key,
      whereArgs: args,
    );
  });

  /// Serializes syncs for the same database and account. Reads and saves can
  /// still complete offline while a network request is outstanding.
  Future<void> sync(UsityApi api) async {
    final key = (db.path, scope);
    final previous = _syncs[key];
    final done = Completer<void>();
    _syncs[key] = done.future;
    try {
      await previous;
      await _sync(api);
    } finally {
      done.complete();
      if (identical(_syncs[key], done.future)) _syncs.remove(key);
    }
  }

  Future<void> _sync(UsityApi api) async {
    final dirty = await db.query(
      _table,
      columns: ['id'],
      where: _pending,
      whereArgs: [scope],
      orderBy: 'id',
    );
    for (final task in dirty) {
      await _replay(api, task['id'] as String);
    }
    final snapshot = await api.fetchTasks();
    // The GET is a full snapshot. Replace only clean rows so remote expiry
    // removes cached tasks and a save racing the GET survives.
    final batch = db.batch()
      ..delete(
        _table,
        where: 'scope = ? AND mutation_id IS NULL',
        whereArgs: [scope],
      );
    for (final task in snapshot) {
      final remote = _remote(task);
      batch.insert(_table, {
        'scope': scope,
        'id': remote['id'],
        'version': remote['version'],
        'fields': jsonEncode(_fields(remote)),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  /// Freeze an attempt before I/O. Later saves can change fields but a retry
  /// after a timeout or process death must resend the exact same operation.
  Future<_Json?> _attempt(String id) => db.transaction((txn) async {
    final args = [scope, id];
    final records = await txn.query(
      _table,
      where: '$_pending AND id = ?',
      whereArgs: args,
    );
    if (records.isEmpty) return null;
    final record = records.single;
    final frozen = record['attempt'] as String?;
    if (frozen != null) return jsonDecode(frozen) as _Json;
    final body = {
      ...jsonDecode(record['fields'] as String) as _Json,
      'expected_version': record['version'],
      'mutation_id': record['mutation_id'],
    };
    await txn.update(
      _table,
      {'attempt': jsonEncode(body)},
      where: _key,
      whereArgs: args,
    );
    return body;
  });

  Future<void> _replay(UsityApi api, String id) async {
    while (true) {
      final body = await _attempt(id);
      if (body == null) return;
      final _Json accepted;
      try {
        accepted = _remote(await api.putTask(id, body), expectedId: id);
      } on ApiException catch (error) {
        final detail = error.detail;
        if (error.status == 422) {
          // A definitively rejected payload may be corrected by a later save.
          await db.update(
            _table,
            {'attempt': null},
            where: _key,
            whereArgs: [scope, id],
          );
        }
        if (error.status != 409 ||
            detail is! Map ||
            !detail.containsKey('current')) {
          rethrow;
        }
        final current = detail['current'] as _Json?;
        await db.update(
          _table,
          {
            // SQL NULL means no conflict. JSON null records a remote expiry.
            'conflict': jsonEncode(
              current == null ? null : _remote(current, expectedId: id),
            ),
            'attempt': null,
          },
          where: _key,
          whereArgs: [scope, id],
        );
        return;
      }
      // Only the fields actually acknowledged can become clean. An edit made
      // during the PUT (or before a retry) uses this acknowledgement as its base.
      await db.rawUpdate(
        '''
        UPDATE $_table SET
          fields = CASE WHEN mutation_id = ? THEN ? ELSE fields END,
          mutation_id = CASE WHEN mutation_id = ? THEN NULL ELSE mutation_id END,
          version = ?, attempt = NULL
        WHERE $_key
      ''',
        [
          body['mutation_id'],
          jsonEncode(_fields(accepted)),
          body['mutation_id'],
          accepted['version'],
          scope,
          id,
        ],
      );
    }
  }
}
