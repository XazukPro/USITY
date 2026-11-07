import 'package:flutter/material.dart';

import '../../domain/day_plan.dart';
import '../../theme/tokens.dart';

Future<PersonalPlanTask?> editPlanTask(
  BuildContext context,
  DateTime day, {
  PersonalPlanTask? task,
}) => showModalBottomSheet<PersonalPlanTask>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _Editor(day: day, task: task),
);

class _Editor extends StatefulWidget {
  const _Editor({required this.day, this.task});
  final DateTime day;
  final PersonalPlanTask? task;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final text = TextEditingController(text: widget.task?.title ?? '');
  late DateTime day = widget.task?.day ?? widget.day;
  late int? start = widget.task == null ? 750 : widget.task!.start;
  late int duration = widget.task?.duration ?? 30;
  late bool remind = widget.task?.remind ?? false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> date() async {
    final d = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (mounted && d != null) setState(() => day = d);
  }

  Future<void> time() async {
    final initial = start ?? 750;
    final pick = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: w!,
      ),
    );
    if (mounted && pick != null) {
      setState(
        () => start = snapStart((pick.hour * 60 + pick.minute).toDouble(), 5),
      );
    }
  }

  Future<void> custom() async {
    var value = duration.toString();
    final n = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) {
          final minutes = int.tryParse(value);
          final valid =
              minutes != null &&
              minutes >= 5 &&
              minutes <= 1440 &&
              minutes % 5 == 0;
          return AlertDialog(
            title: const Text('Продолжительность'),
            content: TextFormField(
              initialValue: value,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Минуты, шаг 5'),
              onChanged: (s) => update(() => value = s),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: valid ? () => Navigator.pop(c, minutes) : null,
                child: const Text('Готово'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted && n != null) setState(() => duration = n);
  }

  @override
  Widget build(BuildContext context) {
    final fits = start == null || start! + duration <= 1440;
    final p = Palette.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          Metrics.space5,
          0,
          Metrics.space5,
          MediaQuery.viewInsetsOf(context).bottom + Metrics.space6,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.task == null ? 'Новая задача' : 'Личная задача',
              style: TypeScale.title,
            ),
            const SizedBox(height: Metrics.space4),
            TextField(
              controller: text,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Что нужно сделать',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Дата'),
              trailing: Text(
                MaterialLocalizations.of(context).formatMediumDate(day),
              ),
              onTap: date,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Время'),
              onTap: time,
              trailing: Text(
                start == null ? 'Без времени' : clockTime(start!),
                style: TypeScale.time,
              ),
            ),
            if (start != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => start = null),
                  child: const Text('Без времени'),
                ),
              ),
              const Text('Продолжительность', style: TypeScale.caption),
              Wrap(
                spacing: Metrics.space2,
                children: [
                  for (final n in [15, 30, 60])
                    ChoiceChip(
                      label: Text(formatGap(n)),
                      selected: n == duration,
                      onSelected: (_) => setState(() => duration = n),
                    ),
                  ChoiceChip(
                    label: Text(
                      [15, 30, 60].contains(duration)
                          ? 'Своё'
                          : formatGap(duration),
                    ),
                    selected: ![15, 30, 60].contains(duration),
                    onSelected: (_) => custom(),
                  ),
                ],
              ),
              if (fits)
                Text(
                  '${clockTime(start!)} – ${clockTime(start! + duration)}',
                  style: TypeScale.code,
                )
              else
                Text(
                  'Выберите интервал в пределах дня',
                  style: TypeScale.caption.copyWith(color: p.dangerInk),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Напомнить за 10 минут'),
                value: remind,
                onChanged: (v) => setState(() => remind = v),
              ),
            ],
            const SizedBox(height: Metrics.space4),
            FilledButton(
              onPressed: text.text.trim().isEmpty || !fits
                  ? null
                  : () => Navigator.pop(
                      context,
                      PersonalPlanTask(
                        text.text.trim(),
                        day,
                        start,
                        duration,
                        remind: start != null && remind,
                      ),
                    ),
              child: Text(widget.task == null ? 'Добавить' : 'Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}
