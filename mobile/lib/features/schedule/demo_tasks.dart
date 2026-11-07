import 'package:flutter/material.dart';

import '../../domain/day_plan.dart';
import '../../design/components.dart';
import '../../theme/tokens.dart';
import 'task_sheet.dart';

/// Access to personal tasks without a scheduled time during the mock stage.
class DemoTasks extends StatelessWidget {
  const DemoTasks({super.key, required this.plan});
  final DemoPlan plan;
  @override
  Widget build(BuildContext context) {
    Future<void> edit([PersonalPlanTask? task]) async {
      final next = await editPlanTask(context, DateTime.now(), task: task);
      if (context.mounted && next != null) plan.save(next, previous: task);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Задачи')),
      body: ListenableBuilder(
        listenable: plan,
        builder: (context, _) {
          final now = DateTime.now();
          final tasks =
              plan.tasks
                  .where(
                    (t) =>
                        t.completed == null ||
                        now.difference(t.completed!) < const Duration(days: 3),
                  )
                  .toList()
                ..sort((a, b) {
                  if ((a.start == null) != (b.start == null)) {
                    return a.start == null ? 1 : -1;
                  }
                  final byDate = a.day.compareTo(b.day);
                  return byDate == 0
                      ? (a.start ?? 0).compareTo(b.start ?? 0)
                      : byDate;
                });
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              Metrics.space5,
              0,
              Metrics.space5,
              96,
            ),
            children: [
              for (final t in tasks)
                ListTile(
                  onTap: () => edit(t),
                  title: Text(
                    t.title,
                    style: TypeScale.body.copyWith(
                      decoration: t.completed == null
                          ? null
                          : TextDecoration.lineThrough,
                    ),
                  ),
                  subtitle: Text(
                    t.start == null
                        ? 'Без времени'
                        : '${MaterialLocalizations.of(context).formatMediumDate(t.day)} · ${clockTime(t.start!)}',
                  ),
                  trailing: TaskCheck(
                    label: t.title,
                    done: t.completed != null,
                    onTap: () => plan.toggleTask(t),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        tooltip: 'Новая задача',
        onPressed: edit,
        child: const Icon(Icons.add),
      ),
    );
  }
}
