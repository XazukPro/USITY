import 'package:flutter/material.dart';

import '../../design/lesson_appearance.dart';
import '../../domain/day_plan.dart';
import '../../domain/group_setup.dart';
import '../../domain/schedule.dart';
import '../../theme/tokens.dart';

class SubjectForm extends StatefulWidget {
  const SubjectForm({super.key, required this.setup, this.original});
  final GroupSetup setup;
  final SetupSubject? original;
  @override
  State<SubjectForm> createState() => _SubjectState();
}

class _SubjectState extends State<SubjectForm> {
  late String name = widget.original?.name ?? '';
  late final kinds = {
    ...?widget.original?.kinds,
    if (widget.original == null) LessonKind.lecture,
  };
  late int groups = widget.original?.groups ?? 0;
  String? get problem {
    if (widget.setup.subjects.any(
      (s) =>
          s.id != widget.original?.id &&
          s.name.toLowerCase() == name.trim().toLowerCase(),
    )) {
      return 'Такой предмет уже есть';
    }
    if (widget.setup.slots.any(
      (slot) =>
          slot.subjectId == widget.original?.id &&
          (!kinds.contains(slot.kind) || (slot.subgroup ?? 0) > groups),
    )) {
      return 'Этот вид или подгруппа уже используются в расписании';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => _Sheet(
    title: widget.original == null ? 'Добавить предмет' : 'Изменить предмет',
    onSave: name.trim().isEmpty || kinds.isEmpty || problem != null
        ? null
        : () {
            final id = widget.original?.id ?? widget.setup.subjects.length;
            Navigator.pop(
              context,
              SetupSubject(id, name.trim(), Set.of(kinds), groups),
            );
          },
    children: [
      TextFormField(
        key: const Key('subject-name'),
        initialValue: name,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Название предмета',
          errorText: problem,
        ),
        onChanged: (v) => setState(() => name = v),
      ),
      const Text('Виды занятий', style: TypeScale.bodyStrong),
      Wrap(
        spacing: Metrics.space2,
        children: [
          for (final kind in LessonKind.values)
            FilterChip(
              label: Text(kind.label),
              selected: kinds.contains(kind),
              onSelected: (v) => setState(() {
                if (v) {
                  kinds.add(kind);
                } else {
                  kinds.remove(kind);
                }
              }),
            ),
        ],
      ),
      Row(
        children: [
          const Expanded(child: Text('Подгруппы')),
          IconButton(
            tooltip: 'Убрать подгруппу',
            onPressed: groups == 0 ? null : () => setState(() => groups--),
            icon: const Icon(Icons.remove),
          ),
          Text('$groups', style: TypeScale.time),
          IconButton(
            tooltip: 'Добавить подгруппу',
            onPressed: () => setState(() => groups++),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    ],
  );
}

class SlotForm extends StatefulWidget {
  const SlotForm({
    super.key,
    required this.setup,
    required this.weekday,
    this.original,
  });
  final GroupSetup setup;
  final int weekday;
  final SetupSlot? original;
  @override
  State<SlotForm> createState() => _SlotState();
}

class _SlotState extends State<SlotForm> {
  late SetupSubject subject = widget.original == null
      ? widget.setup.subjects.first
      : widget.setup.subject(widget.original!.subjectId);
  late LessonKind kind = widget.original?.kind ?? subject.kinds.first;
  late int start = widget.original?.start ?? 510,
      end = widget.original?.end ?? 605;
  late WeekPattern pattern = widget.setup.alternating
      ? (widget.original?.pattern ?? WeekPattern.all)
      : WeekPattern.all;
  late int group = widget.original?.subgroup ?? 0;
  late String teacher = widget.original?.teacher ?? '',
      room = widget.original?.room == 'Онлайн'
          ? ''
          : widget.original?.room ?? '';
  late bool online = widget.original?.room == 'Онлайн';
  SetupSlot get draft => SetupSlot(
    subjectId: subject.id,
    weekday: widget.weekday,
    kind: kind,
    start: start,
    end: end,
    teacher: teacher.trim(),
    room: online ? 'Онлайн' : room.trim(),
    pattern: pattern,
    subgroup: group == 0 ? null : group,
  );
  String? get error {
    if (start >= end) return 'Окончание должно быть позже начала';
    if (widget.setup.dates(draft).isEmpty) {
      return 'В семестре нет такого дня с выбранной чётностью';
    }
    return null;
  }

  Future<void> time(bool beginning) async {
    final minutes = beginning ? start : end;
    final v = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: w!,
      ),
    );
    if (v == null || !mounted) return;
    setState(() {
      if (beginning) {
        start = v.hour * 60 + v.minute;
      } else {
        end = v.hour * 60 + v.minute;
      }
    });
  }

  @override
  Widget build(BuildContext context) => _Sheet(
    title: widget.original == null ? 'Добавить пару' : 'Изменить пару',
    onSave:
        teacher.trim().isEmpty ||
            (!online && room.trim().isEmpty) ||
            error != null
        ? null
        : () => Navigator.pop(context, draft),
    children: [
      DropdownButtonFormField<int>(
        initialValue: subject.id,
        decoration: const InputDecoration(labelText: 'Предмет'),
        isExpanded: true,
        items: [
          for (final s in widget.setup.subjects)
            DropdownMenuItem(
              value: s.id,
              child: Text(s.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (id) => setState(() {
          subject = widget.setup.subject(id!);
          kind = subject.kinds.first;
          group = 0;
        }),
      ),
      Wrap(
        spacing: Metrics.space2,
        children: [
          for (final k in subject.kinds)
            ChoiceChip(
              label: Text(k.label),
              selected: k == kind,
              onSelected: (_) => setState(() => kind = k),
            ),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => time(true),
              child: Text('С ${clockTime(start)}'),
            ),
          ),
          const SizedBox(width: Metrics.space2),
          Expanded(
            child: OutlinedButton(
              onPressed: () => time(false),
              child: Text('До ${clockTime(end)}'),
            ),
          ),
        ],
      ),
      TextFormField(
        initialValue: teacher,
        key: const Key('slot-teacher'),
        decoration: const InputDecoration(labelText: 'ФИО преподавателя'),
        onChanged: (v) => setState(() => teacher = v),
      ),
      SwitchListTile(
        title: const Text('Онлайн'),
        contentPadding: EdgeInsets.zero,
        value: online,
        onChanged: (v) => setState(() => online = v),
      ),
      if (!online)
        TextFormField(
          initialValue: room,
          key: const Key('slot-room'),
          decoration: const InputDecoration(labelText: 'Аудитория'),
          onChanged: (v) => setState(() => room = v),
        ),
      if (subject.groups > 0)
        DropdownButtonFormField<int>(
          key: ValueKey(subject.id),
          initialValue: group,
          decoration: const InputDecoration(labelText: 'Подгруппа'),
          items: [
            const DropdownMenuItem(value: 0, child: Text('Весь предмет')),
            for (var n = 1; n <= subject.groups; n++)
              DropdownMenuItem(value: n, child: Text('Подгруппа $n')),
          ],
          onChanged: (v) => setState(() => group = v!),
        ),
      if (widget.setup.alternating)
        Wrap(
          spacing: Metrics.space2,
          children: [
            for (final w in WeekPattern.values)
              ChoiceChip(
                label: Text(w.label),
                selected: w == pattern,
                onSelected: (_) => setState(() => pattern = w),
              ),
          ],
        ),
      if (error != null)
        Text(
          error!,
          style: TypeScale.caption.copyWith(
            color: Palette.of(context).dangerInk,
          ),
        ),
    ],
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.title,
    required this.children,
    required this.onSave,
  });
  final String title;
  final List<Widget> children;
  final VoidCallback? onSave;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        Metrics.space5,
        0,
        Metrics.space5,
        MediaQuery.viewInsetsOf(context).bottom + Metrics.space5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: TypeScale.title),
          for (final child in children) ...[
            const SizedBox(height: Metrics.space3),
            child,
          ],
          const SizedBox(height: Metrics.space4),
          FilledButton(onPressed: onSave, child: const Text('Сохранить')),
        ],
      ),
    ),
  );
}
