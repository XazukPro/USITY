import 'package:flutter/material.dart';

import '../../data/usity_api.dart';
import '../../domain/schedule.dart';
import '../../theme/tokens.dart';

String agentLabel(String id) => switch (id) {
  'homework_detection' => 'Поиск ДЗ',
  'schedule_binding' => 'Привязка к расписанию',
  'duplicate_conflict' => 'Дубли и противоречия',
  'material_proposal' => 'Учебные материалы',
  'assignment_change' => 'Изменения и отмены',
  _ => id,
};

String _fieldLabel(String field) => switch (field) {
  'text' => 'Текст задания',
  'subject' => 'Предмет',
  'subject_id' => 'Предмет (ID)',
  'subject_ids' => 'Предметы (ID)',
  'candidate_subject_ids' => 'Варианты предмета',
  'lesson_id' => 'Пара (ID)',
  'due_at' || 'deadline' => 'Срок',
  'subgroups' || 'subgroup_ids' => 'Подгруппы',
  'kind' => 'Действие',
  'assignment_id' => 'Задание (ID)',
  'assignment_ids' => 'Задания (ID)',
  'attachment_id' => 'Вложение (ID)',
  'category_id' => 'Категория (ID)',
  'new_text' => 'Новый текст',
  'new_due_date' => 'Новый срок',
  'uncertain' => 'Требует уточнения',
  'model_uncertain' => 'Модель не уверена',
  'subject_not_found' => 'Предмет не найден',
  'subject_ambiguous' => 'Предмет неоднозначен',
  'lesson_not_found' => 'Пара не найдена',
  'subgroup_not_found' => 'Подгруппа не найдена',
  'deadline_missing' => 'Срок не указан',
  'deadline_in_past' => 'Срок уже прошёл',
  'past_deadline' || 'past_due_date' => 'Срок уже прошёл',
  'subject_missing_or_ambiguous' => 'Предмет не указан или неоднозначен',
  'multiple_matching_lessons' => 'Подходят несколько пар',
  'no_future_matching_lesson' => 'Нет подходящей будущей пары',
  'cancel_with_new_values' => 'В отмене указаны новые данные задания',
  _ => field.replaceAll('_', ' '),
};

String _deadline(DateTime value) {
  final date = value.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${pad(date.day)}.${pad(date.month)}.${date.year}, ${pad(date.hour)}:${pad(date.minute)}';
}

String _detailValue(Object? value, [String? field]) {
  if (value == null) return 'Не указано';
  if (value is bool) return value ? 'Да' : 'Нет';
  if (value is List) {
    return value.isEmpty
        ? 'Не указано'
        : value.map((v) => _detailValue(v, field)).join(', ');
  }
  if (value is Map) {
    return value.entries
        .map(
          (e) =>
              '${_fieldLabel(e.key.toString())}: ${_detailValue(e.value, e.key.toString())}',
        )
        .join('\n');
  }
  if (value is String) {
    if (field == 'due_at' || field == 'new_due_date') {
      final date = DateTime.tryParse(value);
      if (date != null) return _deadline(date);
    }
    return switch (value) {
      'cancel' => 'Отмена задания',
      'update' => 'Изменение задания',
      'new_homework' => 'Новое ДЗ',
      'incomplete_homework' => 'Неполное ДЗ · ожидаем продолжение',
      'material' => 'Учебный материал',
      'assignment_change' => 'Изменение или отмена задания',
      'schedule_binding' => 'Предложение пары',
      'duplicate_conflict' => 'Возможный дубль',
      _ => value,
    };
  }
  return value.toString();
}

String _draftStatus(ReviewDraft draft) {
  if (!draft.canPublishHomework) {
    return 'Информация для проверки · без нового ДЗ';
  }
  return switch (draft.summary?.state) {
    'waiting' => 'Ожидаем продолжение',
    'ready' => 'ДЗ готово к проверке',
    'needs_review' => 'Нужно уточнение',
    _ => 'Новое ДЗ · требуется проверка',
  };
}

class _SummaryInfo extends StatelessWidget {
  const _SummaryInfo(this.draft);
  final ReviewDraft draft;

