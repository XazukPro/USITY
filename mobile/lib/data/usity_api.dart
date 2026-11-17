import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/schedule.dart';
import '../domain/group_setup.dart';

class ApiException implements Exception {
  const ApiException(this.status, this.message, [this.detail]);
  final dynamic detail;
  final int status;
  final String message;
  @override
  String toString() => message;
}

class ScheduleSnapshot {
  const ScheduleSnapshot(
    this.groupId,
    this.canReview,
    this.lessons, [
    this.pendingReviewCount = 0,
    this.subjectGroupCounts = const {},
  ]);
  final Map<String, int> subjectGroupCounts;
  final int pendingReviewCount;
  final String groupId;
  final bool canReview;
  final List<LessonOccurrence> lessons;
}

String? _reviewString(Object? value) => value is String ? value : null;

List<T> _reviewList<T>(Object? value) =>
    value is List ? value.whereType<T>().toList() : <T>[];

Iterable<(int, Map<String, dynamic>)> _reviewObjects(Object? value) sync* {
  if (value is List) {
    for (final entry in value.indexed) {
      if (entry.$2 is Map<String, dynamic>) {
        yield (entry.$1, entry.$2 as Map<String, dynamic>);
      }
    }
  }
}

class ReviewSummary {
  const ReviewSummary({
    required this.state,
    this.homework,
    this.text,
    this.subject,
    this.lessonId,
    this.dueAt,
    this.subgroups = const [],
    this.missingFields = const [],
  });
  final String state;
  final bool? homework;
  final String? text;
  final String? subject;
  final String? lessonId;
  final DateTime? dueAt;
  final List<int> subgroups;
  final List<String> missingFields;

  factory ReviewSummary.fromJson(Map<String, dynamic> json) => ReviewSummary(
    state: _reviewString(json['state']) ?? 'needs_review',
    homework: json['homework'] is bool ? json['homework'] as bool : null,
    text: _reviewString(json['text']),
    subject: _reviewString(json['subject']),
    lessonId: _reviewString(json['lesson_id']),
    dueAt: DateTime.tryParse(_reviewString(json['due_at']) ?? ''),
    subgroups: _reviewList<int>(json['subgroups'])
        .where((g) => g > 0)
        .toSet()
        .toList(),
    missingFields: _reviewList<String>(json['missing_fields']),
  );
}

class ReviewProposal {
  const ReviewProposal({
    required this.type,
    this.fields = const {},
    this.reason,
    this.sourceIds = const [],
    this.uncertainty = const [],
    this.index,
    this.decisionStatus,
  });
  final String type;
  final Map<String, dynamic> fields;
  final String? reason;
  final List<int> sourceIds;
  final List<String> uncertainty;
  final int? index;
  final String? decisionStatus;

  factory ReviewProposal.fromJson(Map<String, dynamic> json, {int? index}) =>
      ReviewProposal(
        index: index,
        type: _reviewString(json['proposal_type']) ?? 'unknown',
        fields: json['fields'] is Map<String, dynamic>
            ? json['fields'] as Map<String, dynamic>
            : const {},
        reason: _reviewString(json['reason']),
        sourceIds: _reviewList<int>(json['source_ids']),
        uncertainty: _reviewList<String>(json['uncertainty']),
        decisionStatus: json['decision'] is Map
            ? _reviewString(json['decision']['status'])
            : null,
      );
}

class ReviewAgentRun {
  const ReviewAgentRun(
    this.id,
    this.status, {
    this.proposals = const [],
    this.index,
  });
  final String id;
  final String status;
  final List<ReviewProposal> proposals;
  final int? index;
  factory ReviewAgentRun.fromJson(Map<String, dynamic> json, {int? index}) =>
      ReviewAgentRun(
        _reviewString(json['agent_id']) ?? 'unknown',
        _reviewString(json['status']) ?? 'unknown',
        index: index,
        proposals: _reviewObjects(json['proposals'])
            .map((entry) => ReviewProposal.fromJson(entry.$2, index: entry.$1))
            .toList(),
      );
}

class ReviewDraft {
  const ReviewDraft({
    required this.id,
    required this.text,
    required this.version,
    required this.messages,
    this.agents = const [],
    this.summary,
    this.proposalSchemaVersion,
    this.sourceMessages = const [],
    this.activeAssignments = const [],
  });
  final String id;
  final String text;
  final int version;
  final List<String> messages;
  final List<ReviewAgentRun> agents;
  final ReviewSummary? summary;
  final int? proposalSchemaVersion;
  final List<Map<String, dynamic>> sourceMessages;
  final List<Map<String, dynamic>> activeAssignments;

  bool get hasPendingAncillaryProposals => agents
      .where((agent) => agent.status == 'proposed')
      .expand((agent) => agent.proposals)
      .any(
        (proposal) =>
            proposal.decisionStatus == null &&
            [
              'material',
              'assignment_change',
              'duplicate_conflict',
            ].contains(proposal.type),
      );

