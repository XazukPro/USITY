import 'package:flutter/material.dart';

import '../../data/usity_api.dart';
import '../../shell/tabs.dart';
import '../../shell/settings.dart';
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
  Future<void> openReview(ScheduleSnapshot data) async {
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
  }

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
          child: tab == 3
              ? FutureBuilder<ScheduleSnapshot>(
                  future: snapshot,
                  builder: (context, state) => SettingsPage(
                    pending: state.data?.pendingReviewCount ?? 0,
                    onReview: state.data?.canReview == true
                        ? () => openReview(state.data!)
                        : null,
                  ),
                )
              : tab != 0
              ? Center(child: Text(tabLabels[tab]))
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
                            onPressed: () => openReview(data),
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
    bottomNavigationBar: FutureBuilder<ScheduleSnapshot>(
      future: snapshot,
      builder: (context, state) => UsityTabs(
        index: tab,
        pending: state.data?.canReview == true
            ? state.data!.pendingReviewCount
            : 0,
        onSelect: (value) => setState(() => tab = value),
      ),
    ),
  );
}
