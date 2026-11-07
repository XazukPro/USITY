import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'shell/settings.dart';
import 'shell/tabs.dart';

import 'data/usity_api.dart';
import 'features/schedule/live_home_page.dart';

import 'features/schedule/schedule_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final font in ['Onest', 'JetBrainsMono']) {
      yield LicenseEntryWithLineBreaks([
        font,
      ], await rootBundle.loadString('assets/fonts/$font-OFL.txt'));
    }
  });
  runApp(UsityApp(preferences: await SharedPreferences.getInstance()));
}

class UsityApp extends StatefulWidget {
  const UsityApp({super.key, this.preferences});
  final SharedPreferences? preferences;
  @override
  State<UsityApp> createState() => _UsityAppState();
}

class _UsityAppState extends State<UsityApp> {
  late final api = UsityApi(
    baseUrl: const String.fromEnvironment(
      'USITY_API_URL',
      defaultValue: 'http://127.0.0.1:8000',
    ),
    token: const String.fromEnvironment('USITY_SESSION_TOKEN'),
  );
  late ThemeMode mode = ThemeMode.values.firstWhere(
    (v) => v.name == widget.preferences?.getString('themeMode'),
    orElse: () => ThemeMode.system,
  );

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
    return MaterialApp(
      title: 'USITY',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: usityTheme(Brightness.light),
      darkTheme: usityTheme(Brightness.dark),
      builder: (_, child) => ThemePreference(
        mode: mode,
        select: (value) {
          setState(() => mode = value);
          widget.preferences?.setString('themeMode', value.name);
        },
        child: child!,
      ),
      home:
          kDebugMode &&
              const String.fromEnvironment('USITY_SESSION_TOKEN').isNotEmpty
          ? LiveHomePage(api: api)
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
    return Scaffold(
      body: selectedTab == 0
          ? SchedulePage(today: widget.today, lessons: widget.lessons)
          : selectedTab == 3
          ? const SettingsPage()
          : SafeArea(child: Center(child: Text(tabLabels[selectedTab]))),
      bottomNavigationBar: UsityTabs(
        index: selectedTab,
        onSelect: (index) => setState(() => selectedTab = index),
      ),
    );
  }
}
