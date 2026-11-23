import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../theme.dart';

/// Parental control helpers. Locked categories ask for the PIN once per app session.
abstract final class Parental {
  static final _unlocked = <String>{};

  /// Categories the user may see. Adult categories are hidden entirely when no PIN is set
  /// and "hide adult" is on; with a PIN they are shown with a lock.
  static List<Category> visible(LibraryStore store, String profileId, List<Category> cats) {
    if (store.hasPin) return cats;
    return cats.where((c) => !(store.hideAdult && c.isAdult)).toList();
  }

  static bool isLocked(LibraryStore store, String profileId, Category c) =>
      store.hasPin && store.isCategoryLocked(profileId, c) && !_unlocked.contains('$profileId|${c.type.name}|${c.id}');

  static Future<bool> unlock(BuildContext context, String profileId, Category c) async {
    final store = context.read<LibraryStore>();
    if (!isLocked(store, profileId, c)) return true;
    final ok = await askPin(context, title: 'Unlock "${c.name}"');
    if (ok) _unlocked.add('$profileId|${c.type.name}|${c.id}');
    return ok;
  }

  static Future<bool> askPin(BuildContext context, {String title = 'Enter PIN'}) async {
    final store = context.read<LibraryStore>();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => PinDialog(title: title),
    );
    if (result == null) return false;
    final ok = store.checkPin(result);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wrong PIN')));
    }
    return ok;
  }

  static void lockAll() => _unlocked.clear();
}

/// Four-digit PIN entry that works with a TV remote's number keys, a keyboard or touch.
class PinDialog extends StatefulWidget {
  const PinDialog({super.key, this.title = 'Enter PIN', this.subtitle});

  final String title;
  final String? subtitle;

  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  String _pin = '';

  void _add(String d) {
    if (_pin.length >= 4) return;
    setState(() => _pin += d);
    if (_pin.length == 4) Navigator.of(context).pop(_pin);
  }

  void _back() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, IconData? icon, bool autofocus = false}) => Padding(
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        width: 64,
        height: 56,
        child: OutlinedButton(
          autofocus: autofocus,
          onPressed: onTap ?? () => _add(label),
          child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: 20)),
        ),
      ),
    );

    return Focus(
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final ch = e.character;
        if (ch != null && RegExp(r'^\d$').hasMatch(ch)) {
          _add(ch);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.backspace || e.logicalKey == LogicalKeyboardKey.delete) {
          _back();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AlertDialog(
        title: Text(widget.title, textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.subtitle!, style: const TextStyle(color: Brand.textSecondary)),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                4,
                (i) => Container(
                  margin: const EdgeInsets.all(8),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? Brand.cyberMint : Colors.transparent,
                    border: Border.all(color: Brand.cyberMint, width: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (final d in row) key(d, autofocus: d == '5')],
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                key('', icon: Icons.close_rounded, onTap: () => Navigator.of(context).pop()),
                key('0'),
                key('', icon: Icons.backspace_outlined, onTap: _back),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
