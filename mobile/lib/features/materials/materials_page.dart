import 'package:flutter/material.dart';

import '../../design/catalog_card.dart';
import '../../domain/day_plan.dart';
import '../../domain/schedule.dart';
import '../../theme/tokens.dart';
import 'material_tile.dart';

class MaterialsPage extends StatefulWidget {
  const MaterialsPage({super.key, required this.plan});
  final DemoPlan plan;
  @override
  State<MaterialsPage> createState() => _MaterialsState();
}

class _MaterialsState extends State<MaterialsPage> {
  String search = '', subject = '';
  final field = TextEditingController();
  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Материалы', style: TypeScale.titleLg),
        backgroundColor: p.bg,
      ),
      body: ListenableBuilder(
        listenable: widget.plan,
        builder: (context, _) {
          final catalog = <String, List<(LessonOccurrence, StudyMaterial)>>{};
          for (final lesson in widget.plan.visibleLessons) {
            for (final m in lesson.materials) {
              (catalog[lesson.subject] ??= []).add((lesson, m));
            }
          }
          final needle = search.trim().toLowerCase();
          final filter = catalog.containsKey(subject) ? subject : '';
          final rows = <Widget>[];
          for (final group in catalog.entries) {
            if (filter.isNotEmpty && group.key != filter) continue;
            final matches = group.value.where(
              (r) => [
                r.$2.title,
                r.$2.category,
                group.key,
              ].any((s) => s.toLowerCase().contains(needle)),
            );
            if (matches.isEmpty) continue;
            rows.add(SectionCaption(group.key));
            for (final (lesson, item) in matches) {
              rows.add(MaterialTile(item: item, lesson: lesson));
            }
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Metrics.space5,
                  vertical: Metrics.space2,
                ),
                child: TextField(
                  controller: field,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Поиск по материалам',
                    filled: true,
                    fillColor: p.surfaceMuted,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: search.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить поиск',
                            onPressed: () {
                              field.clear();
                              setState(() => search = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Metrics.radiusMd),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (s) => setState(() => search = s),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Metrics.space5),
                child: Row(
                  children: [
                    for (final s in ['', ...catalog.keys])
                      Padding(
                        padding: const EdgeInsets.only(right: Metrics.space2),
                        child: ChoiceChip(
                          showCheckmark: false,
                          label: Text(s.isEmpty ? 'Все' : s),
                          selected: filter == s,
                          backgroundColor: p.surfaceMuted,
                          selectedColor: p.accent,
                          shape: const StadiumBorder(),
                          side: BorderSide.none,
                          onSelected: (_) => setState(() => subject = s),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? const Center(child: Text('Материалы не найдены'))
                    : ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Metrics.space5,
                        ),
                        children: rows,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
