import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:usity/data/usity_api.dart';
import 'package:usity/features/account/account_page.dart';

void main() {
  test('accepts only the installed-app invitation format', () {
    final token = '12345678-abcd-4321-aaaa-123456789abc.${'a' * 64}';
    expect(invitationToken(' usity://join/$token '), token);
    for (final url in [
      'https://join/$token',
      'usity://join:80/$token',
      'usity://name@join/$token',
      'usity://join/$token?extra=1',
      'usity://join/$token/other',
      'usity://join/bad',
    ]) {
      expect(invitationToken(url), isNull);
    }
  });

  test(
    'requests a code without a bearer and sends OTP only to verify',
    () async {
      final paths = <String>[];
      final api = UsityApi(
        baseUrl: 'https://example.test',
        token: '',
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body);
          expect(body['email'], 'student@example.test');
          if (request.url.path == '/auth/code') {
            expect(body.containsKey('code'), isFalse);
            return http.Response('{"sent":true}', 202);
          }
          expect(body['code'], '123456');
          return http.Response('{"token":"test-session"}', 200);
        }),
      );
      await api.requestCode('student@example.test');
      expect(
        await api.verifyCode('student@example.test', '123456'),
        'test-session',
      );
      expect(paths, ['/auth/code', '/auth/verify']);
      api.close();
    },
  );
}
