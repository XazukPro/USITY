import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/usity_api.dart';
import '../../domain/group_setup.dart';
import '../../theme/tokens.dart';
import '../onboarding/owner_wizard.dart';
import '../schedule/live_home_page.dart';

String? invitationToken(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null ||
      uri.scheme != 'usity' ||
      uri.host != 'join' ||
      uri.pathSegments.length != 1 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasPort ||
      uri.hasFragment) {
    return null;
  }
  final token = uri.pathSegments.single;
  return RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\.[a-f0-9]{64}$')
          .hasMatch(token)
      ? token
      : null;
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.baseUrl});
  final String baseUrl;
  @override
  State<AccountPage> createState() => _AccountState();
}

class _AccountState extends State<AccountPage> {
  final email = TextEditingController(),
      code = TextEditingController(),
      invitation = TextEditingController();
  final storage = const FlutterSecureStorage();
  final links = AppLinks();
  StreamSubscription<Uri>? subscription;
  String get key => 'usity.session.${Uri.encodeComponent(widget.baseUrl)}';
  late UsityApi api;
  Map<String, dynamic>? profile;
  bool sent = false, busy = true;
  String? problem;
  GroupSetup? draft;

  @override
  void initState() {
    super.initState();
    api = client('');
    subscription = links.uriLinkStream.listen(readInvite, onError: (_) {});
    restore();
  }

  UsityApi client(String token) =>
      UsityApi(baseUrl: widget.baseUrl, token: token);
  void readInvite(Uri uri) {
    if (mounted && invitationToken(uri.toString()) != null) {
      setState(() => invitation.text = uri.toString());
    }
  }