  String? materialUrl(ReviewProposal proposal) {
    final attachments = sourceMessages
        .where((m) => proposal.sourceIds.contains(m['id']))
        .expand((m) => _reviewObjects(m['attachments']).map((a) => a.$2))
        .where((a) => a['id'] == proposal.fields['attachment_id'])
        .toList();
    if (attachments.length != 1 || attachments.single['kind'] != 'link') {
      return null;
    }
    final value = _reviewString(attachments.single['url']);
    final uri = Uri.tryParse(value ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return value;
  }

  bool get canPublishHomework {
    if (summary?.state == 'no_action' || summary?.homework == false) {
      return false;
    }
    if (summary?.homework == true) return true;
    // Older summaries did not include homework. Explicit non-homework proposals
    // must still never be sent to the new-assignment decision endpoint.
    final proposals = agents.expand((agent) => agent.proposals);
    if (proposals.any((p) => p.type == 'new_homework')) return true;
    if (proposals.any(
      (p) => [
        'material',
        'assignment_change',
        'duplicate_conflict',
      ].contains(p.type),
    )) {
      return false;
    }
    return true;
  }

  String get assignmentText => summary == null ? text : summary!.text ?? '';

  factory ReviewDraft.fromJson(Map<String, dynamic> json) {
    final proposalSet = json['proposal_set'];
    final data = proposalSet is Map<String, dynamic>
        ? proposalSet
        : const <String, dynamic>{};
    final summary = data['summary'];
    final context = json['source_context'];
    final sourceMessages = context is Map
        ? _reviewObjects(context['messages']).map((m) => m.$2).toList()
        : <Map<String, dynamic>>[];
    return ReviewDraft(
      id: json['id'] as String,
      text: json['text'] as String,
      version: json['version'] as int,
      messages: sourceMessages
          .map((m) => _reviewString(m['text']) ?? '')
          .toList(),
      sourceMessages: sourceMessages,
      activeAssignments: context is Map
          ? _reviewObjects(context['active_assignments'])
                .map((a) => a.$2)
                .toList()
          : const [],
      proposalSchemaVersion: data['schema_version'] is int
          ? data['schema_version'] as int
          : null,
      summary: summary is Map<String, dynamic>
          ? ReviewSummary.fromJson(summary)
          : null,
      agents: _reviewObjects(data['runs'])
          .map((entry) => ReviewAgentRun.fromJson(entry.$2, index: entry.$1))
          .toList(),
    );
  }
}

class UsityApi {
  UsityApi({required String baseUrl, required this.token, http.Client? client})
    : base = Uri.parse(baseUrl),
      client = client ?? http.Client() {
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            ['localhost', '127.0.0.1', '10.0.2.2'].contains(base.host))) {
      throw ArgumentError('Для сервера требуется HTTPS');
    }
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw ArgumentError('Неверный адрес сервера');
    }
  }
  final Uri base;
  final String token;
  final http.Client client;
  void close() => client.close();

  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      final uri = base.resolve(path);
      if (uri.origin != base.origin ||
          !path.startsWith('/') ||
          uri.userInfo.isNotEmpty) {
        throw ArgumentError('Неверный путь API');
      }
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll({
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        });
      if (body != null) request.body = jsonEncode(body);
      // Do not automatically retry mutations after a timeout: they may have committed.
      final response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = switch (response.statusCode) {
          401 when path == '/auth/verify' => 'Код недействителен или истёк.',
          401 => 'Сессия истекла. Войдите снова.',
          403 => 'Недостаточно прав для этого действия.',
          409 => 'Данные изменились. Обновите экран.',
          422 => 'Проверьте введённые данные.',
          404 when path == '/account/join' => 'Приглашение недействительно.',
          429 => 'Слишком много попыток. Попробуйте позже.',
          503 when path.startsWith('/auth/') => 'Почта временно недоступна.',
          _ => 'Сервер недоступен. Повторите позже.',
        };
        Object? detail;
        try {
          final body = jsonDecode(utf8.decode(response.bodyBytes));
          if (body is Map) detail = body['detail'];
        } on FormatException {
          // A proxy may return a non-JSON error; preserve its HTTP status.
        }
        throw ApiException(response.statusCode, message, detail);
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on TimeoutException {
      throw const ApiException(
        0,
        'Сервер не ответил. Обновите экран, чтобы проверить результат.',
      );
    } on http.ClientException {
      throw const ApiException(0, 'Нет соединения с сервером. Проверьте сеть.');
    } on FormatException {
      throw const ApiException(0, 'Не удалось прочитать ответ сервера.');
    }
  }

  Future<void> requestCode(String email) async =>
      await request('POST', '/auth/code', {'email': email});
  Future<String> verifyCode(String email, String code) async =>
      (await request('POST', '/auth/verify', {
            'email': email,
            'code': code,
          }))['token']
          as String;
  Future<Map<String, dynamic>> account() async =>
      await request('GET', '/account');
  Future<void> logout() async => await request('POST', '/account/logout');
  Future<Map<String, dynamic>> join(String invite) async =>
      await request('POST', '/account/join', {'invite': invite});
  Future<Map<String, dynamic>> chooseGroups(Map<String, int> choices) async =>
      await request('PUT', '/account/subgroups', {'choices': choices});
  Future<Map<String, dynamic>> createGroup(GroupSetup group) async =>
      await request('POST', '/account/group', {
        'name': group.name.trim(),
        'start': group.start.toIso8601String().substring(0, 10),
        'end': group.end.toIso8601String().substring(0, 10),
        'alternating': group.alternating,
        'subjects': [
          for (final s in group.subjects)
            {
              'id': s.id,
              'name': s.name,
              'groups': s.groups,
              'kinds': s.kinds.map((k) => k.name).toList(),
            },
        ],
        'slots': [
          for (final s in group.slots)
            {
              'subject_id': s.subjectId,
              'weekday': s.weekday,
              'start': s.start,
              'end': s.end,
              'kind': s.kind.name,
              'teacher': s.teacher,
              'room': s.room,
              'subgroup': s.subgroup,
              'pattern': s.pattern.name,
            },
        ],
      });

  Future<List<Map<String, dynamic>>> fetchTasks() async =>
      (await request('GET', '/account/tasks') as List)
          .cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> putTask(
    String id,
    Map<String, dynamic> body,
  ) async => await request('PUT', '/account/tasks/$id', body);

  Future<Map<String, dynamic>> fetchSchedule({
    bool includeCompleted = false,
  }) async {
    final me = await request('GET', '/me');
    final group = me['group_id'] as String;
    final results = await Future.wait([
      request('GET', '/groups/$group/lessons'),
      request(
        'GET',
        '/groups/$group/assignments${includeCompleted ? '?include_completed=true' : ''}',
      ),
    ]);
    return {'me': me, 'lessons': results[0], 'assignments': results[1]};
  }

  Future<ScheduleSnapshot> loadSchedule() async =>
      decodeSchedule(await fetchSchedule());

  static ScheduleSnapshot decodeSchedule(Map<String, dynamic> data) {
    final me = data['me'];
    final group = me['group_id'] as String;
    final assignments = data['assignments'] as List;
    String time(DateTime date) =>
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final lessons = (data['lessons'] as List).map((j) {
      final start = DateTime.parse(j['starts_at'] as String).toLocal();
      final end = DateTime.parse(j['ends_at'] as String).toLocal();
      return LessonOccurrence(
        id: j['id'] as String,
        date: start,
        startTime: time(start),
        endTime: time(end),
        subject: j['subject'] as String,
        teacher: j['teacher'] as String,
        location: j['location'] as String,
        kind: LessonKind.values.byName(j['kind'] as String? ?? 'lecture'),
        subgroup: j['subgroup']?.toString(),
        homework: assignments
            .where((a) => a['lesson_id'] == j['id'])
            .map(
              (a) => HomeworkItem(
                id: a['id'] as String,
                text: a['text'] as String,
                version: a['version'] as int,
                completed: a['completed'] as bool? ?? false,
              ),
            )
            .toList(),
      );
    }).toList();
    return ScheduleSnapshot(
      group,
      ['admin', 'owner'].contains(me['role']),
      lessons,
      me['pending_review_count'] as int? ?? 0,
      Map<String, int>.from(me['subject_group_counts'] as Map? ?? {}),
    );
  }

  Future<List<ReviewDraft>> loadReview(String groupId) async =>
      (await request('GET', '/groups/$groupId/review') as List)
          .map((j) => ReviewDraft.fromJson(j as Map<String, dynamic>))
          .toList();

  Future<void> decide({
    required String groupId,
    required String draftId,
    required int version,
    required bool approve,
    String? text,
    String? lessonId,
    List<int> subgroups = const [],
  }) async {
    await request('POST', '/groups/$groupId/review/$draftId/decision', {
      'action': approve ? 'approve' : 'reject',
      'expected_version': version,
      if (approve) ...{'text': text, 'lesson_id': lessonId},
      if (approve && subgroups.isNotEmpty) 'subgroups': subgroups,
    });
  }

  Future<void> decideProposal({
    required String groupId,
    required String draftId,
    required int version,
    required int runIndex,
    required int proposalIndex,
    required bool approve,
    String? text,
    String? lessonId,
  }) async {
    await request(
      'POST',
      '/groups/$groupId/review/$draftId/proposals/$runIndex/$proposalIndex/decision',
      {
        'action': approve ? 'approve' : 'reject',
        'expected_version': version,
        if (approve && text != null) 'text': text,
        if (approve && lessonId != null) 'lesson_id': lessonId,
      },
    );
  }

  Future<void> complete(
    String groupId,
    HomeworkItem homework, {
    bool completed = true,
  }) async {
    await request(
      'PUT',
      '/groups/$groupId/assignments/${homework.id}/completion',
      {'version': homework.version, 'completed': completed},
    );
  }
}
