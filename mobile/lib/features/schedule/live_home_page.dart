import 'package:flutter/material.dart';

import '../../data/usity_api.dart';
import '../review/review_page.dart';
import 'schedule_page.dart';

class LiveHomePage extends StatefulWidget {
  const LiveHomePage({super.key, required this.api});
  final UsityApi api;
  @override
  State<LiveHomePage> createState() => _LiveHomePageState();
}

class _LiveHomePageState extends State<LiveHomePage> {
  late Future<ScheduleSnapshot> snapshot = widget.api.loadSchedule();
  int tab = 0;
  DateTime selectedDay = DateTime.now();
  bool completing = false;
  void refresh() => setState(() {
    snapshot = widget.api.loadSchedule();
  });
  @override
  void dispose() {
    widget.api.close();
    super.dispose();
  }

  Future<void> complete(ScheduleSnapshot data, HomeworkItem item) async {
    if (completing) return;
    setState(() => completing = true);
    try {
      await widget.api.complete(data.groupId, item);
      if (mounted) refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
        if (e is ApiException && e.status == 409) refresh();
      }
    } finally {
      if (mounted) setState(() => completing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 5),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Text(
              'Учебный стенд · синтетические данные',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
        Expanded(
          child: tab != 0
              ? Center(
                  child: Text(
                    [
                      '',
                      'Предметы — в разработке',
                      'Личные задачи — в разработке',
                      'Настройки — в разработке',
                    ][tab],
                  ),
                )
              : FutureBuilder<ScheduleSnapshot>(
                  future: snapshot,
                  builder: (context, state) {
                    if (state.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (state.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${state.error}',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: refresh,
                                child: const Text('Повторить'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    final data = state.data!;
                    return SchedulePage(
                      today: selectedDay,
                      onDaySelected: (day) => selectedDay = day,
                      lessons: data.lessons,
                      onComplete: completing
                          ? null
                          : (item) => complete(data, item),
                      actions: [
                        if (data.canReview)
                          IconButton(
                            tooltip: 'Проверить ДЗ',
                            icon: const Icon(Icons.fact_check_outlined),
                            onPressed: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ReviewPage(
                                    api: widget.api,
                                    groupId: data.groupId,
                                    lessons: data.lessons,
                                  ),
                                ),
                              );
                              if (mounted) refresh();
                            },
                          ),
                        IconButton(
                          tooltip: 'Обновить',
                          onPressed: refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (value) => setState(() => tab = value),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.calendar_today_outlined),
          label: 'Расписание',
        ),
        NavigationDestination(
          icon: Icon(Icons.menu_book_outlined),
          label: 'Предметы',
        ),
        NavigationDestination(
          icon: Icon(Icons.check_circle_outline),
          label: 'Задачи',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: 'Настройки',
        ),
      ],
    ),
  );
}
