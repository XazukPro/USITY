import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class DayStrip extends StatelessWidget {
  const DayStrip({super.key, required this.selected, required this.onSelect});
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;
  static const names = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      children: List.generate(7, (i) {
        final day = DateTime(
          selected.year,
          selected.month,
          selected.day - selected.weekday + 1 + i,
        );
        final active = selected.weekday == i + 1;
        return Expanded(
          child: Semantics(
            selected: active,
            button: true,
            child: InkWell(
              key: Key('day-${day.toIso8601String().substring(0, 10)}'),
              borderRadius: BorderRadius.circular(Metrics.space5),
              onTap: () => onSelect(day),
              child: Ink(
                decoration: BoxDecoration(
                  color: active ? p.accent : p.bg,
                  borderRadius: BorderRadius.circular(Metrics.space5),
                ),
                padding: const EdgeInsets.symmetric(vertical: Metrics.space3),
                child: Column(
                  children: [
                    Text(
                      names[i],
                      style: TypeScale.caption.copyWith(
                        color: active ? p.onFill : p.inkMuted,
                      ),
                    ),
                    Text(
                      '${day.day}',
                      style: TypeScale.heading.copyWith(
                        color: active ? p.onFill : p.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(
    this.label, {
    super.key,
    required this.fill,
    required this.ink,
    this.icon,
    this.mono = false,
  });
  final String label;
  final Color fill, ink;
  final IconData? icon;
  final bool mono;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(Metrics.radiusFull),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Metrics.space3,
        vertical: Metrics.space1,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: Metrics.space4, color: ink),
            const SizedBox(width: Metrics.space1),
          ],
          Text(
            label,
            style: (mono ? TypeScale.code : TypeScale.caption).copyWith(
              color: ink,
            ),
          ),
        ],
      ),
    ),
  );
}

class TaskCheck extends StatelessWidget {
  const TaskCheck({
    super.key,
    required this.label,
    required this.done,
    required this.onTap,
    this.personal = true,
  });
  final String label;
  final bool done, personal;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      checked: done,
      label: label,
      child: InkResponse(
        onTap: onTap,
        child: SizedBox.square(
          dimension: Metrics.hitMin,
          child: Center(
            child: Container(
              width: personal ? 28 : 26,
              height: personal ? 28 : 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  personal ? Metrics.radiusFull : Metrics.radiusXs,
                ),
                border: Border.all(color: p.accentInk, width: 2),
                color: done ? p.accentInk : null,
              ),
              child: done
                  ? Icon(Icons.check, size: Metrics.space5, color: p.surface)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class TimelineEntry extends StatelessWidget {
  const TimelineEntry({
    super.key,
    required this.start,
    required this.end,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.content,
    this.minimumHeight = 84,
  });
  final String start, end;
  final IconData icon;
  final Color fill, ink;
  final Widget content;
  final double minimumHeight;
  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minimumHeight),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: Metrics.hitMin,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Metrics.space2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(start, maxLines: 1, style: TypeScale.time),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      end,
                      style: TypeScale.code.copyWith(
                        color: Palette.of(context).inkMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Metrics.space4),
          Container(
            width: Metrics.space10,
            alignment: Alignment.topCenter,
            padding: const EdgeInsets.only(top: Metrics.space3),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(Metrics.radiusFull),
            ),
            child: Icon(icon, color: ink, size: Metrics.space5),
          ),
          const SizedBox(width: Metrics.space4),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: content),
          ),
        ],
      ),
    ),
  );
}
