import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';

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

enum _Fit { contain, cover, fill }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.request});

  final PlayRequest request;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Session _session = context.read<Session>();
  late final LibraryStore _store = context.read<LibraryStore>();
  late final Player _player;
  late final VideoController _video;
  final _subs = <StreamSubscription<Object?>>[];
  final _rootFocus = FocusNode(debugLabel: 'player');
  final _playFocus = FocusNode(debugLabel: 'play-button');

  late int _index = widget.request.index;
  String _title = '';
  String? _error;
  bool _opening = true;
  bool _controls = true;
  bool _channelList = false;
  bool _fullscreen = false;
  _Fit _fit = _Fit.contain;
  Timer? _hideTimer;
  Timer? _progressTimer;
  Timer? _numberTimer;
  String _typedNumber = '';
  int _retries = 0;
  List<EpgProgram> _epg = const [];
  int _openToken = 0;

  bool get _isLive => widget.request.type == ContentType.live && widget.request.catchup == null;
  Channel? get _channel => _isLive ? widget.request.channels[_index] : null;

  @override
  void initState() {
    super.initState();
    final settings = _store.player;
    _player = Player(
      configuration: PlayerConfiguration(title: 'iPTV', bufferSize: 64 * 1024 * 1024, logLevel: MPVLogLevel.warn),
    );
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(enableHardwareAcceleration: settings.hardwareDecoding),
    );
    _tunePlayer(settings);

    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(
      _player.stream.completed.listen((done) {
        if (!done) return;
        if (_isLive) {
          _retry(); // a live stream that "ends" dropped; reconnect
        } else if (widget.request.type == ContentType.series &&
            settings.autoPlayNextEpisode &&
            _index < widget.request.episodes.length - 1) {
          _saveProgress(finished: true);
          _index++;
          _open();
        }
      }),
    );
    _subs.add(
      _player.stream.playing.listen((p) {
        if (p && _opening && mounted) setState(() => _opening = false);
        _syncAutoPip(p);
      }),
    );
    _subs.add(_player.stream.width.listen((_) => _syncAutoPip(_player.state.playing)));
    AppPlatform.pipActive.addListener(_onPipChanged);

    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());

    // Phones go landscape full screen; TVs and desktops already are.
    if (AppPlatform.isAndroid && !AppPlatform.isTv) defaultEnterNativeFullscreen();
    _open();
    _scheduleHide();
  }

  /// mpv settings that make IPTV streams start fast and survive network hiccups.
  Future<void> _tunePlayer(PlayerSettings s) async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    Future<void> set(String k, String v) async {
      try {
        await native.setProperty(k, v);
      } catch (_) {}
    }

    await set('cache', 'yes');
    await set('cache-secs', '${s.bufferSeconds}');
    await set('demuxer-readahead-secs', '${s.bufferSeconds}');
    await set('demuxer-max-bytes', '${64 * 1024 * 1024}');
    await set('demuxer-max-back-bytes', '${16 * 1024 * 1024}');
    await set('network-timeout', '20');
    await set('stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5');
    await set('hls-bitrate', 'max');
    await set('tls-verify', 'no');
  }

  Future<void> _open() async {
    final token = ++_openToken;
    setState(() {
      _opening = true;
      _error = null;
      _epg = const [];
    });
    try {
      final r = widget.request;
      final src = _session.source;
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
      if (token != _openToken || !mounted) return;
      _title = switch (r.type) {
        ContentType.live => r.catchup?.title ?? r.channels[_index].name,
        ContentType.movie => r.catchup?.title ?? r.movie!.name,
        ContentType.series => '${r.series!.name} · S${r.episodes[_index].season}E${r.episodes[_index].number}',
      };
      setState(() {});
      await _player.open(Media(stream.url, httpHeaders: stream.headers, start: startAt));
      _recordHistory();
      if (_isLive) _loadEpg();
    } catch (e) {
      if (token == _openToken && mounted) {
        setState(() {
          _opening = false;
          _error = e is SourceException ? e.message : 'Could not play this stream.';
        });
      }
    }
  }

  void _onError(String message) {
    if (!mounted) return;
    debugPrint('Player error: $message');
    if (_isLive && _retries < 5) {
      _retry();
      return;
    }
    if (_player.state.playing) return; // a recoverable warning
    setState(() {
      _opening = false;
      _error = 'The stream could not be played. It may be offline or need a different format.';
    });
  }

  void _retry() {
    _retries++;
    Future<void>.delayed(Duration(seconds: _retries.clamp(1, 5)), () {
      if (mounted) _open();
    });
  }

  Future<void> _loadEpg() async {
    final c = _channel;
    if (c == null) return;
    final list = await _session.epgFor(c, limit: 3);
    if (mounted && _channel?.id == c.id) setState(() => _epg = list);
  }

  void _recordHistory() {
    final profileId = _session.profile?.id;
    if (profileId == null) return;
    final r = widget.request;
    if (r.catchup != null) return;
    switch (r.type) {
      case ContentType.live:
        _store.recordPlayback(SavedItem.channel(profileId, r.channels[_index]));
      case ContentType.movie:
        final existing = _store.historyItem(profileId, ContentType.movie, r.movie!.id);
        _store.recordPlayback(existing ?? SavedItem.movie(profileId, r.movie!));
      case ContentType.series:
        _saveProgress();
    }
  }

  void _saveProgress({bool finished = false}) {
    final profileId = _session.profile?.id;
    final r = widget.request;
    if (profileId == null || _isLive || r.catchup != null || !_store.player.rememberPosition) return;
    final dur = _player.state.duration.inMilliseconds;
    var pos = _player.state.position.inMilliseconds;
    if (dur <= 0) return;
    if (finished) pos = dur;
    if (r.type == ContentType.movie) {
      _store.recordPlayback(SavedItem.movie(profileId, r.movie!).withProgress(pos, dur));
    } else if (r.type == ContentType.series) {
      final e = r.episodes[_index];
      final s = r.series!;
      _store.recordPlayback(
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

  void _syncAutoPip(bool playing) {
    AppPlatform.setAutoPip(playing, width: _player.state.width, height: _player.state.height);
  }

  void _onPipChanged() {
    if (mounted) setState(() => _controls = !AppPlatform.pipActive.value);
  }

  // Controls ---------------------------------------------------------------

  void _showControls() {
    if (!_controls) {
      setState(() => _controls = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _playFocus.requestFocus());
    }
    _scheduleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() => _controls = false);
    _rootFocus.requestFocus();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _player.state.playing && !_channelList) _hideControls();
    });
  }

  void _zap(int delta) {
    if (!_isLive) return;
    final n = widget.request.channels.length;
    if (n < 2) return;
    _index = (_index + delta) % n;
    if (_index < 0) _index += n;
    _retries = 0;
    _open();
    _showControls();
  }

  void _jumpToChannel(int index) {
    if (index == _index) return;
    _index = index;
    _retries = 0;
    _open();
  }

  void _seek(int seconds) {
    if (_isLive) return;
    final target = _player.state.position + Duration(seconds: seconds);
    _player.seek(target < Duration.zero ? Duration.zero : target);
    _showControls();
  }

  void _onNumber(String digit) {
    if (!_isLive) return;
    _numberTimer?.cancel();
    setState(() => _typedNumber += digit);
    _numberTimer = Timer(const Duration(milliseconds: 1500), () {
      final n = int.tryParse(_typedNumber);
      setState(() => _typedNumber = '');
      if (n == null) return;
      final channels = widget.request.channels;
      var i = channels.indexWhere((c) => c.number == n);
      if (i < 0 && n >= 1 && n <= channels.length) i = n - 1;
      if (i >= 0) _jumpToChannel(i);
    });
  }

  Future<void> _toggleFullscreen() async {
    if (!AppPlatform.isDesktop) return;
    _fullscreen = !_fullscreen;
    _fullscreen ? await defaultEnterNativeFullscreen() : await defaultExitNativeFullscreen();
    setState(() {});
  }

  void _cycleFit() => setState(() => _fit = _Fit.values[(_fit.index + 1) % _Fit.values.length]);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    // Media and channel keys work whether or not the controls are visible.
    if (k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.space) {
      _player.playOrPause();
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlay) {
      _player.play();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPause) {
      _player.pause();
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaStop) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _seek(30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _seek(-30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.pageUp) {
      _zap(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.pageDown) {
      _zap(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      _isLive ? _zap(1) : _seek(60);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      _isLive ? _zap(-1) : _seek(-60);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF || k == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.info || k == LogicalKeyboardKey.keyI) {
      _controls ? _hideControls() : _showControls();
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (_isLive && ch != null && RegExp(r'^\d$').hasMatch(ch)) {
      _onNumber(ch);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.browserBack) {
      if (_channelList) {
        setState(() => _channelList = false);
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (_controls && _player.state.playing) {
        _hideControls();
        return KeyEventResult.handled;
      }
      if (_fullscreen) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // let the route pop
    }

    // With the controls hidden, the D-pad drives playback directly.
    if (!_controls && !_channelList) {
      if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
        _showControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        _isLive ? _zap(-1) : _showControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        _isLive ? _zap(1) : _showControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowLeft) {
        if (_isLive) {
          setState(() => _channelList = true);
        } else {
          _seek(-10);
        }
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        if (_isLive) {
          setState(() => _channelList = true);
        } else {
          _seek(10);
        }
        return KeyEventResult.handled;
      }
    } else if (_controls) {
      _scheduleHide();
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _saveProgress();
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _numberTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    AppPlatform.pipActive.removeListener(_onPipChanged);
    AppPlatform.setAutoPip(false);
    if (AppPlatform.isAndroid && !AppPlatform.isTv) defaultExitNativeFullscreen();
    if (_fullscreen) defaultExitNativeFullscreen();
    _player.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pip = AppPlatform.pipActive.value;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controls ? _hideControls() : _showControls(),
            onDoubleTap: AppPlatform.isDesktop ? _toggleFullscreen : null,
            onDoubleTapDown: AppPlatform.isDesktop
                ? null
                : (d) {
                    final w = MediaQuery.sizeOf(context).width;
                    if (d.localPosition.dx < w * 0.35) _seek(-10);
                    if (d.localPosition.dx > w * 0.65) _seek(10);
                  },
            onVerticalDragEnd: _isLive && !AppPlatform.isDesktop
                ? (d) => _zap((d.primaryVelocity ?? 0) < 0 ? 1 : -1)
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(
                  controller: _video,
                  controls: NoVideoControls,
                  fit: switch (_fit) {
                    _Fit.contain => BoxFit.contain,
                    _Fit.cover => BoxFit.cover,
                    _Fit.fill => BoxFit.fill,
                  },
                  filterQuality: FilterQuality.medium,
                  pauseUponEnteringBackgroundMode: !AppPlatform.pipSupported,
                ),
                if (!pip) ...[
                  _BufferingIndicator(player: _player, opening: _opening && _error == null),
                  if (_error != null)
                    _ErrorOverlay(
                      message: _error!,
                      onRetry: () {
                        _retries = 0;
                        _open();
                      },
                    ),
                  if (_typedNumber.isNotEmpty)
                    Positioned(
                      top: 32,
                      right: 40,
                      child: Text(
                        _typedNumber,
                        style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                          fontFamily: Brand.headingFont,
                          color: Brand.cyberMint,
                        ),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_controls,
                      child: ExcludeFocus(excluding: !_controls, child: _buildControls(context)),
                    ),
                  ),
                  if (_channelList && _isLive)
                    _ChannelListOverlay(
                      channels: widget.request.channels,
                      current: _index,
                      onPick: (i) {
                        setState(() => _channelList = false);
                        _rootFocus.requestFocus();
                        _jumpToChannel(i);
                      },
                      onClose: () {
                        setState(() => _channelList = false);
                        _rootFocus.requestFocus();
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final r = widget.request;
    final now = DateTime.now();
    final current = _epg.where((p) => p.isLiveAt(now)).firstOrNull;
    final next = current == null ? null : _epg.where((p) => !p.start.isBefore(current.end)).firstOrNull;
    final profileId = _session.profile?.id;
    final fav = _isLive && profileId != null && _store.isFavorite(profileId, ContentType.live, _channel!.id);

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
          stops: [0, 0.25, 0.55, 1],
        ),
      ),
      child: SafeArea(
        child: FocusTraversalGroup(
          child: Column(
            children: [
              // Top bar
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 24, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    if (_isLive && _channel!.logo != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(width: 64, height: 40, child: NetImage(_channel!.logo, fit: BoxFit.contain)),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isLive && _channel!.number != null ? '${_channel!.number}  $_title' : _title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              fontFamily: Brand.headingFont,
                            ),
                          ),
                          if (current != null)
                            Text(
                              '${formatClock(current.start)} – ${formatClock(current.end)}  ${current.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Brand.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    Text(formatClock(now), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const Spacer(),
              // Bottom bar
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isLive && current != null) ...[
                      BrandProgress(value: current.progressAt(now)),
                      const SizedBox(height: 6),
                      if (next != null)
                        Text(
                          'Next: ${formatClock(next.start)}  ${next.title}',
                          style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
                        ),
                    ],
                    if (!_isLive) _SeekBar(player: _player, onSeeked: _scheduleHide),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_isLive)
                          _CtrlButton(
                            icon: Icons.skip_previous_rounded,
                            tooltip: 'Previous channel',
                            onPressed: () => _zap(-1),
                          ),
                        if (!_isLive)
                          _CtrlButton(icon: Icons.replay_10_rounded, tooltip: 'Back 10 s', onPressed: () => _seek(-10)),
                        StreamBuilder<bool>(
                          stream: _player.stream.playing,
                          initialData: _player.state.playing,
                          builder: (_, snap) => _CtrlButton(
                            focusNode: _playFocus,
                            autofocus: true,
                            big: true,
                            icon: snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            tooltip: snap.data == true ? 'Pause' : 'Play',
                            onPressed: () {
                              _player.playOrPause();
                              _scheduleHide();
                            },
                          ),
                        ),
                        if (!_isLive)
                          _CtrlButton(
                            icon: Icons.forward_10_rounded,
                            tooltip: 'Forward 10 s',
                            onPressed: () => _seek(10),
                          ),
                        if (_isLive)
                          _CtrlButton(icon: Icons.skip_next_rounded, tooltip: 'Next channel', onPressed: () => _zap(1)),
                        if (r.type == ContentType.series && _index < r.episodes.length - 1)
                          _CtrlButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: 'Next episode',
                            onPressed: () {
                              _saveProgress(finished: true);
                              _index++;
                              _open();
                            },
                          ),
                        const Spacer(),
                        if (_isLive)
                          _CtrlButton(
                            icon: Icons.list_rounded,
                            tooltip: 'Channels',
                            onPressed: () => setState(() => _channelList = true),
                          ),
                        if (_isLive && profileId != null)
                          _CtrlButton(
                            icon: fav ? Icons.star_rounded : Icons.star_outline_rounded,
                            tooltip: fav ? 'Remove from favorites' : 'Add to favorites',
                            onPressed: () {
                              _store.toggleFavorite(SavedItem.channel(profileId, _channel!));
                              setState(() {});
                            },
                          ),
                        if (_isLive && _channel!.hasCatchup)
                          _CtrlButton(icon: Icons.history_rounded, tooltip: 'Catch-up', onPressed: _openCatchup),
                        _CtrlButton(
                          icon: Icons.audiotrack_rounded,
                          tooltip: 'Audio',
                          onPressed: () => _pickTrack(audio: true),
                        ),
                        _CtrlButton(
                          icon: Icons.subtitles_rounded,
                          tooltip: 'Subtitles',
                          onPressed: () => _pickTrack(audio: false),
                        ),
                        _CtrlButton(
                          icon: switch (_fit) {
                            _Fit.contain => Icons.fit_screen_rounded,
                            _Fit.cover => Icons.crop_rounded,
                            _Fit.fill => Icons.aspect_ratio_rounded,
                          },
                          tooltip: 'Aspect: ${_fit.name}',
                          onPressed: _cycleFit,
                        ),
                        if (AppPlatform.pipSupported)
                          _CtrlButton(
                            icon: Icons.picture_in_picture_alt_rounded,
                            tooltip: 'Picture in picture',
                            onPressed: () =>
                                AppPlatform.enterPip(width: _player.state.width, height: _player.state.height),
                          ),
                        if (AppPlatform.isDesktop)
                          _CtrlButton(
                            icon: _fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                            tooltip: 'Full screen (F)',
                            onPressed: _toggleFullscreen,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickTrack({required bool audio}) async {
    _hideTimer?.cancel();
    final tracks = _player.state.tracks;
    final current = _player.state.track;
    final items = audio ? tracks.audio : tracks.subtitle;
    String label(dynamic t) {
      final id = t.id as String;
      if (id == 'auto') return 'Auto';
      if (id == 'no') return audio ? 'Off' : 'Off';
      final parts = [t.title, t.language].whereType<String>().where((s) => s.isNotEmpty).toList();
      return parts.isEmpty ? 'Track $id' : parts.join(' · ');
    }

    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Brand.slateObsidian,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(audio ? 'Audio track' : 'Subtitles', style: Theme.of(c).textTheme.titleMedium),
            ),
            for (final (i, t) in items.indexed)
              ListTile(
                autofocus: i == 0,
                leading: Icon(
                  (audio ? current.audio.id : current.subtitle.id) == t.id
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: Brand.cyberMint,
                ),
                title: Text(label(t)),
                onTap: () => Navigator.pop(c, t),
              ),
          ],
        ),
      ),
    );
    if (picked is AudioTrack) await _player.setAudioTrack(picked);
    if (picked is SubtitleTrack) await _player.setSubtitleTrack(picked);
    _scheduleHide();
    _rootFocus.requestFocus();
  }

  Future<void> _openCatchup() async {
    final c = _channel;
    final src = _session.source;
    if (c == null || src == null) return;
    _hideTimer?.cancel();
    // Ask the provider for the last few days of programmes for this channel.
    List<EpgProgram> programs = _session.guide.programsFor(c.epgId, channelName: c.name);
    if (programs.isEmpty) {
      try {
        programs = await src.shortEpg(c, limit: 200);
      } catch (_) {}
    }
    final now = DateTime.now();
    final earliest = now.subtract(Duration(days: c.catchupDays));
    final past = programs.where((p) => p.end.isBefore(now) && p.start.isAfter(earliest)).toList().reversed.toList();
    if (!mounted) return;
    if (past.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No past programmes to replay.')));
      return;
    }
    final pick = await showModalBottomSheet<EpgProgram>(
      context: context,
      backgroundColor: Brand.slateObsidian,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.7,
          child: ListView.builder(
            itemCount: past.length,
            itemBuilder: (_, i) {
              final p = past[i];
              return ListTile(
                autofocus: i == 0,
                leading: const Icon(Icons.history_rounded, color: Brand.sky),
                title: Text(p.title),
                subtitle: Text('${p.start.day}/${p.start.month}  ${formatClock(p.start)} – ${formatClock(p.end)}'),
                onTap: () => Navigator.pop(ctx, p),
              );
            },
          ),
        ),
      ),
    );
    if (pick == null || !mounted) return;
    final stream = await src.resolveCatchup(c, pick);
    if (!mounted) return;
    if (stream == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Catch-up is not available here.')));
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PlayerScreen(request: PlayRequest.catchup(c, stream))));
  }
}

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.big = false,
    this.autofocus = false,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool big;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: IconButton(
      focusNode: focusNode,
      autofocus: autofocus,
      tooltip: tooltip,
      iconSize: big ? 44 : 28,
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? Brand.cyberMint
              : big
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) ? Brand.deepVoid : Colors.white,
        ),
      ),
      icon: Icon(icon),
    ),
  );
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.onSeeked});

  final Player player;
  final VoidCallback onSeeked;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, snap) {
        final dur = widget.player.state.duration;
        final pos = snap.data ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 1.0 : max);
        return Row(
          children: [
            Text(formatDuration(Duration(milliseconds: value.toInt())), style: const TextStyle(fontSize: 13)),
            Expanded(
              child: Slider(
                value: value,
                max: max <= 0 ? 1 : max,
                onChanged: max <= 0 ? null : (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  widget.player.seek(Duration(milliseconds: v.toInt()));
                  setState(() => _drag = null);
                  widget.onSeeked();
                },
              ),
            ),
            Text(formatDuration(dur), style: const TextStyle(fontSize: 13, color: Brand.textSecondary)),
          ],
        );
      },
    );
  }
}

