import 'package:flutter/material.dart';

import '../../design/components.dart';
import '../../domain/day_plan.dart';
import '../../domain/schedule.dart';
import '../../theme/tokens.dart';
import 'lesson_detail.dart';

class DayAxis extends StatefulWidget {
  const DayAxis({
    super.key,
    required this.day,
    required this.now,
    required this.plan,
    required this.openLesson,
    required this.editTask,
  });
  final DateTime day, now;
  final DemoPlan plan;
  final ValueChanged<LessonOccurrence> openLesson;
  final ValueChanged<PersonalPlanTask> editTask;
  @override
  State<DayAxis> createState() => _AxisState();
}

class _AxisState extends State<DayAxis> {
  final keys = <GlobalKey>[];
  final preview = ValueNotifier<int>(0);
  late List<PlanGroup> groups;
  double? grabMinute;
  @override
  void dispose() {
    preview.dispose();
    super.dispose();
  }

  // Interpolate within actual rendered blocks and compressed gaps, including
  // groups whose text wraps on small screens. Coordinates follow scrolling.
  double minuteAt(double y) {
    double? bottom;
    int? end;
    for (var i = 0; i < groups.length; i++) {
      final box = keys[i].currentContext!.findRenderObject()! as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      final g = groups[i];
      if (y < top) {
        if (bottom == null || top <= bottom) return g.start + y - top;
        return end! + (y - bottom) / (top - bottom) * (g.start - end);
      }
      bottom = top + box.size.height;
      if (y <= bottom) {
        return g.start + (y - top) / box.size.height * (g.end - g.start);
      }
      end = g.end;
    }
    return end! + y - bottom!;
  }

  Widget draggable(PersonalPlanTask task, Widget child) {
    return Listener(
      onPointerDown: (event) {
        grabMinute = minuteAt(event.position.dy);
        preview.value = task.start!;
      },
      child: LongPressDraggable<PersonalPlanTask>(
        data: task,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        maxSimultaneousDrags: 1,
        onDragUpdate: (d) {
          if (grabMinute != null) {
            preview.value = snapStart(
              task.start! + minuteAt(d.globalPosition.dy) - grabMinute!,
              task.duration,
            );
          }
        },
        feedback: FractionalTranslation(
          translation: const Offset(-0.5, -1.2),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(Metrics.radiusMd),
            child: Padding(
              padding: const EdgeInsets.all(Metrics.space3),
              child: ValueListenableBuilder<int>(
                valueListenable: preview,
                builder: (_, v, _) => Text(
                  '${clockTime(v)}–${clockTime(v + task.duration)}',
                  style: TypeScale.time,
                ),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: .4, child: child),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    groups = groupEntries(widget.plan.entriesOn(widget.day));
    while (keys.length < groups.length) {
      keys.add(GlobalKey());
    }
    if (groups.isEmpty) return const Center(child: Text('Пар нет'));
    return DragTarget<PersonalPlanTask>(
      onAcceptWithDetails: (d) => widget.plan.move(d.data, preview.value),
      builder: (_, _, _) => SingleChildScrollView(
        key: PageStorageKey(widget.day),
        padding: const EdgeInsets.fromLTRB(
          Metrics.space5,
          Metrics.space2,
          Metrics.space5,
          96,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              Column(
                key: keys[i],
                children: [
                  for (var k = 0; k < groups[i].entries.length; k++)
                    _entry(p, groups[i], k),
                ],
              ),
              if (i + 1 < groups.length)
                _Gap(minutes: groups[i + 1].start - groups[i].end),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entry(Palette p, PlanGroup group, int i) {
    final entry = group.entries[i], lesson = entry.lesson, task = entry.task;
    final current = entry.isCurrent(widget.day, widget.now);
    final ink = lesson == null
        ? p.accentInk
        : current
        ? p.onFill
        : lesson.kind.ink(p);
    final fill = lesson == null
        ? p.surfaceMuted
        : current
        ? lesson.kind.fill(p)
        : lesson.kind.tint(p);
    final count = lesson == null ? 0 : widget.plan.remaining(lesson);
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: Metrics.space2),
      child: lesson != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(lesson.subject, style: TypeScale.heading),
                Text(
                  [
                    lesson.teacher,
                    if (lesson.subgroup != null) 'подгруппа ${lesson.subgroup}',
                  ].join(' · '),
                  style: TypeScale.callout.copyWith(color: p.inkMuted),
                ),
                const SizedBox(height: Metrics.space2),
                Wrap(
                  spacing: Metrics.space2,
                  runSpacing: Metrics.space1,
                  children: [
                    Tag(
                      lesson.location,
                      fill: lesson.kind.tint(p),
                      ink: lesson.kind.ink(p),
                      mono: true,
                    ),
                    if (count > 0)
                      Tag(
                        'ДЗ · $count',
                        fill: p.accentTint,
                        ink: p.accentInk,
                        icon: Icons.menu_book_outlined,
                      ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${clockTime(entry.start)}–${clockTime(entry.end)} · ${formatGap(task!.duration)}',
                        style: TypeScale.caption.copyWith(color: p.inkMuted),
                      ),
                      Text(task.title, style: TypeScale.bodyStrong),
                    ],
                  ),
                ),
                TaskCheck(
                  label: 'Выполнить: ${task.title}',
                  done: false,
                  onTap: () => widget.plan.toggleTask(task),
                ),
              ],
            ),
    );
    final row = InkWell(
      onTap: () =>
          lesson != null ? widget.openLesson(lesson) : widget.editTask(task!),
      child: IntrinsicHeight(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: group.entries.length > 1
                ? 88
                : lesson != null
                ? 100
                : 76,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: Metrics.hitMin,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Metrics.space2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (i == 0)
                        FittedBox(
                          child: Text(
                            clockTime(group.start),
                            style: TypeScale.time,
                          ),
                        ),
                      const Spacer(),
                      if (i == group.entries.length - 1)
                        FittedBox(
                          child: Text(
                            clockTime(group.end),
                            style: TypeScale.code.copyWith(color: p.inkMuted),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Metrics.space4),
              SizedBox(
                width: Metrics.space10,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: i == 0 ? 0 : -12,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fill,
                          borderRadius: BorderRadius.circular(
                            Metrics.radiusFull,
                          ),
                          boxShadow: i == 0
                              ? null
                              : [BoxShadow(color: p.bg, spreadRadius: 4)],
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(top: Metrics.space4),
                            child: Icon(
                              lesson?.kind.icon ?? Icons.checklist,
                              color: ink,
                              size: Metrics.space5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Metrics.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    content,
                    if (i + 1 < group.entries.length)
                      Text(
                        'Задачи пересекаются',
                        style: TypeScale.caption.copyWith(color: p.dangerInk),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return task == null ? row : draggable(task, row);
  }
}

class _Gap extends StatelessWidget {
  const _Gap({required this.minutes});
  final int minutes;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: Metrics.hitMin + Metrics.space4),
          SizedBox(
            width: Metrics.space10,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < 4; i++)
                  Container(color: p.borderStrong, width: 2, height: 5),
              ],
            ),
          ),
          const SizedBox(width: Metrics.space4),
          Text(
            formatGap(minutes),
            style: TypeScale.caption.copyWith(color: p.inkMuted),
          ),
        ],
      ),
    );
  }
}
