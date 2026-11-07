import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../domain/day_plan.dart';
import '../../domain/schedule.dart';
import '../../theme/tokens.dart';
import '../../design/lesson_appearance.dart';
export '../../design/lesson_appearance.dart';
import '../materials/material_tile.dart';

class LessonDetail extends StatelessWidget {
  const LessonDetail({super.key, required this.lesson, required this.plan});
  final LessonOccurrence lesson;
  final DemoPlan plan;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.pop(context)),
      ),
      body: ListenableBuilder(
        listenable: plan,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(Metrics.space5),
          children: [
            Container(
              padding: const EdgeInsets.all(Metrics.space6),
              decoration: BoxDecoration(
                color: lesson.kind.tint(p),
                borderRadius: BorderRadius.circular(Metrics.radiusLg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(lesson.kind.icon, color: lesson.kind.ink(p)),
                      const SizedBox(width: Metrics.space2),
                      Text(
                        lesson.kind.label.toUpperCase(),
                        style: TypeScale.caption.copyWith(
                          color: lesson.kind.ink(p),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Metrics.space3),
                  Text(lesson.subject, style: TypeScale.titleLg),
                  const SizedBox(height: Metrics.space3),
                  Text(
                    '${lesson.startTime}–${lesson.endTime} · ${MaterialLocalizations.of(context).formatMediumDate(lesson.date)}',
                    style: TypeScale.time,
                  ),
                  Text(lesson.location, style: TypeScale.time),
                  Text(lesson.teacher, style: TypeScale.callout),
                  if (lesson.subgroup != null)
                    Text(
                      'Подгруппа ${lesson.subgroup}',
                      style: TypeScale.caption,
                    ),
                ],
              ),
            ),
            const SizedBox(height: Metrics.space6),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Домашнее задание', style: TypeScale.heading),
                if (lesson.homework.isNotEmpty)
                  Text(
                    '${lesson.homework.length - plan.remaining(lesson)} из ${lesson.homework.length} выполнено',
                    style: TypeScale.caption,
                  ),
              ],
            ),
            const SizedBox(height: Metrics.space2),
            if (lesson.homework.isEmpty) const Text('Заданий нет'),
            Material(
              color: p.surface,
              borderRadius: BorderRadius.circular(Metrics.space6),
              child: Column(
                children: [
                  for (final h in lesson.homework)
                    ListTile(
                      title: Text(
                        h.text,
                        style: TypeScale.body.copyWith(
                          color: plan.done(h) ? p.inkMuted : p.ink,
                          decoration: plan.done(h)
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      trailing: TaskCheck(
                        label: h.text,
                        done: plan.done(h),
                        personal: false,
                        onTap: () => plan.toggleHomework(h),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Metrics.space6),
            const Text('Материалы', style: TypeScale.heading),
            const SizedBox(height: Metrics.space2),
            if (lesson.materials.isEmpty) const Text('Материалов пока нет'),
            for (final item in lesson.materials)
              MaterialTile(item: item, lesson: lesson),
          ],
        ),
      ),
    );
  }
}