  Future<void> restore() async {
    try {
      final token = await storage.read(key: key);
      if (!mounted) return;
      if (token != null) {
        api.close();
        api = client(token);
        profile = await api.account();
      }
    } on ApiException catch (e) {
      if (e.status == 401) {
        await clear();
      } else {
        problem = e.message;
      }
    } on Exception {
      problem = 'Не удалось восстановить сессию.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> clear() async {
    api.close();
    api = client('');
    profile = null;
    sent = false;
    draft = null;
    code.clear();
    await storage.delete(key: key);
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (e.status == 401 && api.token.isNotEmpty) await clear();
      problem = e.message;
    } on Exception {
      problem = 'Действие не удалось. Попробуйте ещё раз.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    subscription?.cancel();
    api.close();
    email.dispose();
    code.dispose();
    invitation.dispose();
    super.dispose();
  }

  Future<void> send() async {
    await api.requestCode(email.text.trim());
    if (mounted) {
      sent = true;
      code.clear();
    }
  }

  Future<void> verify() async {
    final token = await api.verifyCode(email.text.trim(), code.text);
    await storage.write(key: key, value: token);
    if (!mounted) return;
    api.close();
    api = client(token);
    code.clear();
    profile = await api.account();
  }

  Future<void> create() async {
    draft ??= await Navigator.push<GroupSetup>(
      context,
      MaterialPageRoute(
        builder: (_) => OwnerWizard(today: DateTime.now(), server: true),
      ),
    );
    if (!mounted || draft == null) return;
    // A timed-out POST may have committed. Reconcile before retry.
    profile = await api.account();
    if (profile!['group_id'] == null) profile = await api.createGroup(draft!);
    draft = null;
  }

  Future<void> join() async {
    final token = invitationToken(invitation.text);
    if (token == null) {
      problem = 'Вставьте полную ссылку USITY.';
      return;
    }
    profile = await api.account();
    if (profile!['group_id'] == null) profile = await api.join(token);
    invitation.clear();
  }

  Future<void> choose() async {
    final groups = Map<String, int>.from(profile!['choices'] as Map);
    final result = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: StatefulBuilder(
          builder: (context, update) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(Metrics.space5),
            children: [
              const Text('Подгруппы по предметам', style: TypeScale.title),
              for (final s in profile!['subjects'])
                DropdownButtonFormField<int>(
                  initialValue: groups[s['name']] ?? 0,
                  decoration: InputDecoration(labelText: s['name'] as String),
                  items: [
                    const DropdownMenuItem(value: 0, child: Text('Пропустить')),
                    for (var n = 1; n <= s['groups']; n++)
                      DropdownMenuItem(value: n, child: Text('Подгруппа $n')),
                  ],
                  onChanged: (v) => update(() {
                    if (v == 0) {
                      groups.remove(s['name']);
                    } else {
                      groups[s['name'] as String] = v!;
                    }
                  }),
                ),
              const SizedBox(height: Metrics.space4),
              FilledButton(
                onPressed: () => Navigator.pop(context, groups),
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null && mounted) profile = await api.chooseGroups(result);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context), hasSession = api.token.isNotEmpty;
    Widget button(String label, Future<void> Function() action) => FilledButton(
      onPressed: busy ? null : () => run(action),
      child: Text(label),
    );
    final data = profile;
    return Scaffold(
      appBar: AppBar(title: const Text('USITY')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Metrics.space5),
          children: [
            if (!hasSession) ...[
              Text(
                sent ? 'Проверьте почту' : 'Вход по email',
                style: TypeScale.titleLg,
              ),
              const SizedBox(height: Metrics.space4),
              if (!sent)
                TextField(
                  controller: email,
                  enabled: !busy,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Электронная почта',
                    hintText: 'student@example.test',
                  ),
                )
              else ...[
                Text(email.text),
                TextField(
                  controller: code,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: const InputDecoration(labelText: 'Код из письма'),
                ),
              ],
              const SizedBox(height: Metrics.space4),
              button(sent ? 'Войти' : 'Получить код', sent ? verify : send),
              if (sent) ...[
                TextButton(
                  onPressed: busy ? null : () => run(send),
                  child: const Text('Отправить ещё раз'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          sent = false;
                          problem = null;
                        }),
                  child: const Text('Изменить email'),
                ),
              ],
              if (invitation.text.isNotEmpty)
                const Text('Приглашение будет доступно после входа.'),
            ] else if (data == null) ...[
              if (!busy)
                button(
                  'Загрузить профиль',
                  () async => profile = await api.account(),
                ),
            ] else ...[
              Text(
                data['group_name'] as String? ?? 'Учебная группа',
                style: TypeScale.titleLg,
              ),
              Text(data['email'] as String),
              const SizedBox(height: Metrics.space5),
              if (data['group_id'] == null) ...[
                button(
                  draft == null
                      ? 'Создать группу'
                      : 'Повторить создание группы',
                  create,
                ),
                if (draft != null)
                  TextButton(
                    onPressed: busy ? null : () => setState(() => draft = null),
                    child: const Text('Заполнить заново'),
                  ),
                const SizedBox(height: Metrics.space5),
                TextField(
                  controller: invitation,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Ссылка-приглашение',
                  ),
                ),
                const SizedBox(height: Metrics.space2),
                button('Вступить в группу', join),
              ] else ...[
                Text(switch (data['role']) {
                  'owner' => 'Староста',
                  'admin' => 'Администратор',
                  _ => 'Студент',
                }, style: TypeScale.heading),
                const SizedBox(height: Metrics.space3),
                button('Открыть расписание', () async {
                  final scheduleApi = client(api.token);
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LiveHomePage(api: scheduleApi),
                    ),
                  );
                }),
                if (data['role'] == 'student' &&
                    (data['subjects'] as List).isNotEmpty)
                  TextButton(
                    onPressed: busy ? null : () => run(choose),
                    child: const Text('Выбрать подгруппы'),
                  ),
                if (data['invite_url'] case final String url)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Скопировать приглашение'),
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            await Clipboard.setData(ClipboardData(text: url));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Приглашение скопировано'),
                                ),
                              );
                            }
                          }),
                  ),
              ],
            ],
            if (hasSession)
              TextButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await api.logout();
                        await clear();
                      }),
                child: const Text('Выйти из аккаунта'),
              ),
            if (busy) const LinearProgressIndicator(),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: Metrics.space3),
                child: Text(
                  problem!,
                  style: TypeScale.callout.copyWith(color: p.dangerInk),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
