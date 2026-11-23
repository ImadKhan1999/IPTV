import 'package:flutter_test/flutter_test.dart';
import 'package:iptv/ui/player/player_controller.dart';
import 'package:iptv/ui/widgets/common.dart';

void main() {
  test('explains HTTP errors from the stream', () {
    expect(describeStreamError('tcp: HTTP error 404 Not Found'), contains('offline'));
    expect(describeStreamError('Server returned 403 Forbidden (access denied)'), contains('subscription'));
    expect(describeStreamError('HTTP error 458'), contains('Too many connections'));
    expect(describeStreamError('HTTP error 503 Service Unavailable'), contains('server'));
    expect(httpCodeOf('Server returned 401 Unauthorized'), '401');
  });

  test('explains network failures', () {
    expect(describeStreamError('Connection timed out'), contains('not responding'));
    expect(describeStreamError('Connection refused'), contains('refused'));
    expect(describeStreamError('Failed to resolve hostname x'), contains('internet'));
    expect(describeStreamError('Invalid data found when processing input'), contains('no playable video'));
    expect(describeStreamError('something odd'), isNull);
    expect(describeStreamError(null), isNull);
  });

  test('formats counts with thousands separators', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(1234), '1,234');
    expect(formatCount(1234567), '1,234,567');
  });
}
