import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform.dart';
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
  bool _okDown = false;
  bool _longFired = false;
  bool _hovered = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) {
      final k = e.logicalKey;
      final wasDown = _okDown;
      _okDown = false;
      if (wasDown &&
          !_longFired &&
          widget.onLongPress != null &&
          (k == LogicalKeyboardKey.select ||
              k == LogicalKeyboardKey.enter ||
              k == LogicalKeyboardKey.numpadEnter ||
              k == LogicalKeyboardKey.gameButtonA)) {
        widget.onSelect?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    // Long-press OK / menu key on remotes opens the context action (e.g. add to favorites).
    if ((k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.info) && widget.onLongPress != null) {
      widget.onLongPress!();
      return KeyEventResult.handled;
    }
    final isOk =
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA;
    if (!isOk) return KeyEventResult.ignored;
    if (widget.onLongPress == null) {
      if (e is KeyDownEvent) widget.onSelect?.call();
      return KeyEventResult.handled;
    }
    // With a long-press action: a short press of OK selects (on release), holding it opens the menu.
    if (e is KeyDownEvent) {
      _okDown = true;
      _longFired = false;
    } else if (e is KeyRepeatEvent && _okDown && !_longFired) {
      _longFired = true;
      widget.onLongPress!();
    }
    return KeyEventResult.handled;
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
        if (!f) _okDown = false;
        setState(() => _hasFocus = f);
        widget.onFocus?.call(f);
        if (f) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: lowEffects ? Duration.zero : const Duration(milliseconds: 160),
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
          child: _decorated(active),
        ),
      ),
    );
  }

  Widget _decorated(bool active) {
    final decoration = BoxDecoration(
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
      // A blurred glow is expensive on TV GPUs; TVs get a crisp ring instead.
      boxShadow: _focused && !lowEffects
          ? [BoxShadow(color: Brand.cyberMint.withValues(alpha: 0.28), blurRadius: 18, spreadRadius: 1)]
          : null,
    );
    final clipped = ClipRRect(borderRadius: BorderRadius.circular(widget.borderRadius - 1), child: widget.child);
    if (lowEffects) {
      // No zoom/fade animations: every D-pad press repaints at once, nothing to tween.
      return RepaintBoundary(
        child: Transform.scale(
          scale: _focused ? widget.scale : 1,
          child: DecoratedBox(position: DecorationPosition.foreground, decoration: decoration, child: clipped),
        ),
      );
    }
    return AnimatedScale(
      scale: _focused ? widget.scale : 1,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: AnimatedContainer(duration: const Duration(milliseconds: 140), decoration: decoration, child: clipped),
    );
  }
}

/// True on Android TV: skip animations, glows and big image decodes that make cheap boxes lag.
bool get lowEffects => AppPlatform.isTv;

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
          cacheWidth: w.clamp(32, lowEffects ? 400 : 800),
          gaplessPlayback: true,
          filterQuality: lowEffects ? FilterQuality.low : FilterQuality.medium,
          errorBuilder: (_, _, _) => placeholder,
          frameBuilder: (context, child, frame, sync) => sync || lowEffects
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

/// Loading indicator: just the spinner, no text (clean, set-top box style).
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3)));
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

/// One-line text prompt (group names and similar). Returns null when cancelled.
Future<String?> askText(BuildContext context, {required String title, String? hint, String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TvTextKeys(
        child: TextField(
          controller: c,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
      ],
    ),
  );
}

class _ShowKeyboardIntent extends Intent {
  const _ShowKeyboardIntent();
}

/// Makes a text box usable with a TV remote: OK opens the on-screen keyboard, and
/// up/down move to the next control instead of getting stuck inside the box.
class TvTextKeys extends StatelessWidget {
  const TvTextKeys({super.key, required this.child});

  final Widget child;

  static void showKeyboard() => SystemChannels.textInput.invokeMethod<void>('TextInput.show');

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.select): _ShowKeyboardIntent(),
      SingleActivator(LogicalKeyboardKey.gameButtonA): _ShowKeyboardIntent(),
      SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
      SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
    },
    child: Actions(
      actions: {
        _ShowKeyboardIntent: CallbackAction<_ShowKeyboardIntent>(onInvoke: (_) => showKeyboard()),
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(onInvoke: (i) => moveFocus(i.direction)),
      },
      child: child,
    ),
  );
}

/// Moves focus one step in [direction]; at the edge of a pane (a [FocusScope]) it carries
/// on into whatever is next to that pane, such as the top bar above a list.
bool moveFocus(TraversalDirection direction) {
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return false;
  if (node.focusInDirection(direction)) return true;
  var scope = node.enclosingScope;
  while (scope != null && scope.enclosingScope != null) {
    if (scope.focusInDirection(direction)) return true;
    scope = scope.enclosingScope;
  }
  return false;
}