  @override
  Widget build(BuildContext context) {
    final summary = draft.summary!;
    final p = Palette.of(context);
    final warning =
        summary.state == 'waiting' || summary.state == 'needs_review';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: warning ? p.warningTint : p.accentTint,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _draftStatus(draft),
            style: TypeScale.bodyStrong.copyWith(
              color: warning ? p.warningInk : p.accentInk,
            ),
          ),
          const SizedBox(height: 8),
          if (summary.state == 'waiting' && draft.canPublishHomework)
            const Text(
              'Дождитесь продолжения в учебной теме или заполните текст ДЗ и выберите будущую пару вручную.',
            ),
          if (!draft.canPublishHomework)
            const Text(
              'Публикация нового ДЗ недоступна. Проверьте отдельные предложения ниже.',
            ),
          const SizedBox(height: 8),
          Text('Предмет: ${summary.subject ?? 'Не указан'}'),
          Text(
            'Срок: ${summary.dueAt == null ? 'Не указан' : _deadline(summary.dueAt!)}',
            style: TypeScale.time,
          ),
          if (summary.subgroups.isNotEmpty)
            Text('Предложенные подгруппы: ${summary.subgroups.join(', ')}'),
          if (summary.missingFields.isNotEmpty)
            Text(
              'Нужно уточнить: ${summary.missingFields.map(_fieldLabel).join(', ')}',
            ),
        ],
      ),
    );
  }
}

class _AgentDetails extends StatelessWidget {
  const _AgentDetails(
    this.agent, {
    required this.enabled,
    required this.onDecision,
    required this.draft,
  });
  final ReviewAgentRun agent;
  final bool enabled;
  final ReviewDraft draft;
  final void Function(ReviewProposal, int, bool) onDecision;

  String? approveLabel(ReviewProposal proposal) => switch (proposal.type) {
    'material'
        when draft.materialUrl(proposal) != null &&
            (proposal.fields['assignment_ids'] == null ||
                proposal.fields['assignment_ids'] is List &&
                    (proposal.fields['assignment_ids'] as List).isEmpty) =>
      'Опубликовать материал',
    'duplicate_conflict' => 'Отметить просмотренным',
    'assignment_change' when proposal.fields['kind'] == 'update' =>
      'Проверить изменение',
    'assignment_change' when proposal.fields['kind'] == 'cancel' =>
      'Подтвердить отмену ДЗ',
    _ => null,
  };

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(agentLabel(agent.id)),
    subtitle: Text(switch (agent.status) {
      'proposed' => 'Есть предложения для проверки',
      'not_found' => 'Предложений нет',
      'error' => 'Ошибка обработки',
      _ => 'Статус неизвестен',
    }),
    children: [
      for (final (position, proposal) in agent.proposals.indexed)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Palette.of(context).surfaceMuted,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_detailValue(proposal.type), style: TypeScale.bodyStrong),
              for (final field in proposal.fields.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${_fieldLabel(field.key)}: ${_detailValue(field.value, field.key)}',
                  ),
                ),
              if (proposal.type == 'material' &&
                  draft.materialUrl(proposal) != null)
                Text('Ссылка: ${draft.materialUrl(proposal)}'),
              if (proposal.reason != null)
                Text('Основание: ${proposal.reason}'),
              if (proposal.sourceIds.isNotEmpty)
                Text('Источники: ${proposal.sourceIds.join(', ')}'),
              if (proposal.uncertainty.isNotEmpty)
                Text(
                  'Неопределённость: ${proposal.uncertainty.map(_fieldLabel).join(', ')}',
                ),
              if (proposal.decisionStatus != null)
                Text(switch (proposal.decisionStatus) {
                  'approved' => 'Предложение принято',
                  'rejected' => 'Предложение отклонено',
                  'reviewed' => 'Предложение просмотрено',
                  _ => 'Решение уже принято',
                })
              else if (draft.proposalSchemaVersion == 2 &&
                  agent.status == 'proposed' &&
                  [
                    'material',
                    'assignment_change',
                    'duplicate_conflict',
                  ].contains(proposal.type)) ...[
                const SizedBox(height: 12),
                if (proposal.type == 'material' &&
                    approveLabel(proposal) == null)
                  const Text(
                    'Сейчас можно публиковать только HTTPS-ссылки из исходных сообщений без связи с ДЗ.',
                  ),
                if (approveLabel(proposal) != null)
                  FilledButton(
                    onPressed: enabled
                        ? () => onDecision(
                            proposal,
                            proposal.index ?? position,
                            true,
                          )
                        : null,
                    child: Text(approveLabel(proposal)!),
                  ),
                TextButton(
                  onPressed: enabled
                      ? () => onDecision(
                          proposal,
                          proposal.index ?? position,
                          false,
                        )
                      : null,
                  child: const Text('Отклонить предложение'),
                ),
              ],
            ],
          ),
        ),
    ],
  );
}

class _UpdateProposalDialog extends StatefulWidget {
  const _UpdateProposalDialog({
    required this.proposal,
    required this.futureLessons,
  });
  final ReviewProposal proposal;
  final List<LessonOccurrence> Function() futureLessons;