class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator({required this.player, required this.opening});

  final Player player;
  final bool opening;

  @override
  Widget build(BuildContext context) => StreamBuilder<bool>(
    stream: player.stream.buffering,
    initialData: player.state.buffering,
    builder: (_, snap) => (opening || snap.data == true)
        ? const Center(child: SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 4)))
        : const SizedBox.shrink(),
  );
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black54,
    child: MessageView(
      icon: Icons.signal_wifi_connected_no_internet_4_rounded,
      title: 'Playback problem',
      subtitle: message,
      action: FilledButton.icon(
        autofocus: true,
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Retry'),
      ),
    ),
  );
}

/// Side list for switching channels without leaving the player.
class _ChannelListOverlay extends StatelessWidget {
  const _ChannelListOverlay({
    required this.channels,
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  final List<Channel> channels;
  final int current;
  final ValueChanged<int> onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: Container(color: Colors.black38),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 380,
          child: Container(
            color: Brand.slateObsidian.withValues(alpha: 0.95),
            child: SafeArea(
              right: false,
              child: ListView.builder(
                controller: ScrollController(initialScrollOffset: (current * 60.0 - 200).clamp(0, double.infinity)),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                itemCount: channels.length,
                itemExtent: 60,
                itemBuilder: (_, i) {
                  final c = channels[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: TvFocusable(
                      autofocus: i == current,
                      selected: i == current,
                      borderRadius: 10,
                      scale: 1.02,
                      onSelect: () => onPick(i),
                      child: Container(
                        color: i == current ? Brand.cyberMint.withValues(alpha: 0.12) : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              child: Text('${c.number ?? i + 1}', style: const TextStyle(color: Brand.textMuted)),
                            ),
                            SizedBox(
                              width: 56,
                              height: 36,
                              child: NetImage(c.logo, fit: BoxFit.contain, cacheWidth: 112),
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
