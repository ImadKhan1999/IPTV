import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../data/updater.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// One destination on the home screen.
class HomeTile {
  const HomeTile({
    required this.id,
    required this.label,
    required this.icon,
    this.subtitle,
    this.count,
    this.colors = const [Color(0xFF14213D), Color(0xFF0E1628)],
    this.big = false,
  });

  final Object id;
  final String label;
  final IconData icon;
  final String? subtitle;
  final int? count;
  final List<Color> colors;
  final bool big;
}

/// Big-tile home screen for TV and desktop: Live TV, Movies and Series up front,
/// then Favorites, Search, Settings. Built to be driven with a D-pad from across the room.
class TvHome extends StatelessWidget {
  const TvHome({super.key, required this.tiles, required this.onOpen, this.focusId});

  final List<HomeTile> tiles;
  final ValueChanged<Object> onOpen;

  /// The tile that gets focus (the section the person came back from).
  final Object? focusId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final session = context.watch<Session>();
    final size = MediaQuery.sizeOf(context);
    final short = size.height < 640;
    final big = tiles.where((t) => t.big).toList();
    final small = tiles.where((t) => !t.big).toList();
    final focus = focusId ?? tiles.first.id;
    final account = session.account;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.8, -0.9),
            radius: 1.4,
            colors: [Color(0xFF101B33), Brand.deepVoid],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: size.width * 0.04, vertical: short ? 16 : 28),
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      AppLogo(size: short ? 34 : 44),
                      const SizedBox(width: 18),
                      if (store.activeProfile != null)
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Brand.surfaceCard,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Brand.border),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    session.state == SessionState.ready
                                        ? Icons.circle
                                        : session.state == SessionState.error
                                        ? Icons.error_rounded
                                        : Icons.sync_rounded,
                                    size: 10,
                                    color: session.state == SessionState.ready
                                        ? Brand.success
                                        : session.state == SessionState.error
                                        ? Brand.error
                                        : Brand.warning,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      store.activeProfile!.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Brand.textSecondary, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  if (account?.expiresAt != null) ...[
                                    const SizedBox(width: 10),
                                    Text(
                                      'Expires ${_date(account!.expiresAt!)}',
                                      style: const TextStyle(color: Brand.textMuted, fontSize: 12),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      const _DateClock(),
                    ],
                  ),
                  SizedBox(height: short ? 16 : 32),
                  Expanded(
                    flex: 3,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, t) in big.indexed) ...[
                          if (i > 0) const SizedBox(width: 18),
                          Expanded(
                            flex: i == 0 ? 5 : 4,
                            child: _Tile(tile: t, autofocus: t.id == focus, onOpen: onOpen, large: true),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: short ? 14 : 20),
                  Expanded(
                    flex: 2,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, t) in small.indexed) ...[
                          if (i > 0) const SizedBox(width: 18),
                          Expanded(
                            child: _Tile(tile: t, autofocus: t.id == focus, onOpen: onOpen),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: short ? 10 : 18),
                  Row(
                    children: [
                      const ImadLabsMark(size: 20, prefix: 'by '),
                      const Spacer(),
                      Text(
                        'Hold OK on a channel or category for more options  ·  v${AppVersion.name}',
                        style: const TextStyle(color: Brand.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.onOpen, this.autofocus = false, this.large = false});

  final HomeTile tile;
  final ValueChanged<Object> onOpen;
  final bool autofocus;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = tile;
    return TvFocusable(
      autofocus: autofocus,
      borderRadius: 20,
      scale: 1.04,
      onSelect: () => onOpen(t.id),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: t.colors),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final h = c.maxHeight;
            final iconSize = (large ? h * 0.34 : h * 0.3).clamp(22.0, 84.0);
            return Stack(
              children: [
                // Large faint icon in the corner for depth (no blur, cheap to draw).
                Positioned(
                  right: -h * 0.08,
                  bottom: -h * 0.12,
                  child: Icon(t.icon, size: h * 0.8, color: Colors.white.withValues(alpha: 0.05)),
                ),
                Padding(
                  padding: EdgeInsets.all(large ? 22 : 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(t.icon, size: iconSize, color: Colors.white),
                          const Spacer(),
                          if (t.count != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                formatCount(t.count!),
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                            ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        t.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: Brand.headingFont,
                          fontSize: large ? (h * 0.13).clamp(18.0, 34.0) : (h * 0.15).clamp(14.0, 22.0),
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      if (t.subtitle != null && h > 90)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            t.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.72), fontSize: large ? 14 : 12),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DateClock extends StatefulWidget {
  const _DateClock();

  @override
  State<_DateClock> createState() => _DateClockState();
}

class _DateClockState extends State<_DateClock> {
  late final Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 20), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        formatClock(_now),
        style: const TextStyle(fontFamily: Brand.headingFont, fontSize: 30, fontWeight: FontWeight.w800, height: 1),
      ),
      const SizedBox(height: 4),
      Text(
        '${_days[_now.weekday - 1]}, ${_now.day} ${_months[_now.month - 1]}',
        style: const TextStyle(color: Brand.textSecondary, fontSize: 13),
      ),
    ],
  );
}

/// Colours for the home tiles (ImadLabs palette).
abstract final class TileColors {
  static const live = [Color(0xFF00B894), Color(0xFF006E5A)];
  static const movies = [Color(0xFF2563EB), Color(0xFF1E3A8A)];
  static const series = [Color(0xFF7C3AED), Color(0xFF4C1D95)];
  static const favorites = [Color(0xFFF59E0B), Color(0xFF9A5B00)];
  static const search = [Color(0xFF0EA5E9), Color(0xFF075985)];
  static const settings = [Color(0xFF334155), Color(0xFF1E293B)];
  static const resume = [Color(0xFFE11D48), Color(0xFF881337)];
}

/// Subtitle for the Live TV tile: the channel watched last, if any.
String? lastChannelLine(LibraryStore store, Session session) {
  final id = session.profile?.id;
  if (id == null) return null;
  final last = store.lastChannel(id);
  return last == null ? null : 'Last watched: ${last.name}';
}

/// Live/movie/series totals once the playlist is loaded.
int? totalFor(Session session, ContentType type) => session.total(type);
