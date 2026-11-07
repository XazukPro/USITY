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
import 'features/materials/materials_page.dart';
import 'domain/group_setup.dart';
import 'features/onboarding/owner_wizard.dart';

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
  bool demoOpen = true;
  late bool notifications =
      widget.preferences?.getBool('demo.notifications') ?? true;
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
        notifications: notifications,
        setNotifications: (value) {
          setState(() => notifications = value);
          widget.preferences?.setBool('demo.notifications', value);
        },
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
              child: demoOpen
                  ? HomePage(
                      today: today,
                      onExit: () => setState(() => demoOpen = false),
                    )
                  : Scaffold(
                      body: Center(
                        child: FilledButton(
                          onPressed: () => setState(() => demoOpen = true),
                          child: const Text('Открыть демо USITY'),
                        ),
                      ),
                    ),
            ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.today, this.onExit, this.group});
  final GroupSetup? group;
  final VoidCallback? onExit;
  final DateTime today;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedTab = 0;
  late final plan = widget.group?.createPlan() ?? samplePlan(widget.today);
  Future<void> createGroup() async {
    final group = await Navigator.push<GroupSetup>(
      context,
      MaterialPageRoute(builder: (_) => OwnerWizard(today: widget.today)),
    );
    if (!mounted || group == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (c) => Banner(
          message: 'Демо',
          location: BannerLocation.topEnd,
          child: HomePage(
            today: widget.today,
            group: group,
            onExit: () => Navigator.pop(c),
          ),
        ),
      ),
    );
  }

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
          PlannerPage(
            today: widget.today,
            plan: plan,
            initialDay: widget.group?.firstDay(plan, widget.today),
          ),
          DemoTasks(plan: plan),
          MaterialsPage(plan: plan),
          SettingsPage(
            plan: plan,
            onExit: widget.onExit,
            group: widget.group,
            onCreateGroup: widget.group == null ? createGroup : null,
          ),
        ],
      ),
      bottomNavigationBar: UsityTabs(
        index: selectedTab,
        onSelect: (index) => setState(() => selectedTab = index),
      ),
    );
  }
}
