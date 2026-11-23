import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/m3u_source.dart';
import 'package:iptv/data/library_store.dart';
import 'package:iptv/main.dart';
import 'package:iptv/state/session.dart';
import 'package:iptv/ui/screens/home_shell.dart';
import 'package:iptv/ui/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

const _m3u = '''#EXTM3U
#EXTINF:-1 tvg-chno="1" group-title="News",News One
http://x/1.ts
#EXTINF:-1 tvg-chno="2" group-title="Sports",Sports One
http://x/2.ts
#EXTINF:-1 group-title="Movies",Film (2020)
http://x/movie/u/p/3.mp4
''';

Widget _app(LibraryStore store, Session session, Widget home) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: store),
    ChangeNotifierProvider.value(value: session),
  ],
  child: MaterialApp(theme: buildTheme(), home: home),
);

void main() {
  testWidgets('first run shows the add-playlist form', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = LibraryStore.memory();
    await tester.pumpWidget(IptvApp(store: store));
    await tester.pump();
    expect(find.text('Add your playlist'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    // Switching to Stalker shows the MAC field.
    await tester.tap(find.text('Stalker'));
    await tester.pump();
    expect(find.text('MAC address'), findsOneWidget);
  });

  testWidgets('TV layout: rail, categories and channels, D-pad moves focus', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = LibraryStore.memory();
    final profile = PlaylistProfile(id: 'p', name: 'Test', kind: SourceKind.m3u, url: 'x');
    await store.upsertProfile(profile);
    final session = Session(store)
      ..source = (M3uSource(profile)..loadFromText(_m3u))
      ..state = SessionState.ready;

    await tester.pumpWidget(_app(store, session, const HomeShell()));
    await tester.pumpAndSettle();
    expect(find.text('Live TV'), findsOneWidget);
    expect(find.text('Movies'), findsWidgets);
    expect(find.text('News One'), findsOneWidget);
    expect(find.text('Sports One'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout uses a bottom bar', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = LibraryStore.memory();
    final profile = PlaylistProfile(id: 'p', name: 'Test', kind: SourceKind.m3u, url: 'x');
    await store.upsertProfile(profile);
    final session = Session(store)
      ..source = (M3uSource(profile)..loadFromText(_m3u))
      ..state = SessionState.ready;
    await tester.pumpWidget(_app(store, session, const HomeShell()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('News One'), findsOneWidget);
  });
}
