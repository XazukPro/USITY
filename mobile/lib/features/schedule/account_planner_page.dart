import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/offline_plan.dart';
import '../../data/usity_api.dart';
import '../../domain/day_plan.dart';
import '../../shell/settings.dart';
import '../../shell/tabs.dart';
import '../materials/live_materials.dart';
import '../review/review_page.dart';
import 'demo_tasks.dart';
import 'planner_page.dart';

class AccountPlannerPage extends StatefulWidget {
  const AccountPlannerPage({
    super.key,
    required this.api,
    required this.profile,
  });
  final UsityApi api;
  final Map<String, dynamic> profile;
  @override
  State<AccountPlannerPage> createState() => _AccountPlannerState();
}

class _AccountPlannerState extends State<AccountPlannerPage>
    with WidgetsBindingObserver {
  OfflinePlan? plan;
  int tab = 0;
  bool syncing = false, again = false, foreground = true;
  String? problem;
  Timer? retry, expiry;
  DateTime? get expires =>
      DateTime.tryParse(widget.profile['session_expires_at'] ?? '');
  String get group => widget.profile['group_id'] as String;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(open());
    final until = expires;
    if (until != null) expiry = Timer(until.difference(DateTime.now()), deny);
    retry = Timer.periodic(const Duration(seconds: 30), (_) {
      if (foreground && (problem != null || (plan?.pending ?? 0) > 0)) sync();
    });
  }

  Future<void> open() async {
    try {
      final p = await OfflinePlan.open(widget.api, widget.profile, sync, fail);
      await p.reload();
      if (!mounted) {
        p.dispose();
        return;
      }
      setState(() => plan = p);
      p.addListener(updated);
      await sync();
    } on Exception {
      fail('Не удалось открыть локальную базу.');
    }
  }

  void updated() {
    if (mounted) setState(() {});
  }

  void fail(String value) {
    if (mounted) setState(() => problem = value);
  }

  void deny() {
    if (!mounted) return;
    final nav = Navigator.of(context), route = ModalRoute.of(context);
    nav.popUntil((r) => r == route || r.isFirst);
    nav.pop(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      if (expires?.isBefore(DateTime.now()) == true) {
        deny();
        return;
      }
      sync();
    }
  }

  Future<void> sync() async {
    final p = plan;
    if (!mounted || p == null) return;
    if (syncing) {
      again = true;
      return;
    }
    setState(() => syncing = true);
    try {
      do {
        again = false;
        await p.sync(widget.api);
        if (!mounted) return;
        problem = null;
      } while (again);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 401 || e.status == 403) {
        deny();
        return;
      }
      fail(
        e.status == 0
            ? 'Офлайн · изменения сохранены на устройстве'
            : e.message,
      );
    } on Exception {
      fail('Не удалось синхронизировать данные.');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> review() async {
    final data = plan?.snapshot;
    if (data == null || !data.canReview) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewPage(
          api: widget.api,
          groupId: group,
          lessons: data.lessons,
          subjectGroupCounts: data.subjectGroupCounts,
        ),
      ),
    );
    if (mounted) await sync();
  }

  String describe(Map row) {
    final start = row['start'] as int?;
    return [
      row['title'],
      if (start == null)
        'Без срока'
      else
        '${row['day']} · ${clockTime(start)}–${clockTime(start + (row['duration'] as int))}',
      row['completed_at'] == null ? 'Активна' : 'Выполнена',
      if (row['remind'] == true) 'Напоминание включено',
    ].join('\n');
  }

  Future<void> chooseVersion() async {
    final p = plan!;
    if (p.conflicts.isEmpty) return;
    final conflict = p.conflicts.first;
    final remote = conflict['remote'] as Map?;
    final local = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Выберите версию задачи'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('На устройстве', style: Theme.of(c).textTheme.titleSmall),
              Text(describe(conflict['local'] as Map)),
              const SizedBox(height: 12),
              Text('На сервере', style: Theme.of(c).textTheme.titleSmall),
              Text(
                remote == null ? 'Задача больше недоступна' : describe(remote),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Принять с сервера'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              remote == null ? 'Сохранить как новую' : 'Оставить мою',
            ),
          ),
        ],
      ),
    );
    if (local != null && mounted) p.resolve(conflict['id'] as String, local);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    retry?.cancel();
    expiry?.cancel();
    plan?.removeListener(updated);
    plan?.dispose();
    widget.api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = plan;
    if (p == null) {
      return Scaffold(
        body: Center(
          child: problem == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(problem!),
                    TextButton(onPressed: open, child: const Text('Повторить')),
                  ],
                ),
        ),
      );
    }
    final snap = p.snapshot;
    final canReview = snap?.canReview ?? false;
    final conflicts = p.conflicts.isNotEmpty;
    final message = conflicts
        ? 'Задача изменена на другом устройстве'
        : problem ??
              (p.pending > 0 ? 'Ожидают синхронизации · ${p.pending}' : null);
    final subjects =
        (widget.profile['subject_names'] as List?)?.cast<String>() ??
        p.lessons.map((l) => l.subject).toSet().toList();
    Widget materials([String? subject]) => LiveMaterials(
      api: widget.api,
      groupId: group,
      userId: widget.profile['user_id'] as String,
      canReview: canReview,
      subjects: subjects,
      initialSubject: subject,
    );
    void openMaterials(String subject) => Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => materials(subject)),
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (message != null)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(message)),
                      TextButton(
                        onPressed: conflicts ? chooseVersion : sync,
                        child: Text(conflicts ? 'Сравнить' : 'Обновить'),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: IndexedStack(
                index: tab,
                children: [
                  PlannerPage(
                    today: DateTime.now(),
                    plan: p,
                    onMaterials: openMaterials,
                  ),
                  DemoTasks(plan: p, onMaterials: openMaterials),
                  if (tab == 2) materials() else const SizedBox.shrink(),
                  SettingsPage(
                    pending: snap?.pendingReviewCount ?? 0,
                    onReview: canReview ? review : null,
                    profileLabel: widget.profile['group_name'] as String?,
                    roleLabel: switch (widget.profile['role']) {
                      'owner' => 'Староста',
                      'admin' => 'Администратор',
                      _ => 'Студент',
                    },
                    onAccount: () => Navigator.pop(context),
                    onRefresh: sync,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: UsityTabs(
        index: tab,
        onSelect: (i) => setState(() => tab = i),
        pending: canReview ? snap!.pendingReviewCount : 0,
      ),
    );
  }
}
