import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'shell/settings.dart';
import 'shell/tabs.dart';

import 'data/usity_api.dart';
import 'features/schedule/live_home_page.dart';

import 'domain/day_plan.dart';
import 'features/schedule/planner_page.dart';
import 'features/schedule/demo_tasks.dart';

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
    return MaterialApp(
      title: 'USITY',
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
              child: HomePage(today: today),
            ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.today});
  final DateTime today;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedTab = 0;
  late final plan = samplePlan(widget.today);
  @override
  void dispose() {
    plan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: selectedTab,
        children: [
          PlannerPage(today: widget.today, plan: plan),
          DemoTasks(plan: plan),
          SafeArea(child: Center(child: Text(tabLabels[2]))),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: UsityTabs(
        index: selectedTab,
        onSelect: (index) => setState(() => selectedTab = index),
      ),
    );
  }
}
