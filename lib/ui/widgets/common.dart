import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// A focusable tile that works the same with a TV remote (D-pad + OK), a keyboard,
/// a mouse and touch. Focus shows a mint ring and a slight zoom so it is visible
/// from across the room.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onLongPress,
    this.onFocus,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = 14,
    this.scale = 1.05,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocus;
  final bool autofocus;
  final FocusNode? focusNode;
  final double borderRadius;
  final double scale;
  final bool selected;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  bool _hovered = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    // Long-press OK / menu key on remotes opens the context action (e.g. add to favorites).
    if ((k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.info) && widget.onLongPress != null) {
      widget.onLongPress!();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.gameButtonA)) {
      widget.onSelect?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode _) {
    if (_hasFocus && mounted) setState(() {});
  }

  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    // Touch users never see the focus ring; remote, keyboard and mouse users do.
    _focused = _hasFocus && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final active = _focused || _hovered;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      onFocusChange: (f) {
        setState(() => _hasFocus = f);
        widget.onFocus?.call(f);
        if (f) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
          );
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onSelect,
          onLongPress: widget.onLongPress,
          onSecondaryTap: widget.onLongPress,
          child: AnimatedScale(
            scale: _focused ? widget.scale : 1,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: Border.all(
                  color: _focused
                      ? Brand.cyberMint
                      : widget.selected
                      ? Brand.cyberMint.withValues(alpha: 0.5)
                      : active
                      ? Brand.focusRing.withValues(alpha: 0.5)
                      : Colors.transparent,
                  width: _focused ? 2.5 : 1.5,
                ),
                boxShadow: _focused
                    ? [BoxShadow(color: Brand.cyberMint.withValues(alpha: 0.28), blurRadius: 18, spreadRadius: 1)]
                    : null,
              ),
              child: ClipRRect(borderRadius: BorderRadius.circular(widget.borderRadius - 1), child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Network image with a branded placeholder, decoded at display size to save memory on TV boxes.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover, this.icon = Icons.live_tv_rounded, this.cacheWidth});

  final String? url;
  final BoxFit fit;
  final IconData icon;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: Brand.surfaceHover,
      alignment: Alignment.center,
      child: Icon(icon, color: Brand.textMuted, size: 28),
    );
    final u = url;
    if (u == null || u.isEmpty || !u.startsWith('http')) return placeholder;
    return LayoutBuilder(
      builder: (context, c) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final w = cacheWidth ?? (c.maxWidth.isFinite ? (c.maxWidth * dpr).round() : 300);
        return Image.network(
          u,
          fit: fit,
          cacheWidth: w.clamp(32, 800),
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => placeholder,
          frameBuilder: (context, child, frame, sync) => sync
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: child,
                ),
        );
      },
    );
  }
}

/// The HexaCore "iL" symbol with the ImadLabs wordmark ("Imad" white, "Labs" mint).
class ImadLabsMark extends StatelessWidget {
  const ImadLabsMark({super.key, this.size = 28, this.prefix});

  final double size;
  final String? prefix;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/brand/imadlabs_symbol.png', width: size, height: size),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            TextSpan(
              children: [
                if (prefix != null)
                  TextSpan(
                    text: prefix,
                    style: const TextStyle(color: Brand.textSecondary),
                  ),
                const TextSpan(
                  text: 'Imad',
                  style: TextStyle(color: Brand.textPrimary),
                ),
                const TextSpan(
                  text: 'Labs',
                  style: TextStyle(color: Brand.cyberMint),
                ),
              ],
            ),
            style: TextStyle(fontFamily: Brand.headingFont, fontWeight: FontWeight.w800, fontSize: size * 0.55),
          ),
        ),
      ],
    );
  }
}

/// The app mark: icon tile plus "iPTV".
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: Image.asset(
            'assets/brand/app_icon.png',
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
          ),
        ),
        SizedBox(width: size * 0.28),
        Flexible(
          child: Text(
            'iPTV',
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              fontFamily: Brand.headingFont,
              fontWeight: FontWeight.w800,
              fontSize: size * 0.62,
              color: Brand.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3)),
        if (message != null) ...[
          const SizedBox(height: 16),
          Text(message!, style: const TextStyle(color: Brand.textSecondary)),
        ],
      ],
    ),
  );
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.title, this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Brand.textMuted),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              style: const TextStyle(color: Brand.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

/// Thin progress bar in the brand gradient (watch progress, EPG progress).
class BrandProgress extends StatelessWidget {
  const BrandProgress({super.key, required this.value, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height),
    child: SizedBox(
      height: height,
      child: Stack(
        children: [
          Container(color: Brand.border),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(decoration: const BoxDecoration(gradient: Brand.progressGradient)),
          ),
        ],
      ),
    ),
  );
}

String formatClock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 12345 → "12,345".
String formatCount(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Small pill with an item count, used in category lists and the side rail.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.selected = false});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 8),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: selected ? Brand.cyberMint.withValues(alpha: 0.18) : Brand.surfaceHover,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      formatCount(count),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: selected ? Brand.cyberMint : Brand.textMuted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
