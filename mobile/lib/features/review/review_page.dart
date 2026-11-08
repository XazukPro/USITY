import 'package:flutter/material.dart';

import '../../data/usity_api.dart';
import '../../domain/schedule.dart';

String agentLabel(String id) => switch (id) {
  'homework_detection' => 'Новое ДЗ',
  'schedule_binding' => 'Привязка к расписанию',
  'duplicate_conflict' => 'Дубли и противоречия',
  'material_proposal' => 'Учебные материалы',
  'assignment_change' => 'Изменения и отмены',
  _ => id,
};

class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.api,
    required this.groupId,
    required this.lessons,
  });
  final UsityApi api;
  final String groupId;
  final List<LessonOccurrence> lessons;
  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late Future<List<ReviewDraft>> pending = widget.api.loadReview(
    widget.groupId,
  );
  void refresh() => setState(() {
    pending = widget.api.loadReview(widget.groupId);
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Проверка ДЗ'),
      actions: [
        IconButton(
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
          tooltip: 'Обновить',
        ),
      ],
    ),
    body: FutureBuilder<List<ReviewDraft>>(
      future: pending,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${snapshot.error}'),
            ),
          );
        }
        final drafts = snapshot.data!;
        if (drafts.isEmpty) return const Center(child: Text('Всё проверено'));
        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: drafts.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final draft = drafts[index];
            return Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(18),
                title: Text(
                  draft.text,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Новое ДЗ · требуется проверка'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReviewEditor(
                        api: widget.api,
                        groupId: widget.groupId,
                        draft: draft,
                        lessons: widget.lessons,
                      ),
                    ),
                  );
                  if (mounted) refresh();
                },
              ),
            );
          },
        );
      },
    ),
  );
}

class ReviewEditor extends StatefulWidget {
  const ReviewEditor({
    super.key,
    required this.api,
    required this.groupId,
    required this.draft,
    required this.lessons,
    this.now,
  });
  final DateTime Function()? now;
  final UsityApi api;
  final String groupId;
  final ReviewDraft draft;
  final List<LessonOccurrence> lessons;
  @override
  State<ReviewEditor> createState() => _ReviewEditorState();
}

class _ReviewEditorState extends State<ReviewEditor> {
  late final text = TextEditingController(text: widget.draft.text);
  String? lessonId;
  String? error;
  bool busy = false;
  bool conflict = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit(bool approve) async {
    if (busy || conflict) return;
    if (approve && !futureLessons().any((lesson) => lesson.id == lessonId)) {
      setState(() {
        lessonId = null;
        error = 'Выберите будущую пару.';
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.decide(
        groupId: widget.groupId,
        draftId: widget.draft.id,
        version: widget.draft.version,
        approve: approve,
        text: approve ? text.text.trim() : null,
        lessonId: approve ? lessonId : null,
      );
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          error = e.message;
          conflict = e.status == 409;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Не удалось сохранить решение. Обновите очередь.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<LessonOccurrence> futureLessons() {
    final now = widget.now?.call() ?? DateTime.now();
    return widget.lessons.where((lesson) {
      final time = lesson.startTime.split(':');
      return DateTime(
        lesson.date.year,
        lesson.date.month,
        lesson.date.day,
        int.parse(time[0]),
        int.parse(time[1]),
      ).isAfter(now);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final available = futureLessons();
    if (!available.any((lesson) => lesson.id == lessonId)) lessonId = null;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Новое домашнее задание')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Сообщения из учебной темы',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            if (widget.draft.agents.isNotEmpty) ...[
              Text(
                '${widget.draft.agents.length} AI-агентов',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final agent in widget.draft.agents)
                    Chip(
                      label: Text(agentLabel(agent.id)),
                      avatar: Icon(
                        agent.status == 'error'
                            ? Icons.error_outline
                            : Icons.auto_awesome_outlined,
                        size: 18,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
            ],
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final message in widget.draft.messages)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(message),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: text,
              minLines: 3,
              maxLines: 8,
              maxLength: 20000,
              enabled: !busy && !conflict,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Текст ДЗ',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey(lessonId),
              initialValue: lessonId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'К какой паре',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final lesson in available)
                  DropdownMenuItem(
                    value: lesson.id,
                    child: Text(
                      '${lesson.subject} · ${lesson.date.day}.${lesson.date.month} · ${lesson.startTime}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: busy || conflict
                  ? null
                  : (value) => setState(() => lessonId = value),
            ),
            if (available.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Нет будущих пар. Сначала добавьте занятие в расписание.',
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            if (conflict)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Вернуться к очереди'),
              )
            else ...[
              FilledButton(
                onPressed: busy || lessonId == null || text.text.trim().isEmpty
                    ? null
                    : () => submit(true),
                child: Text(busy ? 'Сохраняем…' : 'Опубликовать'),
              ),
              TextButton(
                onPressed: busy ? null : () => submit(false),
                child: const Text('Отклонить'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
