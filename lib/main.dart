import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'data/disk_cache.dart';
import 'data/library_store.dart';
import 'state/session.dart';
import 'ui/platform.dart';
import 'ui/screens/home_shell.dart';
import 'ui/screens/welcome_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await AppPlatform.init();
  final store = await LibraryStore.open();
  final cache = await DiskCache.open();
  runApp(IptvApp(store: store, cache: cache));
}

class IptvApp extends StatelessWidget {
  const IptvApp({super.key, required this.store, this.cache});

  final LibraryStore store;
  final DiskCache? cache;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider(create: (_) => Session(store, cache: cache)),
      ],
      child: MaterialApp(
        title: 'iPTV by ImadLabs',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        darkTheme: buildTheme(),
        themeMode: ThemeMode.dark,
        // Remotes send "select"/"enter"; make sure both activate buttons everywhere.
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
        },
        home: const RootGate(),
      ),
    );
  }
}

/// Shows the welcome / add-playlist flow until a playlist exists, then the main shell.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = context.read<LibraryStore>();
      final p = store.activeProfile;
      if (p != null) context.read<Session>().connect(p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    if (store.profiles.isEmpty) return const WelcomeScreen();
    return const HomeShell();
  }
}
