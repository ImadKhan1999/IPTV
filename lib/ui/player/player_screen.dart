import 'dart:async';

import 'package:flutter/gestures.dart';
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
import 'player_controller.dart';

export 'player_controller.dart' show PlayRequest, PlayStage, PlayerController;

enum _Panel { none, volume, brightness }

/// The full screen player. It either plays [request] with its own controller, or takes over
/// a running [controller] (from the live preview) without restarting the stream.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, this.request, this.controller}) : assert(request != null || controller != null);

  final PlayRequest? request;
  final PlayerController? controller;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _c;
  late final bool _owned = widget.controller == null;
  final _rootFocus = FocusNode(debugLabel: 'player');
  final _playFocus = FocusNode(debugLabel: 'play-button');

  bool _controls = true;
  bool _channelList = false;
  bool _info = false;
  bool _fullscreen = false;
  _Panel _panel = _Panel.none;
  Timer? _hideTimer;
  Timer? _numberTimer;
  Timer? _hudTimer;
  String _typedNumber = '';

  // Swipe-to-adjust on touch screens.
  bool? _dragBrightness;
  String? _hud;

  Player get _player => _c.player;

  @override
  void initState() {
    super.initState();
    _c =
        widget.controller ??
        PlayerController(
          session: context.read<Session>(),
          store: context.read<LibraryStore>(),
          request: widget.request!,
        );
    _c.fullscreenActive = true;
    _c.addListener(_onController);
    AppPlatform.pipActive.addListener(_onPipChanged);
    AppPlatform.setAutoPip(_player.state.playing, width: _player.state.width, height: _player.state.height);

    if (AppPlatform.isAndroid && !AppPlatform.isTv) {
      // Phones go landscape full screen; TVs already are.
      defaultEnterNativeFullscreen();
    } else if (AppPlatform.isDesktop && !_owned) {
      // Opened from the live preview's full screen button: fill the monitor.
      _fullscreen = true;
      defaultEnterNativeFullscreen();
    }
    _scheduleHide();
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _onPipChanged() {
    if (mounted) setState(() => _controls = !AppPlatform.pipActive.value);
  }

  // Controls ---------------------------------------------------------------

  void _showControls() {
    if (!_controls) {
      setState(() => _controls = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panel == _Panel.none) _playFocus.requestFocus();
      });
    }
    _scheduleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() {
      _controls = false;
      _panel = _Panel.none;
    });
    _rootFocus.requestFocus();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _player.state.playing && !_channelList && _panel == _Panel.none) _hideControls();
    });
  }

  void _zap(int delta) {
    _c.zap(delta);
    _showControls();
  }

  void _seek(int seconds) {
    _c.seekBy(seconds);
    _showControls();
  }

  void _togglePanel(_Panel p) {
    setState(() => _panel = _panel == p ? _Panel.none : p);
    if (_panel == _Panel.none) {
      _playFocus.requestFocus();
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _showHud(String text) {
    _hudTimer?.cancel();
    setState(() => _hud = text);
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _nudgeVolume(double delta) {
    _c.setVolume((_c.muted ? 0 : _c.volume) + delta);
    _showHud('Volume ${_c.volume.round()}%');
  }

  void _onNumber(String digit) {
    if (!_c.isLive) return;
    _numberTimer?.cancel();
    setState(() => _typedNumber += digit);
    _numberTimer = Timer(const Duration(milliseconds: 1500), () {
      final n = int.tryParse(_typedNumber);
      setState(() => _typedNumber = '');
      if (n == null) return;
      final channels = _c.request.channels;
      var i = channels.indexWhere((c) => c.number == n);
      if (i < 0 && n >= 1 && n <= channels.length) i = n - 1;
      if (i >= 0) _c.jumpTo(i);
    });
  }

  /// Desktop: toggles the window between full screen and windowed. When this screen took over
  /// the live preview, leaving full screen goes back to the channel list with the preview.
  Future<void> _toggleFullscreen() async {
    if (!_owned) {
      Navigator.of(context).maybePop();
      return;
    }
    if (!AppPlatform.isDesktop) return;
    _fullscreen = !_fullscreen;
    _fullscreen ? await defaultEnterNativeFullscreen() : await defaultExitNativeFullscreen();
    if (mounted) setState(() {});
  }

  bool _isKey(LogicalKeyboardKey k, List<LogicalKeyboardKey> keys) => keys.contains(k);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final live = _c.isLive;

    // Media and channel keys work whether or not the controls are visible.
    if (_isKey(k, [LogicalKeyboardKey.mediaPlayPause, LogicalKeyboardKey.space])) {
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
    if (_isKey(k, [LogicalKeyboardKey.channelUp, LogicalKeyboardKey.pageUp])) {
      _zap(-1);
      return KeyEventResult.handled;
    }
    if (_isKey(k, [LogicalKeyboardKey.channelDown, LogicalKeyboardKey.pageDown])) {
      _zap(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      live ? _zap(1) : (_c.hasNextEpisode ? _c.nextEpisode() : _seek(60));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      live ? _zap(-1) : _seek(-60);
      return KeyEventResult.handled;
    }
    if (_isKey(k, [LogicalKeyboardKey.keyF, LogicalKeyboardKey.f11])) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (_isKey(k, [LogicalKeyboardKey.info, LogicalKeyboardKey.keyI])) {
      setState(() => _info = !_info);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyM) {
      _c.toggleMute();
      _showHud(_c.muted ? 'Muted' : 'Volume ${_c.volume.round()}%');
      return KeyEventResult.handled;
    }
    if (_isKey(k, [LogicalKeyboardKey.equal, LogicalKeyboardKey.add, LogicalKeyboardKey.numpadAdd])) {
      _nudgeVolume(5);
      return KeyEventResult.handled;
    }
    if (_isKey(k, [LogicalKeyboardKey.minus, LogicalKeyboardKey.numpadSubtract])) {
      _nudgeVolume(-5);
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (live && ch != null && RegExp(r'^\d$').hasMatch(ch)) {
      _onNumber(ch);
      return KeyEventResult.handled;
    }
    if (_isKey(k, [LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack, LogicalKeyboardKey.browserBack])) {
      if (_channelList) {
        setState(() => _channelList = false);
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (_panel != _Panel.none) {
        _togglePanel(_panel);
        return KeyEventResult.handled;
      }
      if (_info) {
        setState(() => _info = false);
        return KeyEventResult.handled;
      }
      if (_controls && _player.state.playing) {
        _hideControls();
        return KeyEventResult.handled;
      }
      if (_fullscreen && _owned) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // let the route pop
    }

    // With the controls hidden, the D-pad drives playback directly.
    if (!_controls && !_channelList) {
      if (_isKey(k, [LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter])) {
        _showControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        live ? _zap(-1) : _nudgeVolume(5);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        live ? _zap(1) : _nudgeVolume(-5);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
        if (live) {
          setState(() => _channelList = true);
        } else {
          _seek(k == LogicalKeyboardKey.arrowLeft ? -10 : 10);
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
    _hideTimer?.cancel();
    _numberTimer?.cancel();
    _hudTimer?.cancel();
    AppPlatform.pipActive.removeListener(_onPipChanged);
    AppPlatform.setAutoPip(false);
    if (AppPlatform.isAndroid && !AppPlatform.isTv) defaultExitNativeFullscreen();
    if (_fullscreen) defaultExitNativeFullscreen();
    _c.removeListener(_onController);
    _c.fullscreenActive = false;
    if (_owned) _c.dispose();
    _rootFocus.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  // Touch gestures --------------------------------------------------------------

  void _onDragStart(DragStartDetails d) {
    final w = MediaQuery.sizeOf(context).width;
    _dragBrightness = d.localPosition.dx < w / 2 && !PlayerController.directOutput(_c.store.player) ? true : false;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final h = MediaQuery.sizeOf(context).height;
    final delta = -d.delta.dy / (h * 0.7);
    if (_dragBrightness == true) {
      _c.setBrightness(_c.brightness + delta * 100);
      _showHud('Brightness ${(_c.brightness + 50).round()}%');
    } else if (_dragBrightness == false) {
      _c.setVolume((_c.muted ? 0 : _c.volume) + delta * 100);
      _showHud('Volume ${_c.volume.round()}%');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pip = AppPlatform.pipActive.value;
    final touch = !AppPlatform.isDesktop && !AppPlatform.isTv;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          // Mouse wheel changes the volume on desktop.
          onPointerSignal: (s) {
            if (s is PointerScrollEvent) _nudgeVolume(s.scrollDelta.dy < 0 ? 5 : -5);
          },
          child: MouseRegion(
            onHover: (_) => _showControls(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _controls ? _hideControls() : _showControls(),
              onDoubleTap: AppPlatform.isDesktop ? _toggleFullscreen : null,
              onDoubleTapDown: touch
                  ? (d) {
                      final w = MediaQuery.sizeOf(context).width;
                      if (d.localPosition.dx < w * 0.35) _seek(-10);
                      if (d.localPosition.dx > w * 0.65) _seek(10);
                    }
                  : null,
              onVerticalDragStart: touch ? _onDragStart : null,
              onVerticalDragUpdate: touch ? _onDragUpdate : null,
              onVerticalDragEnd: touch ? (_) => _dragBrightness = null : null,
              onHorizontalDragEnd: touch && _c.isLive ? (d) => _zap((d.primaryVelocity ?? 0) < 0 ? 1 : -1) : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PlayerVideo(controller: _c),
                  if (!pip) ...[
                    PlayerStatusOverlay(controller: _c, onNextChannel: _c.isLive ? () => _zap(1) : null),
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
                    if (_hud != null)
                      Align(
                        alignment: const Alignment(0, -0.6),
                        child: _Hud(text: _hud!),
                      ),
                    AnimatedOpacity(
                      opacity: _controls ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_controls,
                        child: ExcludeFocus(excluding: !_controls, child: _buildControls(context)),
                      ),
                    ),
                    if (_panel != _Panel.none && _controls) _buildPanel(),
                    if (_info)
                      Positioned(
                        top: 0,
                        right: 0,
                        bottom: 0,
                        width: 340,
                        child: StreamInfoPanel(controller: _c, onClose: () => setState(() => _info = false)),
                      ),
                    if (_channelList && _c.isLive)
                      _ChannelListOverlay(
                        channels: _c.request.channels,
                        current: _c.index,
                        onPick: (i) {
                          setState(() => _channelList = false);
                          _rootFocus.requestFocus();
                          _c.jumpTo(i);
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
      ),
    );
  }

  Widget _buildPanel() {
    final volume = _panel == _Panel.volume;
    return Positioned(
      left: 24,
      bottom: 110,
      child: _SliderCard(
        icon: volume ? (_c.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded) : Icons.brightness_6_rounded,
        label: volume ? 'Volume' : 'Brightness',
        value: volume ? (_c.muted ? 0 : _c.volume) : _c.brightness + 50,
        onChanged: (v) => volume ? _c.setVolume(v) : _c.setBrightness(v - 50),
        onIconTap: volume ? _c.toggleMute : () => _c.setBrightness(0),
        iconTooltip: volume ? (_c.muted ? 'Unmute (M)' : 'Mute (M)') : 'Reset brightness',
        onClose: () => _togglePanel(_panel),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final r = _c.request;
    final live = _c.isLive;
    final channel = _c.channel;
    final now = DateTime.now();
    final current = _c.epg.where((p) => p.isLiveAt(now)).firstOrNull;
    final next = current == null ? null : _c.epg.where((p) => !p.start.isBefore(current.end)).firstOrNull;
    final store = context.watch<LibraryStore>();
    final profileId = _c.session.profile?.id;
    final fav = channel != null && profileId != null && store.isFavorite(profileId, ContentType.live, channel.id);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 760;

    final transport = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live)
          _CtrlButton(icon: Icons.skip_previous_rounded, tooltip: 'Previous channel', onPressed: () => _zap(-1))
        else
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
        if (live)
          _CtrlButton(icon: Icons.skip_next_rounded, tooltip: 'Next channel', onPressed: () => _zap(1))
        else ...[
          _CtrlButton(icon: Icons.forward_10_rounded, tooltip: 'Forward 10 s', onPressed: () => _seek(10)),
          if (r.type == ContentType.series)
            _CtrlButton(
              icon: Icons.skip_next_rounded,
              tooltip: 'Next episode',
              onPressed: _c.hasNextEpisode ? _c.nextEpisode : null,
            ),
        ],
      ],
    );

    final left = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CtrlButton(
          icon: _c.muted || _c.volume == 0
              ? Icons.volume_off_rounded
              : _c.volume < 50
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded,
          tooltip: 'Sound',
          active: _panel == _Panel.volume,
          onPressed: () => _togglePanel(_Panel.volume),
        ),
        if (AppPlatform.isDesktop && !compact)
          SizedBox(
            width: 110,
            child: ExcludeFocus(
              child: Slider(
                value: _c.muted ? 0 : _c.volume,
                max: 100,
                onChanged: (v) {
                  _c.setVolume(v);
                  _scheduleHide();
                },
              ),
            ),
          ),
        // Direct (MediaCodec) output draws video outside the renderer, so no picture brightness.
        if (!PlayerController.directOutput(_c.store.player))
          _CtrlButton(
            icon: Icons.brightness_6_rounded,
            tooltip: 'Brightness',
            active: _panel == _Panel.brightness,
            onPressed: () => _togglePanel(_Panel.brightness),
          ),
      ],
    );

    final right = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live) ...[
          _CtrlButton(
            icon: Icons.list_rounded,
            tooltip: 'Channels',
            onPressed: () => setState(() => _channelList = true),
          ),
          if (profileId != null)
            _CtrlButton(
              icon: fav ? Icons.star_rounded : Icons.star_outline_rounded,
              tooltip: fav ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () => store.toggleFavorite(SavedItem.channel(profileId, channel!)),
            ),
          if (channel!.hasCatchup)
            _CtrlButton(icon: Icons.history_rounded, tooltip: 'Catch-up', onPressed: _openCatchup),
        ],
        _CtrlButton(icon: Icons.audiotrack_rounded, tooltip: 'Audio track', onPressed: () => _pickTrack(audio: true)),
        _CtrlButton(icon: Icons.subtitles_rounded, tooltip: 'Subtitles', onPressed: () => _pickTrack(audio: false)),
        _CtrlButton(
          icon: switch (_c.fit) {
            VideoFit.contain => Icons.fit_screen_rounded,
            VideoFit.cover => Icons.crop_rounded,
            VideoFit.fill => Icons.aspect_ratio_rounded,
          },
          tooltip: 'Aspect: ${_c.fit.name}',
          onPressed: _c.cycleFit,
        ),
        _CtrlButton(
          icon: Icons.info_outline_rounded,
          tooltip: 'Stream info (I)',
          active: _info,
          onPressed: () => setState(() => _info = !_info),
        ),
        if (AppPlatform.pipSupported)
          _CtrlButton(
            icon: Icons.picture_in_picture_alt_rounded,
            tooltip: 'Picture in picture',
            onPressed: () => AppPlatform.enterPip(width: _player.state.width, height: _player.state.height),
          ),
        if (AppPlatform.isDesktop || !_owned)
          _CtrlButton(
            icon: _fullscreen || !_owned ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
            tooltip: _fullscreen || !_owned ? 'Exit full screen (F)' : 'Full screen (F)',
            onPressed: _toggleFullscreen,
          ),
      ],
    );

    Widget scrollable(Widget child) =>
        SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: child);

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
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    if (channel?.logo != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(width: 64, height: 40, child: NetImage(channel!.logo, fit: BoxFit.contain)),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel?.number != null ? '${channel!.number}  ${_c.title}' : _c.title,
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
                    _QualityBadge(player: _player),
                    const SizedBox(width: 12),
                    Text(formatClock(now), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Stream info (I)',
                      icon: const Icon(Icons.info_outline_rounded),
                      onPressed: () => setState(() => _info = !_info),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Bottom bar
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (live && current != null) ...[
                      BrandProgress(value: current.progressAt(now)),
                      const SizedBox(height: 6),
                      if (next != null)
                        Text(
                          'Next: ${formatClock(next.start)}  ${next.title}',
                          style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
                        ),
                    ],
                    if (!live) _SeekBar(player: _player, onSeeked: _scheduleHide),
                    const SizedBox(height: 6),
                    if (compact) ...[
                      Center(child: transport),
                      Row(
                        children: [
                          left,
                          const SizedBox(width: 8),
                          Expanded(
                            child: Align(alignment: Alignment.centerRight, child: scrollable(right)),
                          ),
                        ],
                      ),
                    ] else
                      Row(
                        children: [
                          Expanded(
                            child: Align(alignment: Alignment.centerLeft, child: left),
                          ),
                          transport,
                          Expanded(
                            child: Align(alignment: Alignment.centerRight, child: scrollable(right)),
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
      if (id == 'no') return 'Off';
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
    final c = _c.channel;
    final src = _c.session.source;
    if (c == null || src == null) return;
    _hideTimer?.cancel();
    // Ask the provider for the last few days of programmes for this channel.
    List<EpgProgram> programs = _c.session.guide.programsFor(c.epgId, channelName: c.name);
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
    // Only one stream at a time: stop live while the recording plays, then tune back in.
    await _player.stop();
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => PlayerScreen(request: PlayRequest.catchup(c, stream))));
    if (mounted) _c.retry();
  }
}

/// The video surface for a controller, with its picture fit applied.
class PlayerVideo extends StatelessWidget {
  const PlayerVideo({super.key, required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) => Video(
    controller: controller.video,
    controls: NoVideoControls,
    fit: switch (controller.fit) {
      VideoFit.contain => BoxFit.contain,
      VideoFit.cover => BoxFit.cover,
      VideoFit.fill => BoxFit.fill,
    },
    filterQuality: FilterQuality.medium,
    pauseUponEnteringBackgroundMode: !AppPlatform.pipSupported,
  );
}

/// Start-up progress ("Connecting…", "Buffering 42%", "Reconnecting 2/4") and readable errors.
class PlayerStatusOverlay extends StatelessWidget {
  const PlayerStatusOverlay({super.key, required this.controller, this.compact = false, this.onNextChannel});

  final PlayerController controller;
  final bool compact;
  final VoidCallback? onNextChannel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        if (c.stage == PlayStage.playing) return const SizedBox.shrink();
        if (c.stage == PlayStage.error) return _error(context, c);
        final pct = c.stage == PlayStage.buffering && c.bufferPercent > 0 ? c.bufferPercent / 100 : null;
        final size = compact ? 40.0 : 64.0;
        final steps = [PlayStage.resolving, PlayStage.connecting, PlayStage.buffering];
        final stepIndex = steps.indexOf(c.stage);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: size,
                height: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      value: pct,
                      strokeWidth: compact ? 3 : 4,
                      backgroundColor: Colors.white12,
                      color: c.stage == PlayStage.reconnecting ? Brand.warning : Brand.cyberMint,
                    ),
                    if (pct != null)
                      Center(
                        child: Text(
                          '${c.bufferPercent.round()}%',
                          style: TextStyle(fontSize: compact ? 11 : 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: compact ? 10 : 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(
                  c.statusText,
                  style: TextStyle(fontSize: compact ? 12 : 15, fontWeight: FontWeight.w600),
                ),
              ),
              if (!compact && stepIndex >= 0) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, label) in const ['Link', 'Server', 'Buffer'].indexed) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Icon(
                        i < stepIndex ? Icons.check_circle_rounded : Icons.circle_outlined,
                        size: 14,
                        color: i <= stepIndex ? Brand.cyberMint : Brand.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: TextStyle(fontSize: 12, color: i <= stepIndex ? Brand.textPrimary : Brand.textMuted),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _error(BuildContext context, PlayerController c) {
    final code = c.errorCode;
    final offline = code == '404' || code == '410' || code == 'TIMEOUT';
    final denied = code == '401' || code == '403';
    final title = offline
        ? 'Channel unavailable'
        : denied
        ? 'Access denied'
        : 'Playback problem';
    final icon = offline
        ? Icons.tv_off_rounded
        : denied
        ? Icons.lock_outline_rounded
        : Icons.signal_wifi_connected_no_internet_4_rounded;
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      padding: EdgeInsets.all(compact ? 12 : 32),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 32 : 56, color: Brand.error),
            SizedBox(height: compact ? 6 : 14),
            Text(
              title,
              style: TextStyle(fontSize: compact ? 15 : 22, fontWeight: FontWeight.w700, fontFamily: Brand.headingFont),
            ),
            SizedBox(height: compact ? 4 : 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                c.errorMessage ?? 'Playback failed.',
                textAlign: TextAlign.center,
                maxLines: compact ? 3 : 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Brand.textSecondary, fontSize: compact ? 12 : 14),
              ),
            ),
            if (code != null && !compact) ...[
              const SizedBox(height: 8),
              Text('Code: $code', style: const TextStyle(color: Brand.textMuted, fontSize: 12)),
            ],
            SizedBox(height: compact ? 8 : 20),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  autofocus: !compact,
                  onPressed: c.retry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
                if (onNextChannel != null && !compact)
                  OutlinedButton.icon(
                    onPressed: onNextChannel,
                    icon: const Icon(Icons.skip_next_rounded),
                    label: const Text('Next channel'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Live technical details: resolution, codecs, frame rate, bitrate, decoder and buffer.
class StreamInfoPanel extends StatefulWidget {
  const StreamInfoPanel({super.key, required this.controller, required this.onClose});

  final PlayerController controller;
  final VoidCallback onClose;

  @override
  State<StreamInfoPanel> createState() => _StreamInfoPanelState();
}

class _StreamInfoPanelState extends State<StreamInfoPanel> {
  Timer? _timer;
  List<(String, String)> _rows = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final info = await widget.controller.streamInfo();
    if (mounted) setState(() => _rows = info.rows);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {}, // keep taps from toggling the player controls
      child: Container(
        color: Brand.slateObsidian.withValues(alpha: 0.94),
        child: SafeArea(
          left: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
            children: [
              Row(
                children: [
                  const Icon(Icons.info_outline_rounded, color: Brand.cyberMint),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Stream info',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, fontFamily: Brand.headingFont),
                    ),
                  ),
                  IconButton(
                    autofocus: true,
                    tooltip: 'Close',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: widget.controller,
                builder: (_, _) => _row('Status', switch (widget.controller.stage) {
                  PlayStage.playing => 'Playing',
                  PlayStage.error => 'Error ${widget.controller.errorCode ?? ''}'.trim(),
                  _ => widget.controller.statusText,
                }),
              ),
              for (final (k, v) in _rows) _row(k, v),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(k, style: const TextStyle(color: Brand.textMuted, fontSize: 13)),
        ),
        Expanded(
          child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ],
    ),
  );
}

/// "1080p" style badge in the top bar, from the decoded video size.
class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) => StreamBuilder<int?>(
    stream: player.stream.height,
    initialData: player.state.height,
    builder: (_, snap) {
      final h = snap.data;
      if (h == null || h <= 0) return const SizedBox.shrink();
      final label = h >= 2000
          ? '4K'
          : h >= 1400
          ? '1440p'
          : h >= 1000
          ? '1080p'
          : h >= 700
          ? '720p'
          : '${h}p';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: Brand.cyberMint.withValues(alpha: 0.7)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Brand.cyberMint, fontWeight: FontWeight.w800, fontSize: 12),
        ),
      );
    },
  );
}

class _Hud extends StatelessWidget {
  const _Hud({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(24)),
    child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
  );
}

class _SliderCard extends StatelessWidget {
  const _SliderCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onIconTap,
    required this.iconTooltip,
    required this.onClose,
  });

  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onIconTap;
  final String iconTooltip;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () {},
    child: Container(
      width: 320,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: Brand.slateObsidian.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.border),
      ),
      child: Row(
        children: [
          IconButton(tooltip: iconTooltip, onPressed: onIconTap, icon: Icon(icon)),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '$label  ${value.round()}%',
                    style: const TextStyle(fontSize: 12, color: Brand.textSecondary),
                  ),
                ),
                Slider(autofocus: true, value: value.clamp(0, 100), max: 100, divisions: 20, onChanged: onChanged),
              ],
            ),
          ),
          IconButton(tooltip: 'Close', onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 20)),
        ],
      ),
    ),
  );
}

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.big = false,
    this.active = false,
    this.autofocus = false,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool big;
  final bool active;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: big ? 10 : 2),
    child: IconButton(
      focusNode: focusNode,
      autofocus: autofocus,
      tooltip: tooltip,
      iconSize: big ? 48 : 26,
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? Brand.cyberMint
              : big
              ? Colors.white.withValues(alpha: 0.14)
              : active
              ? Brand.cyberMint.withValues(alpha: 0.2)
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? Brand.deepVoid
              : s.contains(WidgetState.disabled)
              ? Colors.white38
              : active
              ? Brand.cyberMint
              : Colors.white,
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
