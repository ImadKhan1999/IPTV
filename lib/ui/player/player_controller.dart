import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../platform.dart';

/// What to play: a live channel list (for zapping), a movie, or a run of episodes.
class PlayRequest {
  PlayRequest._({
    required this.type,
    this.channels = const [],
    this.index = 0,
    this.movie,
    this.series,
    this.episodes = const [],
    this.startAt,
    this.catchup,
  });

  factory PlayRequest.live(List<Channel> channels, int index) =>
      PlayRequest._(type: ContentType.live, channels: channels, index: index < 0 ? 0 : index);

  factory PlayRequest.movie(Movie movie, {Duration? startAt}) =>
      PlayRequest._(type: ContentType.movie, movie: movie, startAt: startAt);

  factory PlayRequest.episodes(Series series, List<Episode> episodes, int index, {Duration? startAt}) =>
      PlayRequest._(type: ContentType.series, series: series, episodes: episodes, index: index, startAt: startAt);

  /// A catch-up recording of a past programme.
  factory PlayRequest.catchup(Channel channel, PlayableStream stream) =>
      PlayRequest._(type: ContentType.movie, channels: [channel], catchup: stream);

  final ContentType type;
  final List<Channel> channels;
  final int index;
  final Movie? movie;
  final Series? series;
  final List<Episode> episodes;
  final Duration? startAt;
  final PlayableStream? catchup;
}

/// Where playback is in its start-up, shown to the user while they wait.
enum PlayStage { resolving, connecting, buffering, playing, reconnecting, error }

enum VideoFit { contain, cover, fill }

/// Technical details for the info panel.
class StreamInfo {
  const StreamInfo(this.rows);

  final List<(String, String)> rows;
}

/// Owns one media_kit player and everything about the current stream: which item plays,
/// start-up status, reconnects, errors, volume and brightness, and watch progress.
///
/// The live preview pane and the full screen player share one controller, so going full
/// screen never restarts the stream.
class PlayerController extends ChangeNotifier {
  PlayerController({required this.session, required this.store, required PlayRequest request})
    : _request = request,
      _index = request.index {
    final settings = store.player;
    player = Player(
      // TV boxes often have 1-2 GB of RAM: keep the network buffers smaller there.
      configuration: PlayerConfiguration(
        title: 'iPTV',
        bufferSize: (AppPlatform.isTv ? 24 : 64) * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    video = VideoController(
      player,
      configuration: videoConfiguration(settings),
    );
    _tune(settings);

    _subs.add(player.stream.error.listen(_onError));
    _subs.add(player.stream.log.listen(_onLog));
    _subs.add(player.stream.completed.listen(_onCompleted));
    _subs.add(
      player.stream.playing.listen((p) {
        if (p && _stage != PlayStage.playing && !player.state.buffering) _setStage(PlayStage.playing);
        AppPlatform.setAutoPip(p && fullscreenActive, width: player.state.width, height: player.state.height);
      }),
    );
    _subs.add(
      player.stream.buffering.listen((b) {
        if (_stage == PlayStage.error) return;
        if (b && _stage == PlayStage.playing) _setStage(PlayStage.buffering);
        if (!b &&
            _opened &&
            (_stage == PlayStage.buffering || _stage == PlayStage.connecting) &&
            player.state.playing) {
          _setStage(PlayStage.playing);
        }
      }),
    );
    _subs.add(
      player.stream.bufferingPercentage.listen((p) {
        if (_stage == PlayStage.buffering || _stage == PlayStage.connecting) {
          bufferPercent = p;
          if (p > 0 && _stage == PlayStage.connecting) _stage = PlayStage.buffering;
          notifyListeners();
        }
      }),
    );
    _subs.add(
      player.stream.position.listen((pos) {
        // First decoded frame: the stream is really playing.
        if (pos > Duration.zero &&
            _stage != PlayStage.playing &&
            _stage != PlayStage.error &&
            !player.state.buffering) {
          _setStage(PlayStage.playing);
        }
      }),
    );
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) => saveProgress());
    open();
  }

  final Session session;
  final LibraryStore store;
  late final Player player;
  late final VideoController video;

