import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/core/epg/xmltv.dart';

const _xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="test">
  <channel id="bbc1.uk"><display-name>BBC One HD</display-name><icon src="http://x/y.png"/></channel>
  <programme start="20260102200000 +0000" stop="20260102210000 +0000" channel="bbc1.uk">
    <title lang="en">News &amp; Weather</title><desc lang="en">Latest headlines.</desc>
  </programme>
  <programme start="20260102190000 +0100" stop="20260102200000 +0100" channel="bbc1.uk">
    <title><![CDATA[Earlier Show]]></title>
  </programme>
  <programme start="20260102210000 +0000" stop="20260102220000 +0000" channel="bbc1.uk"><title>Film</title></programme>
</tv>''';

void main() {
  test('parses XMLTV time with offsets', () {
    expect(parseXmltvTime('20260102200000 +0000')!.toUtc(), DateTime.utc(2026, 1, 2, 20));
    expect(parseXmltvTime('20260102200000 +0130')!.toUtc(), DateTime.utc(2026, 1, 2, 18, 30));
    expect(parseXmltvTime('20260102200000 -0500')!.toUtc(), DateTime.utc(2026, 1, 3, 1));
    expect(parseXmltvTime('bad'), isNull);
  });

  test('parses programmes sorted by start time, with entities and CDATA', () {
    final g = EpgGuide.parse(_xml);
    final list = g.programsFor('bbc1.uk');
    expect(list.map((p) => p.title), ['Earlier Show', 'News & Weather', 'Film']);
    expect(list[1].description, 'Latest headlines.');
  });

  test('finds channels by display name when there is no id', () {
    final g = EpgGuide.parse(_xml);
    expect(g.programsFor(null, channelName: 'bbc one hd'), hasLength(3));
  });

  test('upcoming starts from the programme on air', () {
    final g = EpgGuide.parse(_xml);
    final now = DateTime.utc(2026, 1, 2, 20, 30).toLocal();
    final up = g.upcoming('bbc1.uk', now: now);
    expect(up.first.title, 'News & Weather');
    expect(up.first.isLiveAt(now), isTrue);
    expect(up.first.progressAt(now), closeTo(0.5, 0.01));
  });
}
