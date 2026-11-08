import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/schedule.dart';
import 'usity_api.dart';

/// The database belongs to one account. The snapshot also varies by group and
/// selected subgroups so a changed profile cannot reopen an older timetable.
class ScheduleStore {
  ScheduleStore(this.db, this.scope, this.userId, this.groupId);
  final Database db;
  final String scope, userId, groupId;

  static Future<void> createTables(Database db) async {
    await db.execute(
      'CREATE TABLE schedules (scope TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    await db.execute(
      '''CREATE TABLE homework_outbox (
      group_id TEXT NOT NULL, assignment_id TEXT NOT NULL, version INTEGER NOT NULL,
      completed INTEGER NOT NULL, operation TEXT NOT NULL, PRIMARY KEY(group_id, assignment_id))''',
    );
  }

  Future<void> mark(HomeworkItem item, bool done) async {
    await db.insert('homework_outbox', {
      'group_id': groupId,
      'assignment_id': item.id,
      'version': item.version,
      'completed': done ? 1 : 0,
      'operation': const Uuid().v4(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> pending() async => Sqflite.firstIntValue(
    await db.rawQuery(
      'SELECT COUNT(*) FROM homework_outbox WHERE group_id = ?',
      [groupId],
    ),
  )!;

  Future<ScheduleSnapshot?> read() => db.transaction((tx) async {
    final rows = await tx.query(
      'schedules',
      where: 'scope = ?',
      whereArgs: [scope],
    );
    if (rows.isEmpty) return null;
    final raw =
        jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    final pending = await tx.query(
      'homework_outbox',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    final byId = {for (final p in pending) p['assignment_id']: p};
    for (final a in raw['assignments']) {
      final change = byId[a['id']];
      if (change != null && change['version'] == a['version']) {
        a['completed'] = change['completed'] == 1;
      }
    }
    return UsityApi.decodeSchedule(raw);
  });

  Future<void> sync(UsityApi api) async {
    final sent = await db.query(
      'homework_outbox',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    for (final row in sent) {
      final homework = HomeworkItem(
        text: '',
        id: row['assignment_id'] as String,
        version: row['version'] as int,
      );
      try {
        await api.complete(groupId, homework, completed: row['completed'] == 1);
      } on ApiException catch (e) {
        // The assignment was deleted, hidden or revised. Fetch authoritative state.
        if (e.status != 409 && e.status != 404) rethrow;
      }
    }
    final raw = await api.fetchSchedule(includeCompleted: true);
    if (raw['me']['user_id'] != userId || raw['me']['group_id'] != groupId) {
      throw const ApiException(
        403,
        'Изменилось членство в группе. Откройте профиль.',
      );
    }
    await db.transaction((tx) async {
      await tx.delete('schedules');
      await tx.insert('schedules', {
        'scope': scope,
        'payload': jsonEncode(raw),
      });
      // Retire only the exact toggles sent. A tap during the request remains queued.
      for (final row in sent) {
        await tx.delete(
          'homework_outbox',
          where: 'group_id = ? AND assignment_id = ? AND operation = ?',
          whereArgs: [groupId, row['assignment_id'], row['operation']],
        );
      }
    });
  }
}