  PlayRequest _request;
  int _index;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _progressTimer;
  Timer? _watchdog;
  int _openToken = 0;
  int _retries = 0;
  static const maxRetries = 4;
  String? _lastNetworkError;
  bool _disposed = false;

  /// False from the start of [open] until the new media is handed to mpv, so events from the
  /// previous stream cannot mark the new one as playing.
  bool _opened = false;

  PlayStage _stage = PlayStage.resolving;
  double bufferPercent = 0;
  String? errorMessage;
  String? errorCode;
  String title = '';
  List<EpgProgram> epg = const [];
  VideoFit fit = VideoFit.contain;
  double volume = 100;
  bool muted = false;

  /// Video brightness, -50 to 50 (mpv's brightness filter, works on every platform).
  double brightness = 0;

  /// True while the full screen player shows this controller (the preview hides its video).
  bool get fullscreenActive => _fullscreenActive;
  bool _fullscreenActive = false;
  set fullscreenActive(bool v) {
    if (v == _fullscreenActive) return;
    _fullscreenActive = v;
    // Called while routes build or dispose, so tell listeners on the next microtask.
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  PlayRequest get request => _request;
  int get index => _index;
  PlayStage get stage => _stage;
  bool get isLive => _request.type == ContentType.live && _request.catchup == null;
  Channel? get channel => isLive && _request.channels.isNotEmpty ? _request.channels[_index] : null;
  bool get hasNextEpisode => _request.type == ContentType.series && _index < _request.episodes.length - 1;

  String get statusText => switch (_stage) {
    PlayStage.resolving => 'Getting stream link…',
    PlayStage.connecting => 'Connecting to server…',
    PlayStage.buffering => bufferPercent > 0 ? 'Buffering ${bufferPercent.round()}%' : 'Buffering…',
    PlayStage.reconnecting => 'Connection lost. Reconnecting ($_retries/$maxRetries)…',
    PlayStage.playing => '',
    PlayStage.error => errorMessage ?? 'Playback failed.',
  };

  void _setStage(PlayStage s) {
    if (_disposed) return;
    _stage = s;
    if (s == PlayStage.playing) {
      _watchdog?.cancel();
      _retries = 0;
      bufferPercent = 0;
    }
    notifyListeners();
  }

  /// True when Android decodes straight onto the screen (MediaCodec, no GPU copy).
  static bool directOutput(PlayerSettings s) =>
      AppPlatform.isAndroid &&
      s.hardwareDecoding &&
      (s.videoOutput == 'direct' || (s.videoOutput == 'auto' && AppPlatform.isTv));

  /// How video gets to the screen. On Android TV the hardware decoder draws straight onto
  /// the display surface, so 2K/4K and HEVC 10-bit play without copying every frame through
  /// the GPU (which is what made big streams stutter or crash on low-memory boxes).
  static VideoControllerConfiguration videoConfiguration(PlayerSettings s) {
    if (directOutput(s)) {
      return const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec');
    }
    if (AppPlatform.isAndroid && s.hardwareDecoding) {
      // GPU renderer with hardware decoding; never fall back to slow software decode silently.
      return const VideoControllerConfiguration(hwdec: 'mediacodec-copy');
    }
    return VideoControllerConfiguration(enableHardwareAcceleration: s.hardwareDecoding);
  }

  /// mpv settings that make IPTV streams start fast and survive network hiccups.
  Future<void> _tune(PlayerSettings s) async {
    await _set('cache', 'yes');
    await _set('cache-secs', '${s.bufferSeconds}');
    await _set('demuxer-readahead-secs', '${s.bufferSeconds}');
    final tv = AppPlatform.isTv;
    // Enough for ~8 s of a 40 Mbit/s 4K stream without starving a 1.5 GB box.
    await _set('demuxer-max-bytes', '${(tv ? 48 : 64) * 1024 * 1024}');
    await _set('demuxer-max-back-bytes', '${(tv ? 4 : 16) * 1024 * 1024}');
    await _set('network-timeout', '15');
    // High-bitrate streams: drop a late frame instead of freezing, decode with all cores,
    // and let the decoder write frames directly (fewer copies of every 4K frame).
    await _set('framedrop', 'vo');
    await _set('vd-lavc-threads', '0');
    await _set('vd-lavc-dr', 'yes');
    await _set('hwdec-codecs', 'h264,hevc,mpeg2video,vp8,vp9,av1');
    await _set('stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5');
    await _set('hls-bitrate', 'max');
    await _set('tls-verify', 'no');
  }

  Future<void> _set(String k, String v) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      await native.setProperty(k, v);
    } catch (_) {}
  }

  Future<String?> _get(String k) async {
    final native = player.platform;
    if (native is! NativePlayer) return null;
    try {
      final v = await native.getProperty(k);
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Replaces what is playing (used by the live preview when another channel is picked).
  void replace(PlayRequest request) {
    saveProgress();
    _request = request;
    _index = request.index;
    _retries = 0;
    open();
  }

  Future<void> open() async {
    final token = ++_openToken;
    _watchdog?.cancel();
    _opened = false;
    // Silence the previous channel right away while the next link is fetched.
    if (player.state.playing || player.state.buffering) unawaited(player.stop());
    errorMessage = null;
    errorCode = null;
    _lastNetworkError = null;
    bufferPercent = 0;
    epg = const [];
    _stage = _retries > 0 ? PlayStage.reconnecting : PlayStage.resolving;
    title = _titleFor(_index);
    notifyListeners();
    try {
      final r = _request;
      final src = session.source;
      PlayableStream stream;
      Duration? startAt;
      if (r.catchup != null) {
        stream = r.catchup!;
      } else if (src == null) {
        throw SourceException('Not connected to a playlist.');
      } else {
        switch (r.type) {
          case ContentType.live:
            stream = await src.resolveChannel(r.channels[_index]);
          case ContentType.movie:
            stream = await src.resolveMovie(r.movie!);
            startAt = r.startAt;
          case ContentType.series:
            stream = await src.resolveEpisode(r.episodes[_index]);
            startAt = _index == r.index ? r.startAt : null;
        }
      }
      if (token != _openToken || _disposed) return;
      if (_stage != PlayStage.reconnecting) _stage = PlayStage.connecting;
      notifyListeners();
      // A stream that never produces a frame is reported instead of spinning forever.
      _watchdog = Timer(const Duration(seconds: 25), () {
        if (token == _openToken && _stage != PlayStage.playing) {
          _fail(_describeNetworkError() ?? 'The channel is not responding. It may be offline right now.', 'TIMEOUT');
        }
      });
      final media = Media(stream.url, httpHeaders: stream.headers, start: startAt);
      _opened = true;
      await player.open(media);
      _recordHistory();
      if (isLive) _loadEpg();
    } catch (e) {
      if (token == _openToken && !_disposed) {
        _fail(
          e is SourceException ? e.message : 'Could not get the stream link from your provider.',
          e is SourceException ? 'PROVIDER' : 'RESOLVE',
        );
      }
    }
  }

  String _titleFor(int i) {
    final r = _request;
    return switch (r.type) {
      ContentType.live => r.catchup?.title ?? r.channels[i].name,
      ContentType.movie => r.catchup?.title ?? r.movie!.name,
      ContentType.series => '${r.series!.name} · S${r.episodes[i].season}E${r.episodes[i].number}',
    };
  }

  void _fail(String message, String code) {
    _watchdog?.cancel();
    errorMessage = message;
    errorCode = code;
    _setStage(PlayStage.error);
  }

  /// Remembers the most telling network error from mpv's log (HTTP status, timeouts, DNS).
  void _onLog(PlayerLog log) {
    final t = log.text.toLowerCase();
    if (t.contains('http error') ||
        t.contains('server returned') ||
        t.contains('timed out') ||
        t.contains('connection refused') ||
        t.contains('failed to resolve') ||
        t.contains('name or service not known') ||
        t.contains('no such host') ||
        t.contains('invalid data found') ||
        t.contains('failed to recognize file format')) {
      _lastNetworkError = log.text.trim();
    }
  }

  String? _describeNetworkError() => describeStreamError(_lastNetworkError);

  void _onError(String message) {
    if (_disposed) return;
    debugPrint('Player error: $message');
    if (player.state.playing && _stage == PlayStage.playing) return; // recoverable warning
    final described = describeStreamError(_lastNetworkError ?? message);
    final fatal = _lastNetworkError != null && RegExp(r'\b(401|403|404|410)\b').hasMatch(_lastNetworkError!);
    if (isLive && !fatal && _retries < maxRetries) {
      _retry();
      return;
    }
    _fail(
      described ?? 'The stream could not be played. It may be offline or in an unsupported format.',
      httpCodeOf(_lastNetworkError ?? message) ?? 'PLAYBACK',
    );
  }

  void _onCompleted(bool done) {
    if (!done || _disposed) return;
    if (isLive) {
      _retry(); // a live stream that "ends" has dropped
    } else if (hasNextEpisode && store.player.autoPlayNextEpisode) {
      nextEpisode();
    }
  }

  void _retry() {
    _retries++;
    _stage = PlayStage.reconnecting;
    notifyListeners();
    Future<void>.delayed(Duration(seconds: _retries.clamp(1, 4)), () {
      if (!_disposed) open();
    });
  }

  void retry() {
    _retries = 0;
    open();
  }

  Future<void> _loadEpg() async {
    final c = channel;
    if (c == null) return;
    final list = await session.epgFor(c, limit: 3);
    if (!_disposed && channel?.id == c.id) {
      epg = list;
      notifyListeners();
    }
  }

  // Navigation --------------------------------------------------------------

  void zap(int delta) {
    if (!isLive) return;
    final n = _request.channels.length;
    if (n < 2) return;
    _index = (_index + delta) % n;
    if (_index < 0) _index += n;
    _retries = 0;
    open();
  }

  void jumpTo(int index) {
    if (index == _index || index < 0) return;
    _index = index;
    _retries = 0;
    open();
  }

  void nextEpisode() {
    if (!hasNextEpisode) return;
    saveProgress(finished: true);
    _index++;
    open();
  }

  void seekBy(int seconds) {
    if (isLive) return;
    final target = player.state.position + Duration(seconds: seconds);
    player.seek(target < Duration.zero ? Duration.zero : target);
  }

  // Picture -----------------------------------------------------------------

  void cycleFit() {
    fit = VideoFit.values[(fit.index + 1) % VideoFit.values.length];
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    volume = v.clamp(0, 100);
    muted = volume == 0;
    await player.setVolume(volume);
    notifyListeners();
  }

  Future<void> toggleMute() async {
    muted = !muted;
    await player.setVolume(muted ? 0 : (volume == 0 ? 60 : volume));
    if (!muted && volume == 0) volume = 60;
    notifyListeners();
  }

  Future<void> setBrightness(double v) async {
    brightness = v.clamp(-50, 50);
    await _set('brightness', '${brightness.round()}');
    notifyListeners();
  }

  /// Codec, resolution, frame rate, bitrate and buffer details for the info panel.
  Future<StreamInfo> streamInfo() async {
    final s = player.state;
    final vp = s.videoParams;
    final ap = s.audioParams;
    final results = await Future.wait([
      _get('video-codec'),
      _get('audio-codec-name'),
      _get('container-fps'),
      _get('estimated-vf-fps'),
      _get('video-bitrate'),
      _get('audio-bitrate'),
      _get('hwdec-current'),
      _get('demuxer-cache-duration'),
      _get('file-format'),
      _get('frame-drop-count'),
    ]);
    final [vCodec, aCodec, fps, realFps, vBitrate, aBitrate, hwdec, cache, format, drops] = results;
    String kbps(String? v) {
      final n = double.tryParse(v ?? '');
      if (n == null || n <= 0) return '—';
      return n >= 1e6 ? '${(n / 1e6).toStringAsFixed(1)} Mbps' : '${(n / 1e3).round()} kbps';
    }

    final w = vp.dw ?? s.width;
    final h = vp.dh ?? s.height;
    final f = double.tryParse(realFps ?? fps ?? '');
    return StreamInfo([
      ('Resolution', w != null && h != null && w > 0 ? '$w × $h${_qualityLabel(h)}' : '—'),
      ('Video codec', vCodec?.split(' ').first.toUpperCase() ?? '—'),
      ('Frame rate', f != null ? '${f.toStringAsFixed(f % 1 == 0 ? 0 : 2)} fps' : '—'),
      ('Video bitrate', kbps(vBitrate)),
      (
        'Audio',
        [
          aCodec?.toUpperCase(),
          ap.hrChannels ?? ap.channels,
          if (ap.sampleRate != null) '${(ap.sampleRate! / 1000).toStringAsFixed(1)} kHz',
        ].whereType<String>().join(' · ').ifEmpty('—'),
      ),
      ('Audio bitrate', kbps(aBitrate)),
      ('Decoder', hwdec == null || hwdec == 'no' ? 'Software' : 'Hardware ($hwdec)'),
      ('Container', format ?? '—'),
      ('Buffered', cache != null ? '${double.tryParse(cache)?.toStringAsFixed(1) ?? cache} s' : '—'),
      ('Dropped frames', drops ?? '0'),
    ]);
  }

  static String _qualityLabel(int h) => h >= 2000
      ? '  (4K)'
      : h >= 1000
      ? '  (Full HD)'
      : h >= 700
      ? '  (HD)'
      : '  (SD)';

  // History -------------------------------------------------------------------

  void _recordHistory() {
    final profileId = session.profile?.id;
    final r = _request;
    if (profileId == null || r.catchup != null) return;
    switch (r.type) {
      case ContentType.live:
        store.recordPlayback(SavedItem.channel(profileId, r.channels[_index]));
      case ContentType.movie:
        final existing = store.historyItem(profileId, ContentType.movie, r.movie!.id);
        store.recordPlayback(existing ?? SavedItem.movie(profileId, r.movie!));
      case ContentType.series:
        saveProgress();
    }
  }

  void saveProgress({bool finished = false}) {
    final profileId = session.profile?.id;
    final r = _request;
    if (profileId == null || isLive || r.catchup != null || !store.player.rememberPosition) return;
    final dur = player.state.duration.inMilliseconds;
    var pos = player.state.position.inMilliseconds;
    if (dur <= 0) return;
    if (finished) pos = dur;
    if (r.type == ContentType.movie) {
      store.recordPlayback(SavedItem.movie(profileId, r.movie!).withProgress(pos, dur));
    } else if (r.type == ContentType.series) {
      final e = r.episodes[_index];
      final s = r.series!;
      store.recordPlayback(
        SavedItem(
          profileId: profileId,
          type: ContentType.series,
          id: '${s.id}#${e.id}',
          name: '${s.name} · S${e.season}E${e.number}',
          image: e.image ?? s.poster,
          extra: {...s.extra, '_seriesName': s.name, if (s.poster != null) '_seriesPoster': s.poster!},
          positionMs: pos,
          durationMs: dur,
        ),
      );
    }
  }

  @override
  void dispose() {
    saveProgress();
    _disposed = true;
    _watchdog?.cancel();
    _progressTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    AppPlatform.setAutoPip(false);
    player.dispose();
    super.dispose();
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// The HTTP status in an ffmpeg/mpv error line, if any.
String? httpCodeOf(String? text) {
  if (text == null) return null;
  final m = RegExp(r'\b([45]\d\d)\b').firstMatch(text);
  return m?.group(1);
}

/// Turns ffmpeg/mpv network errors into a sentence a viewer understands.
String? describeStreamError(String? raw) {
  if (raw == null) return null;
  final t = raw.toLowerCase();
  final code = httpCodeOf(raw);
  switch (code) {
    case '404' || '410':
      return 'Channel is offline or was removed by the provider (error $code).';
    case '401' || '403':
      return 'The provider refused this stream (error $code). Your subscription may have expired, '
          'or too many devices are using the account.';
    case '429' || '458' || '509':
      return 'Too many connections on this account (error $code). Close the stream on another device.';
    case '500' || '502' || '503' || '504':
      return 'The provider\'s server has a problem (error $code). Try again in a minute.';
  }
  if (t.contains('timed out')) return 'The server is not responding (connection timed out).';
  if (t.contains('connection refused')) return 'The server refused the connection. The channel may be down.';
  if (t.contains('failed to resolve') || t.contains('name or service not known') || t.contains('no such host')) {
    return 'Cannot reach the server. Check your internet connection.';
  }
  if (t.contains('invalid data found') || t.contains('failed to recognize file format')) {
    return 'The stream sent no playable video. The channel may be down.';
  }
  return null;
}
