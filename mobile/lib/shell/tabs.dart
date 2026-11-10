import 'package:flutter/material.dart';

import '../theme/tokens.dart';

const tabLabels = ['Расписание', 'Задачи', 'Материалы', 'Настройки'];
const _icons = [
  Icons.calendar_today_outlined,
  Icons.checklist_rounded,
  Icons.folder_outlined,
  Icons.tune_rounded,
];

class UsityTabs extends StatelessWidget {
  const UsityTabs({
    super.key,
    required this.index,
    required this.onSelect,
    this.pending = 0,
  });
  final int index;
  final ValueChanged<int> onSelect;
  final int pending;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Material(
      color: p.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(Metrics.radiusLg),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Metrics.space3,
            vertical: Metrics.space2,
          ),
          child: Row(
            children: [
              for (var i = 0; i < tabLabels.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    onTap: () => onSelect(i),
                    selected: i == index,
                    label: i == 3 && pending > 0
                        ? 'Настройки, на проверке: $pending'
                        : tabLabels[i],
                    child: ExcludeSemantics(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(Metrics.space5),
                        onTap: () => onSelect(i),
                        child: Ink(
                          decoration: BoxDecoration(
                            color: i == index ? p.accentTint : p.surface,
                            borderRadius: BorderRadius.circular(Metrics.space5),
                          ),
                          padding: const EdgeInsets.symmetric(
                            vertical: Metrics.space2,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Badge(
                                isLabelVisible: i == 3 && pending > 0,
                                backgroundColor: p.danger,
                                textColor: p.onFill,
                                label: Text('$pending'),
                                child: Icon(
                                  _icons[i],
                                  color: i == index ? p.accentInk : p.inkMuted,
                                ),
                              ),
                              const SizedBox(height: Metrics.space1),
                              Text(
                                tabLabels[i],
                                textAlign: TextAlign.center,
                                style: TypeScale.overline.copyWith(
                                  letterSpacing: 0,
                                  color: i == index ? p.accentInk : p.inkMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