  @override
  State<_UpdateProposalDialog> createState() => _UpdateProposalDialogState();
}

class _UpdateProposalDialogState extends State<_UpdateProposalDialog> {
  late final text = TextEditingController(
    text: widget.proposal.fields['new_text'] is String
        ? widget.proposal.fields['new_text'] as String
        : '',
  );
  String? lessonId;
  String? error;

  @override
  void initState() {
    super.initState();
    lessonId = widget
        .futureLessons()
        .where((l) => l.id == widget.proposal.fields['lesson_id'])
        .firstOrNull
        ?.id;
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.futureLessons();
    if (!available.any((l) => l.id == lessonId)) lessonId = null;
    return AlertDialog(
      title: const Text('Изменение ДЗ'),
      scrollable: true,
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Задание: ${widget.proposal.fields['assignment_id'] ?? 'Не указано'}',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: text,
              minLines: 3,
              maxLines: 6,
              maxLength: 20000,
              decoration: const InputDecoration(
                labelText: 'Новый текст ДЗ',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
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
                      '${lesson.subject} · ${lesson.date.day}.${lesson.date.month} · ${lesson.startTime}${lesson.subgroup == null ? '' : ' · п/г ${lesson.subgroup}'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => lessonId = value),
            ),
            if (available.isEmpty)
              const Text(
                'Нет будущих пар. Сначала добавьте занятие в расписание.',
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Palette.of(context).dangerInk),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Назад'),
        ),
        FilledButton(
          onPressed: lessonId == null || text.text.trim().isEmpty
              ? null
              : () {
                  if (!widget.futureLessons().any((l) => l.id == lessonId)) {
                    setState(() {
                      lessonId = null;
                      error = 'Выберите будущую пару.';
                    });
                    return;
                  }
                  Navigator.of(context)
                      .pop((text: text.text.trim(), lessonId: lessonId!));
                },
          child: const Text('Применить изменение'),
        ),
      ],
    );
  }
}

class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.api,
    required this.groupId,
    required this.lessons,
    this.subjectGroupCounts = const {},
  });
  final UsityApi api;
  final String groupId;
  final List<LessonOccurrence> lessons;
  final Map<String, int> subjectGroupCounts;
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
                  draft.summary == null
                      ? draft.text
                      : (draft.summary!.text?.trim().isNotEmpty == true
                            ? draft.summary!.text!
                            : _draftStatus(draft)),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    [
                      _draftStatus(draft),
                      if (draft.summary?.subject != null)
                        'Предмет: ${draft.summary!.subject}',
                      if (draft.summary?.dueAt != null)
                        'Срок: ${_deadline(draft.summary!.dueAt!)}',
                    ].join('\n'),
                  ),
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
                        subjectGroupCounts: widget.subjectGroupCounts,
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
    this.subjectGroupCounts = const {},
    this.now,
  });
  final DateTime Function()? now;
  final Map<String, int> subjectGroupCounts;
  final UsityApi api;
  final String groupId;
  final ReviewDraft draft;
  final List<LessonOccurrence> lessons;
  @override
  State<ReviewEditor> createState() => _ReviewEditorState();
}

