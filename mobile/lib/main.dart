import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'data/usity_api.dart';
import 'features/schedule/live_home_page.dart';

import 'features/schedule/schedule_page.dart';

void main() => runApp(const UsityApp());

class UsityApp extends StatelessWidget {
  const UsityApp({super.key});

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final lessons = [
      LessonOccurrence(
        id: 'demo-math',
        date: today,
        startTime: '09:00',
        endTime: '10:30',
        subject: 'Математика',
        teacher: 'И. А. Иванова',
        location: 'Аудитория 401',
        homework: const [HomeworkItem(text: 'Решить номера 4 и 5')],
      ),
      LessonOccurrence(
        id: 'demo-python',
        date: today,
        startTime: '10:45',
        endTime: '12:15',
        subject: 'Основы программирования',
        teacher: 'Е. А. Роганов',
        location: 'Аудитория 205',
        homework: const [
          HomeworkItem(text: 'Подготовить практическую работу по спискам'),
        ],
      ),
    ];
    const seed = Color(0xFF087F79);
    return MaterialApp(
      title: 'USITY',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home:
          kDebugMode &&
              const String.fromEnvironment('USITY_SESSION_TOKEN').isNotEmpty
          ? LiveHomePage(
              api: UsityApi(
                baseUrl: const String.fromEnvironment(
                  'USITY_API_URL',
                  defaultValue: 'http://127.0.0.1:8000',
                ),
                token: const String.fromEnvironment('USITY_SESSION_TOKEN'),
              ),
            )
          : Banner(
              message: 'Демо',
              location: BannerLocation.topEnd,
              child: HomePage(lessons: lessons, today: today),
            ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.lessons, required this.today});
  final List<LessonOccurrence> lessons;
  final DateTime today;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    const titles = ['Расписание', 'Предметы', 'Личные задачи', 'Настройки'];
    return Scaffold(
      body: selectedTab == 0
          ? SchedulePage(today: widget.today, lessons: widget.lessons)
          : SafeArea(child: Center(child: Text(titles[selectedTab]))),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: (index) => setState(() => selectedTab = index),
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
}
