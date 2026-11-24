import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/sources/m3u_source.dart';
import 'package:iptv/data/library_store.dart';
import 'package:iptv/main.dart';
import 'package:iptv/ui/widgets/pair_card.dart';
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
  PairCard.debugFakeUrl = 'http://192.168.1.20:8765/?k=demo2026';
  testWidgets('first run shows the add-playlist form', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = LibraryStore.memory();
    await tester.pumpWidget(IptvApp(store: store, checkUpdates: false));
    await tester.pump();
    expect(find.text('Add your playlist'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    // Switching to Stalker shows the MAC field.
    await tester.tap(find.text('Stalker'));
    await tester.pump();
    expect(find.text('MAC address'), findsOneWidget);
  });

  testWidgets('TV layout: home tiles, then categories and channels with the D-pad', (tester) async {
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
    // Home screen with big tiles; Live TV is focused.
    expect(find.text('Live TV'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('News One'), findsWidgets);
    expect(find.text('Sports One'), findsWidgets);

    String? focusedText() {
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return null;
      final texts = <String>[];
      void visit(Element e) {
        final w = e.widget;
        if (w is Text && w.data != null) texts.add(w.data!);
        e.visitChildren(visit);
      }

      (ctx as Element).visitChildren(visit);
      return texts.join(' | ');
    }

    // Left jumps from the channels to the categories.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focusedText(), contains('All channels'));
    // Pick "Sports" with OK: focus lands on its first channel.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // Favorites
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // first real category
    await tester.pumpAndSettle();
    final cat = focusedText();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(focusedText(), isNot(cat));
    expect(focusedText(), anyOf(contains('News One'), contains('Sports One')));
    // Up from the first category climbs out of the pane to the top bar.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    }
    await tester.pumpAndSettle();
    expect(focusedText(), anyOf(contains('Home'), contains('Live TV'), contains('Movies')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // Back returns to the categories, Back again to the home screen.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(focusedText(), cat);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Channels and TV guide'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('categories can be pinned to the top', (tester) async {
    final store = LibraryStore.memory();
    final cats = [
      const Category(id: 'a', name: 'A', type: ContentType.live),
      const Category(id: 'b', name: 'B', type: ContentType.live),
      const Category(id: 'c', name: 'C', type: ContentType.live),
    ];
    await store.toggleFavoriteCategory('p', ContentType.live, 'c');
    await store.toggleFavoriteCategory('p', ContentType.live, 'b');
    expect(store.favoriteCategoriesFirst('p', ContentType.live, cats).map((c) => c.id), ['c', 'b', 'a']);
    expect(store.favoriteCategoriesFirst('p', ContentType.movie, cats).map((c) => c.id), ['a', 'b', 'c']);
    await store.toggleFavoriteCategory('p', ContentType.live, 'c');
    expect(store.isFavoriteCategory('p', ContentType.live, 'c'), isFalse);
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
