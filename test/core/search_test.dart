import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/epg/xmltv.dart';
import 'package:iptv/core/models.dart';
import 'package:iptv/core/search.dart';

void main() {
  test('matches words in any order, ignoring case, accents and punctuation', () {
    final q = SearchQuery('news BBC');
    expect(q.matches('BBC World News HD'), isTrue);
    expect(q.matches('BBC One'), isFalse);
    expect(SearchQuery('cafe').matches('Café TV'), isTrue);
    expect(SearchQuery('sky sports').matches('UK: SKY-SPORTS F1'), isTrue);
    expect(SearchQuery('  ').isEmpty, isTrue);
  });

  test('ranks exact and prefix matches first', () {
    final q = SearchQuery('cnn');
    final sorted = q.filter(['World CNN', 'CNN International', 'CNN'], (s) => s);
    expect(sorted, ['CNN', 'CNN International', 'World CNN']);
  });

  test('finds programmes on now and later today in the guide', () {
    final now = DateTime(2026, 1, 1, 20);
    EpgProgram p(String ch, int h, String t) => EpgProgram(
      channelId: ch,
      start: now.add(Duration(hours: h)),
      end: now.add(Duration(hours: h + 1)),
      title: t,
    );
    final guide = EpgGuide({
      'a': [p('a', -2, 'Match of the Day'), p('a', 0, 'Champions League Live'), p('a', 3, 'League Highlights')],
      'b': [p('b', 30, 'League Replay')],
    }, {});
    final hits = guide.search(SearchQuery('league').matches, now: now.add(const Duration(minutes: 10)));
    expect(hits.map((e) => e.title), ['Champions League Live', 'League Highlights']);
  });
}