/// Remote navigation between side-by-side panes (categories | list | preview).
///
/// Each pane is a [FocusScope] with one of [panes] (left to right). Left/right move inside
/// a pane first and jump to the neighbouring pane at its edge, landing on the item that was
/// focused there last. Back returns to the first pane (categories); from there it goes on
/// to the home screen as usual.
class PaneKeys extends StatelessWidget {
  const PaneKeys({super.key, required this.panes, required this.child, this.backToFirst = true});

  final List<FocusScopeNode> panes;
  final Widget child;

  /// Back from a later pane returns to the first one (off where Back should close instead).
  final bool backToFirst;

  static bool _inTextField(FocusNode? n) => n?.context?.findAncestorWidgetOfExactType<TvTextKeys>() != null;

  /// Focuses [scope]: its last focused item, or its first item ([first] forces that).
  static void focusPane(FocusScopeNode scope, {bool first = false}) {
    final remembered = scope.focusedChild;
    if (!first && remembered != null && remembered.context != null && remembered is! FocusScopeNode) {
      remembered.requestFocus();
      return;
    }
    final target = scope.traversalDescendants
        .where((d) => d is! FocusScopeNode && d.canRequestFocus && !_inTextField(d))
        .firstOrNull;
    (target ?? scope).requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final i = panes.indexWhere((p) => p.hasFocus);
    if (i < 0) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final primary = FocusManager.instance.primaryFocus;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowLeft) {
      if (_inTextField(primary)) return KeyEventResult.ignored; // moving the text cursor
      final right = k == LogicalKeyboardKey.arrowRight;
      if (primary != null && primary.focusInDirection(right ? TraversalDirection.right : TraversalDirection.left)) {
        return KeyEventResult.handled;
      }
      for (var j = i + (right ? 1 : -1); j >= 0 && j < panes.length; j += right ? 1 : -1) {
        if (panes[j].traversalDescendants.isNotEmpty) {
          focusPane(panes[j]);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (_inTextField(primary)) return KeyEventResult.ignored; // TvTextKeys handles these
      moveFocus(k == LogicalKeyboardKey.arrowUp ? TraversalDirection.up : TraversalDirection.down);
      return KeyEventResult.handled;
    }
    if (backToFirst &&
        e is KeyDownEvent &&
        (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) &&
        i > 0) {
      focusPane(panes.first);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: child);
}

/// Makes sure a remote key press never goes nowhere. When nothing on screen holds focus
/// (for example after the player closes, or when a screen was built behind another one),
/// the first arrow or OK press puts focus on the top-left item of the screen in front,
/// instead of being dropped.
class FocusRescue extends StatefulWidget {
  const FocusRescue({super.key, required this.child});

  final Widget child;

  /// The item a lost remote press lands on: the top-left focusable item of the front screen.
  static FocusNode? target() {
    final candidates = <(FocusNode, Rect)>[];
    for (final n in FocusManager.instance.rootScope.traversalDescendants) {
      final ctx = n.context;
      if (n is FocusScopeNode || ctx == null || !ctx.mounted || !n.canRequestFocus) continue;
      if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) continue;
      if (ctx.findAncestorWidgetOfExactType<TvTextKeys>() != null) continue;
      if (ModalRoute.of(ctx)?.isCurrent == false) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) continue;
      candidates.add((n, n.rect));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final dy = a.$2.top.compareTo(b.$2.top);
      return dy != 0 && (a.$2.top - b.$2.top).abs() > 8 ? dy : a.$2.left.compareTo(b.$2.left);
    });
    return candidates.first.$1;
  }

  /// True when no real item has focus (nothing, or only a screen/pane holder).
  static bool get focusLost {
    final p = FocusManager.instance.primaryFocus;
    return p == null || p is FocusScopeNode;
  }

  /// Focuses [target] when focus is lost. Returns whether it did.
  static bool rescue() {
    if (!focusLost) return false;
    final t = target();
    t?.requestFocus();
    return t != null;
  }

  @override
  State<FocusRescue> createState() => _FocusRescueState();
}

class _FocusRescueState extends State<FocusRescue> {
  static final _navKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    super.dispose();
  }

  // Runs before the focused widget sees the key. A press that only brings focus back is
  // used up, so it lands on the first item instead of also moving past it or opening it.
  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !_navKeys.contains(e.logicalKey)) return KeyEventResult.ignored;
    return FocusRescue.rescue() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
