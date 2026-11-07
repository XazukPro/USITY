import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/schedule.dart';
import '../domain/group_setup.dart';

class ApiException implements Exception {
  const ApiException(this.status, this.message);
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

class ReviewDraft {
  const ReviewDraft({
    required this.id,
    required this.text,
    required this.version,
    required this.messages,
  });
  final String id;
  final String text;
  final int version;
  final List<String> messages;
  factory ReviewDraft.fromJson(Map<String, dynamic> json) => ReviewDraft(
    id: json['id'] as String,
    text: json['text'] as String,
    version: json['version'] as int,
    messages: (json['source_context']['messages'] as List)
        .map((m) => m['text'] as String)
        .toList(),
  );
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

  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      final request = http.Request(method, base.resolve(path))
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
        throw ApiException(response.statusCode, message);
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
      await _request('POST', '/auth/code', {'email': email});
  Future<String> verifyCode(String email, String code) async =>
      (await _request('POST', '/auth/verify', {
            'email': email,
            'code': code,
          }))['token']
          as String;
  Future<Map<String, dynamic>> account() async =>
      await _request('GET', '/account');
  Future<void> logout() async => await _request('POST', '/account/logout');
  Future<Map<String, dynamic>> join(String invite) async =>
      await _request('POST', '/account/join', {'invite': invite});
  Future<Map<String, dynamic>> chooseGroups(Map<String, int> choices) async =>
      await _request('PUT', '/account/subgroups', {'choices': choices});
  Future<Map<String, dynamic>> createGroup(GroupSetup group) async =>
      await _request('POST', '/account/group', {
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

  Future<ScheduleSnapshot> loadSchedule() async {
    final me = await _request('GET', '/me');
    final group = me['group_id'] as String;
    final results = await Future.wait([
      _request('GET', '/groups/$group/lessons'),
      _request('GET', '/groups/$group/assignments'),
    ]);
    final assignments = results[1] as List;
    String time(DateTime date) =>
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final lessons = (results[0] as List).map((j) {
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
      (await _request('GET', '/groups/$groupId/review') as List)
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
    await _request('POST', '/groups/$groupId/review/$draftId/decision', {
      'action': approve ? 'approve' : 'reject',
      'expected_version': version,
      if (approve) ...{'text': text, 'lesson_id': lessonId},
      if (approve && subgroups.isNotEmpty) 'subgroups': subgroups,
    });
  }

  Future<void> complete(String groupId, HomeworkItem homework) async {
    await _request(
      'PUT',
      '/groups/$groupId/assignments/${homework.id}/completion',
      {'version': homework.version, 'completed': true},
    );
  }
}
