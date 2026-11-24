import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/playlist_link.dart';
import '../../data/pairing_server.dart';
import '../platform.dart';
import '../theme.dart';

/// "Use your phone": a QR code that opens a page on the phone where the playlist link is
/// pasted. Whatever the phone sends arrives through [onReceived].
class PairCard extends StatefulWidget {
  const PairCard({super.key, required this.onReceived, this.onImported, this.compact = false, this.qrSize});

  /// Playlists sent from another iPTV device on the network.
  final ValueChanged<PlaylistTransfer>? onImported;

  /// Overrides the QR code size (short TV screens).
  final double? qrSize;

  final ValueChanged<PlaylistDraft> onReceived;

  /// Smaller layout for dialogs.
  final bool compact;

  /// Tests and screenshots: show this link instead of starting a real server.
  static String? debugFakeUrl;

  @override
  State<PairCard> createState() => _PairCardState();
}

class _PairCardState extends State<PairCard> {
  PairingServer? _server;
  StreamSubscription<PlaylistDraft>? _sub;
  StreamSubscription<PlaylistTransfer>? _importSub;
  String? _error;
  bool _received = false;

  @override
  void initState() {
    super.initState();
    if (PairCard.debugFakeUrl == null) _start();
  }

  Future<void> _start() async {
    try {
      final s = await PairingServer.start(deviceName: await AppPlatform.deviceName());
      if (!mounted) {
        await s.close();
        return;
      }
      _sub = s.received.listen((d) {
        if (!mounted) return;
        setState(() => _received = true);
        widget.onReceived(d);
      });
      _importSub = s.imported.listen((t) {
        if (!mounted) return;
        setState(() => _received = true);
        widget.onImported?.call(t);
      });
      setState(() {
        _server = s;
        _error = s.url == null ? 'Connect this device to Wi-Fi or Ethernet to use your phone.' : null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start phone pairing on this device.');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _importSub?.cancel();
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    final fake = PairCard.debugFakeUrl;
    final url = fake ?? server?.url;
    final qrSize = widget.qrSize ?? (widget.compact ? 200.0 : 220.0);
    Widget qr;
    if (_error != null) {
      qr = SizedBox(
        width: qrSize,
        height: qrSize,
        child: Center(
          child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.textSecondary)),
        ),
      );
    } else if (url == null) {
      qr = SizedBox(width: qrSize, height: qrSize, child: const Center(child: CircularProgressIndicator()));
    } else {
      qr = Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: QrImageView(
          data: url,
          size: qrSize - 24,
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner_rounded, color: Brand.cyberMint),
            const SizedBox(width: 8),
            Text('Add with your phone', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Scan with your phone camera, paste your link\nand tap Send. No typing on the remote.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 14),
        qr,
        const SizedBox(height: 10),
        if (_received)
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded, color: Brand.cyberMint, size: 18),
              SizedBox(width: 6),
              Text('Received, connecting…', style: TextStyle(color: Brand.cyberMint)),
            ],
          )
        else if (url != null)
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Phone and TV must be on the same Wi-Fi.\nOr open '),
                TextSpan(
                  text: url.replaceFirst('http://', ''),
                  style: const TextStyle(color: Brand.textPrimary, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Brand.textMuted, fontSize: 12),
          ),
      ],
    );
  }
}

/// Shows [PairCard] in a dialog. Returns the [PlaylistDraft] a phone sent, the
/// [PlaylistTransfer] another device sent, or null if closed.
Future<Object?> showPairDialog(BuildContext context) => showDialog<Object>(
  context: context,
  builder: (ctx) => AlertDialog(
    content: PairCard(
      compact: true,
      onReceived: (d) => Navigator.of(ctx).pop(d),
      onImported: (t) => Navigator.of(ctx).pop(t),
    ),
    actions: [TextButton(autofocus: true, onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close'))],
  ),
);