class _ReviewEditorState extends State<ReviewEditor> {
  late final text = TextEditingController(text: widget.draft.assignmentText);
  String? lessonId;
  final subgroups = <int>{};
  String? error;
  bool busy = false;
  bool conflict = false;
  @override
  void initState() {
    super.initState();
    final summary = widget.draft.summary;
    final suggested = futureLessons()
        .where((l) => l.id == summary?.lessonId)
        .firstOrNull;
    if (suggested != null && widget.draft.canPublishHomework) {
      lessonId = suggested.id;
      if (suggested.subgroup == null) {
        final count = widget.subjectGroupCounts[suggested.subject] ?? 0;
        subgroups.addAll(summary!.subgroups.where((g) => g > 0 && g <= count));
      }
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit(bool approve) async {
    if (busy || conflict) return;
    if (approve &&
        (!widget.draft.canPublishHomework ||
            widget.draft.hasPendingAncillaryProposals ||
            text.text.trim().isEmpty)) {
      return;
    }
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
        subgroups: subgroups.toList()..sort(),
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

  Future<void> submitProposal(
    ReviewAgentRun agent,
    int runIndex,
    ReviewProposal proposal,
    int proposalIndex,
    bool approve,
  ) async {
    if (busy || conflict || proposal.decisionStatus != null) return;
    ({String text, String lessonId})? edits;
    if (approve &&
        proposal.type == 'assignment_change' &&
        proposal.fields['kind'] == 'cancel') {
      final target = widget.draft.activeAssignments
          .where((a) => a['id'] == proposal.fields['assignment_id'])
          .firstOrNull;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Отменить ДЗ?'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Задание: ${proposal.fields['assignment_id'] ?? 'Не указано'}',
              ),
              if (target?['text'] is String) Text(target!['text'] as String),
              if (proposal.reason != null)
                Text('Основание: ${proposal.reason}'),
              const SizedBox(height: 12),
              const Text('Исходные сообщения:'),
              for (final message in widget.draft.sourceMessages.where(
                (m) => proposal.sourceIds.contains(m['id']),
              ))
                Text(
                  message['text'] is String ? message['text'] as String : '',
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Назад'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Palette.of(context).dangerTint,
                foregroundColor: Palette.of(context).dangerInk,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Отменить ДЗ'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    } else if (approve && proposal.type == 'assignment_change') {
      if (proposal.fields['kind'] != 'update') return;
      edits = await showDialog<({String text, String lessonId})>(
        context: context,
        builder: (_) => _UpdateProposalDialog(
          proposal: proposal,
          futureLessons: futureLessons,
        ),
      );
      if (!mounted || edits == null) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.decideProposal(
        groupId: widget.groupId,
        draftId: widget.draft.id,
        version: widget.draft.version,
        runIndex: agent.index ?? runIndex,
        proposalIndex: proposalIndex,
        approve: approve,
        text: edits?.text,
        lessonId: edits?.lessonId,
      );
      // A decision increments the draft version. Return to the queue to fetch
      // the new version and per-proposal decisions before another mutation.
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
    if (!available.any((lesson) => lesson.id == lessonId)) {
      lessonId = null;
      subgroups.clear();
    }
    final selected = available.where((l) => l.id == lessonId).firstOrNull;
    final count = widget.subjectGroupCounts[selected?.subject] ?? 0;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.draft.summary == null && widget.draft.canPublishHomework
                ? 'Новое домашнее задание'
                : 'Проверка черновика',
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.draft.summary != null) ...[
              _SummaryInfo(widget.draft),
              const SizedBox(height: 24),
            ],
            if (widget.draft.canPublishHomework) ...[
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
                        '${lesson.subject} · ${lesson.date.day}.${lesson.date.month} · ${lesson.startTime}${lesson.subgroup == null ? '' : ' · п/г ${lesson.subgroup}'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy || conflict
                    ? null
                    : (value) => setState(() {
                        lessonId = value;
                        subgroups.clear();
                      }),
              ),
              if (selected != null &&
                  count > 0 &&
                  selected.subgroup == null) ...[
                const SizedBox(height: 16),
                const Text('Кому задано'),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Всем'),
                      selected: subgroups.isEmpty,
                      onSelected: busy || conflict
                          ? null
                          : (_) => setState(subgroups.clear),
                    ),
                    for (int g = 1; g <= count; g++)
                      FilterChip(
                        label: Text('Подгруппа $g'),
                        selected: subgroups.contains(g),
                        onSelected: busy || conflict
                            ? null
                            : (on) => setState(() {
                                if (on) {
                                  subgroups.add(g);
                                } else {
                                  subgroups.remove(g);
                                }
                              }),
                      ),
                  ],
                ),
              ],
              if (available.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Нет будущих пар. Сначала добавьте занятие в расписание.',
                  ),
                ),
            ],
            const SizedBox(height: 24),
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
              for (final (index, agent) in widget.draft.agents.indexed)
                _AgentDetails(
                  agent,
                  draft: widget.draft,
                  enabled: !busy && !conflict,
                  onDecision: (proposal, proposalIndex, approve) =>
                      submitProposal(
                        agent,
                        index,
                        proposal,
                        proposalIndex,
                        approve,
                      ),
                ),
              const SizedBox(height: 24),
            ],
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Palette.of(context).surfaceMuted,
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
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            if (widget.draft.canPublishHomework &&
                widget.draft.hasPendingAncillaryProposals)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Сначала примите или отклоните отдельные предложения о материалах, изменениях и дублях.',
                ),
              ),
            if (conflict)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Вернуться к очереди'),
              )
            else ...[
              FilledButton(
                onPressed:
                    busy ||
                        !widget.draft.canPublishHomework ||
                        widget.draft.hasPendingAncillaryProposals ||
                        lessonId == null ||
                        text.text.trim().isEmpty
                    ? null
                    : () => submit(true),
                child: Text(busy ? 'Сохраняем…' : 'Опубликовать'),
              ),
              TextButton(
                onPressed: busy ? null : () => submit(false),
                child: Text(
                  widget.draft.hasPendingAncillaryProposals
                      ? 'Отклонить все оставшиеся'
                      : 'Отклонить',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
