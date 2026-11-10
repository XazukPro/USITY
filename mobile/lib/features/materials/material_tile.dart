import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/schedule.dart';
import '../../design/catalog_card.dart';
import '../../design/lesson_appearance.dart';
import '../../theme/tokens.dart';

class MaterialTile extends StatelessWidget {
  const MaterialTile({super.key, required this.item, required this.lesson});
  final StudyMaterial item;
  final LessonOccurrence lesson;

  Future<void> open(BuildContext context) async {
    String? error;
    try {
      switch (item.kind) {
        case ResourceKind.note:
          await showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Metrics.space5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title, style: TypeScale.title),
                    const SizedBox(height: Metrics.space4),
                    SelectableText(item.value),
                  ],
                ),
              ),
            ),
          );
        case ResourceKind.link:
          final uri = Uri.parse(item.value);
          if (uri.scheme != 'https' ||
              !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            error = 'Не удалось открыть ссылку';
          }
        case ResourceKind.pdf:
          final data = await rootBundle.load(item.value);
          final temp = await getTemporaryDirectory();
          final dir = await Directory('${temp.path}/usity-materials')
              .create(recursive: true);
          final file = File('${dir.path}/${item.value.split('/').last}');
          await file.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
          final result = await OpenFilex.open(
            file.path,
            type: 'application/pdf',
          );
          if (result.type != ResultType.done) {
            error = result.type == ResultType.noAppToOpen
                ? 'На устройстве нет просмотрщика PDF'
                : 'Не удалось открыть PDF';
          }
      }
    } on Exception {
      error = 'Не удалось открыть материал';
    }
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final type = switch (item.kind) {
      ResourceKind.note => 'Заметка',
      ResourceKind.link => 'Ссылка',
      ResourceKind.pdf => 'PDF',
    };
    return CatalogCard(
      title: item.title,
      subtitle:
          '$type · ${item.category} · ${MaterialLocalizations.of(context).formatShortDate(lesson.date)}',
      icon: item.kind == ResourceKind.link
          ? Icons.link
          : Icons.description_outlined,
      iconColor: lesson.kind.ink(p),
      tint: lesson.kind.tint(p),
      trailing: Icon(Icons.chevron_right, color: p.inkMuted),
      onTap: () => open(context),
    );
  }
}
