import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/day_plan.dart';
import '../domain/schedule.dart';
import 'schedule_store.dart';
import 'task_store.dart';
import 'usity_api.dart';

class OfflinePlan extends DemoPlan {
  OfflinePlan(this.tasksStore, this.schedule, this.onSaved, this.onError)
    : super([], []);
  final TaskStore tasksStore;
  final ScheduleStore schedule;
  final VoidCallback onSaved;
  final ValueChanged<String> onError;
  ScheduleSnapshot? snapshot;
  List<Map<String, dynamic>> conflicts = [];
  int pending = 0;
  int _read = 0;
  bool _closed = false;
  Future<void> _writes = Future.value();

  static Future<OfflinePlan> open(
    UsityApi api,
    Map<String, dynamic> profile,
    VoidCallback onSaved,
    ValueChanged<String> onError,
  ) async {
    final user = profile['user_id'] as String,
        group = profile['group_id'] as String;
    final account = const Uuid().v5(
      Namespace.url.value,
      jsonEncode([api.base.toString(), user]),
    );
    final db = await openDatabase(
      '${await getDatabasesPath()}/usity-$account.db',
      version: 1,
      onCreate: (db, _) async {
        await ScheduleStore.createTables(db);
        await TaskStore.createTables(db);
      },
    );
    final choices = Map<String, dynamic>.from(profile['choices'] as Map? ?? {});
    final keys = choices.keys.toList()..sort();
    final scope = jsonEncode([
      group,
      profile['role'],
      {for (final k in keys) k: choices[k]},
    ]);
    return OfflinePlan(
      TaskStore(db, user),
      ScheduleStore(db, scope, user, group),
      onSaved,
      onError,
    );
  }

  @override
  Iterable<LessonOccurrence> get visibleLessons => lessons;

  @override
  bool done(HomeworkItem item) => item.completed;

  Future<void> reload() async {
    final revision = ++_read;
    final next = await schedule.read();
    final local = await tasksStore.rows();
    final changes = await tasksStore.conflicts();
    final queued = await tasksStore.pending() + await schedule.pending();
    if (_closed || revision != _read) return;
    snapshot = next;
    lessons
      ..clear()
      ..addAll(next?.lessons ?? []);
    tasks
      ..clear()
      ..addAll(
        local.map(
          (row) =>
              PersonalPlanTask(
                  row['title'] as String,
                  DateTime.parse(row['day'] as String),
                  row['start'] as int?,
                  row['duration'] as int,
                  id: row['id'] as String,
                  version: row['version'] as int,
                  remind: row['remind'] == true,
                )
                ..completed = DateTime.tryParse(
                  row['completed_at'] as String? ?? '',
                )?.toLocal(),
        ),
      );
    conflicts = changes;
    pending = queued;
    notifyListeners();
  }

  Future<void> sync(UsityApi api) async {
    await _writes;
    if (_closed) return;
    await schedule.sync(api);
    if (_closed) return;
    await tasksStore.sync(api);
    if (!_closed) await reload();
  }

  void _persist(Future<void> Function() write) {
    _writes = _writes.then((_) async {
      try {
        await write();
        if (_closed) return;
        await reload();
        if (!_closed) onSaved();
      } on Exception {
        if (!_closed) onError('Не удалось сохранить изменение на устройстве.');
      }
    });
  }

  void resolve(String id, bool local) =>
      _persist(() => tasksStore.resolve(id, local));

  @override
  void toggleHomework(HomeworkItem item) {
    _persist(() => schedule.mark(item, !item.completed));
  }

  void _writeTask(
    PersonalPlanTask task, {
    int? start,
    DateTime? completed,
    int? editingVersion,
  }) {
    final id = task.id ??= const Uuid().v4();
    final fields = {
      'title': task.title,
      'day': task.day.toIso8601String().substring(0, 10),
      'start': start,
      'duration': task.duration,
      'remind': task.remind,
      'completed_at': completed?.toUtc().toIso8601String(),
    };
    _persist(
      () => tasksStore.save(
        id,
        fields,
        editingVersion: editingVersion ?? task.version,
      ),
    );
  }

  @override
  void save(PersonalPlanTask next, {PersonalPlanTask? previous}) {
    next.id ??= previous?.id;
    _writeTask(
      next,
      start: next.start,
      completed: previous?.completed,
      editingVersion: previous?.version,
    );
  }

  @override
  void toggleTask(PersonalPlanTask task) => _writeTask(
    task,
    start: task.start,
    completed: task.completed == null ? DateTime.now() : null,
  );

  @override
  void move(PersonalPlanTask task, int start) => _writeTask(
    task,
    start: snapStart(start.toDouble(), task.duration),
    completed: task.completed,
  );

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
