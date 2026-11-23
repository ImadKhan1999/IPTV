import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/data/library_store.dart';

void main() {
  test('favorites toggle per playlist and type', () async {
    final store = LibraryStore.memory();
    const c = Channel(id: '1', name: 'News');
    await store.toggleFavorite(SavedItem.channel('a', c));
    expect(store.isFavorite('a', ContentType.live, '1'), isTrue);
    expect(store.isFavorite('b', ContentType.live, '1'), isFalse);
    await store.toggleFavorite(SavedItem.channel('a', c));
    expect(store.favorites('a'), isEmpty);
  });

  test('saved items round-trip through JSON', () {
    const c = Channel(id: '1', name: 'News', number: 7, epgId: 'n', catchupDays: 3, headers: {'User-Agent': 'x'});
    final back = SavedItem.fromJson(SavedItem.channel('a', c).toJson()).toChannel();
    expect(back.number, 7);
    expect(back.epgId, 'n');
    expect(back.catchupDays, 3);
    expect(back.headers['User-Agent'], 'x');
  });

  test('PIN and category locks', () async {
    final store = LibraryStore.memory();
    expect(store.hasPin, isFalse);
    await store.setPin('1234');
    expect(store.checkPin('1234'), isTrue);
    expect(store.checkPin('0000'), isFalse);
    const cat = Category(id: '5', name: 'Kids', type: ContentType.live);
    expect(store.isCategoryLocked('a', cat), isFalse);
    await store.toggleCategoryLock('a', cat);
    expect(store.isCategoryLocked('a', cat), isTrue);
    const adult = Category(id: '6', name: 'Adult', type: ContentType.live, isAdult: true);
    expect(store.isCategoryLocked('a', adult), isTrue);
  });

  test('history keeps progress and newest first', () async {
    final store = LibraryStore.memory();
    const m = Movie(id: 'm', name: 'Film');
    await store.recordPlayback(SavedItem.movie('a', m).withProgress(30000, 60000));
    expect(store.historyItem('a', ContentType.movie, 'm')!.progress, 0.5);
  });

  test('removing a playlist removes its favorites', () async {
    final store = LibraryStore.memory();
    await store.upsertProfile(PlaylistProfile(id: 'a', name: 'A', kind: SourceKind.m3u, url: 'u'));
    await store.toggleFavorite(SavedItem.channel('a', const Channel(id: '1', name: 'x')));
    await store.removeProfile('a');
    expect(store.favorites('a'), isEmpty);
    expect(store.profiles, isEmpty);
  });
}
