// Renders README screenshots with the real brand fonts:
//   flutter test tool/screenshots_test.dart --update-goldens
// Not part of the normal test run (goldens differ between platforms).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/m3u_source.dart';
import 'package:iptv/data/library_store.dart';
import 'package:iptv/main.dart';
import 'package:iptv/ui/widgets/pair_card.dart';
import 'package:iptv/ui/player/live_overlay.dart';
import 'package:iptv/ui/player/player_screen.dart';
import 'package:iptv/state/session.dart';
import 'package:iptv/ui/screens/home_shell.dart';
import 'package:iptv/ui/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

Future<void> _font(String family, String path) async {
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

final _m3u = StringBuffer('#EXTM3U\n')
  ..writeAll([
    for (final (i, (g, n)) in [
      ('News', 'World News 24'),
      ('News', 'Business Today'),
      ('Sports', 'Sports Arena HD'),
      ('Sports', 'Football Live'),
      ('Sports', 'Tennis Channel'),
      ('Movies', 'Cinema Classics'),
      ('Kids', 'Cartoon Planet'),
      ('Kids', 'Junior Learning'),
      ('Documentary', 'Nature & Wildlife'),
      ('Documentary', 'Science Now'),
      ('Music', 'Hits Radio TV'),
      ('Entertainment', 'Comedy Central Plus'),
    ].indexed)
      '#EXTINF:-1 tvg-chno="${i + 101}" group-title="$g" ${i % 3 == 0 ? 'catchup="default" catchup-days="3" catchup-source="x"' : ''},$n\nhttp://x/$i.ts\n',
    for (var i = 0; i < 12; i++) '#EXTINF:-1 group-title="Action",Movie Title ${i + 1}\nhttp://x/movie/u/p/$i.mp4\n',
  ]);

void main() {
  PairCard.debugFakeUrl = 'http://192.168.1.20:8765/?k=demo2026';
  setUpAll(() async {
    final sdk =
        Platform.environment['FLUTTER_ROOT'] ??
        File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
    await _font('Inter', 'assets/fonts/Inter.ttf');
    await _font('PlusJakartaSans', 'assets/fonts/PlusJakartaSans.ttf');
    await _font('MaterialIcons', '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  });

  Future<void> shoot(WidgetTester tester, Size size, Widget app, String name, {Future<void> Function()? before}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    // Decode the brand images for real (widget tests skip image decoding otherwise).
    await tester.runAsync(() async {
      final ctx = tester.element(find.byType(Scaffold).first);
      await precacheImage(const AssetImage('assets/brand/app_icon.png'), ctx);
      await precacheImage(const AssetImage('assets/brand/imadlabs_symbol.png'), ctx);
    });
    await tester.pumpAndSettle();
    if (before != null) await before();
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../docs/screenshots/$name.png'));
  }

  Future<(LibraryStore, Session)> connected() async {
    final store = LibraryStore.memory();
    final profile = PlaylistProfile(id: 'p', name: 'My Provider', kind: SourceKind.m3u, url: 'x');
    store.upsertProfile(profile);
    final source = M3uSource(profile)..loadFromText(_m3u.toString());
    final session = Session(store)
      ..source = source
      ..state = SessionState.ready;
    for (final type in ContentType.values) {
      session.counts[type] = (await source.categoryCounts(type))!;
    }
    return (store, session);
  }

  Widget wrap(LibraryStore store, Session session) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider.value(value: session),
    ],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(), home: const HomeShell()),
  );

  testWidgets('welcome on a 1080p TV (960x540 logical)', (t) => shoot(t, const Size(960, 540), IptvApp(store: LibraryStore.memory(), checkUpdates: false), 'welcome-tv'));

  testWidgets('welcome', (t) => shoot(t, const Size(1920, 1080), IptvApp(store: LibraryStore.memory(), checkUpdates: false), 'welcome'));

  testWidgets('home', (t) async {
    final (store, session) = await connected();
    await shoot(t, const Size(1920, 1080), wrap(store, session), 'home');
  });

  testWidgets('home on a 1080p TV (960x540 logical)', (t) async {
    final (store, session) = await connected();
    await shoot(t, const Size(960, 540), wrap(store, session), 'home-tv');
  });

  testWidgets('live tv', (t) async {
    final (store, session) = await connected();
    await shoot(
      t,
      const Size(1920, 1080),
      wrap(store, session),
      'live-tv',
      before: () async {
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      },
    );
  });

  testWidgets('live tv on a 1080p TV', (t) async {
    final (store, session) = await connected();
    await shoot(
      t,
      const Size(960, 540),
      wrap(store, session),
      'live-tv-small',
      before: () async {
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
      },
    );
  });

  testWidgets('movies', (t) async {
    final (store, session) = await connected();
    await shoot(
      t,
      const Size(1920, 1080),
      wrap(store, session),
      'movies',
      before: () async {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      },
    );
  });

  testWidgets('live overlay (set-top box style)', (t) async {
    final (store, session) = await connected();
    final channels = await session.source!.channels(Category.allId);
    final target = _FakeLive(PlayRequest.live(channels, 2));
    await shoot(
      t,
      const Size(1920, 1080),
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: session),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Stand-in for the playing video.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF3B6E8F), Color(0xFF8F5A3B), Color(0xFF2E4A2E)],
                    ),
                  ),
                  child: Center(
                    child: Text('▶  Live video keeps playing', style: TextStyle(fontSize: 48, color: Colors.white70)),
                  ),
                ),
                LiveOverlay(controller: target, onClose: () {}),
              ],
            ),
          ),
        ),
      ),
      'live-overlay',
      before: () async {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      },
    );
  });

  testWidgets('phone', (t) async {
    final (store, session) = await connected();
    await shoot(t, const Size(420, 900), wrap(store, session), 'phone-live');
  });
}

class _FakeLive implements LiveTarget {
  _FakeLive(this.request) : index = request.index;

  @override
  PlayRequest request;
  @override
  int index;

  @override
  Channel? get channel => request.channels[index];

  @override
  void replace(PlayRequest r) {
    request = r;
    index = r.index;
  }
}
