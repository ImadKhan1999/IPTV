import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/library_store.dart';
import '../../data/pairing_server.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Copies this device's playlists to another TV, phone or PC on the same Wi-Fi.
///
/// The other device only needs to show its add-playlist screen (the one with the QR code);
/// it then appears here and one press sends everything. It starts on the playlist
/// this device is using.
class SendPlaylistsScreen extends StatefulWidget {
  const SendPlaylistsScreen({super.key});

  @override
  State<SendPlaylistsScreen> createState() => _SendPlaylistsScreenState();
}

class _SendPlaylistsScreenState extends State<SendPlaylistsScreen> {
  final _devices = <String, NearbyDevice>{};
  StreamSubscription<NearbyDevice>? _scan;
  Timer? _again;
  bool _scanning = false;
  String? _sending;
  final _sent = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _again?.cancel();
    super.dispose();
  }

  void _search() {
    _scan?.cancel();
    _again?.cancel();
    setState(() => _scanning = true);
    _scan = discoverNearby().listen(
      (d) {
        if (mounted) setState(() => _devices[d.address] = d);
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _scanning = false);
        // Keep looking while this screen is open, so a TV that's turned on later shows up.
        _again = Timer(const Duration(seconds: 4), _search);
      },
    );
  }

  Future<void> _send(NearbyDevice d) async {
    final store = context.read<LibraryStore>();
    setState(() {
      _sending = d.address;
      _error = null;
    });
    try {
      await d.send(
        PlaylistTransfer(
          from: await AppPlatform.deviceName(),
          profiles: List.of(store.profiles),
          activeId: store.activeProfile?.id,
        ),
      );
      if (!mounted) return;
      setState(() => _sent.add(d.address));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send to ${d.name}: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final devices = _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      appBar: AppBar(title: const Text('Send playlists to another device')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('On the other TV, phone or PC:', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      const Text(
                        '1. Install iPTV and open it (or go to Settings → Add playlist).\n'
                        '2. Leave it on the screen with the QR code.\n'
                        '3. Make sure it\'s on the same Wi-Fi as this device, then pick it below.',
                        style: TextStyle(color: Brand.textSecondary, height: 1.5),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Sends ${store.profiles.length} playlist${store.profiles.length == 1 ? '' : 's'} '
                        'with their logins. The other device starts on "${store.activeProfile?.name ?? '-'}".',
                        style: const TextStyle(color: Brand.textMuted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text('Devices nearby', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 12),
                  if (_scanning) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              const SizedBox(height: 10),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    _scanning ? 'Looking for devices…' : 'No device found yet. Open the QR code screen on the other device.',
                    style: const TextStyle(color: Brand.textSecondary),
                  ),
                ),
              for (final (i, d) in devices.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TvFocusable(
                    autofocus: i == 0,
                    borderRadius: 12,
                    scale: 1.02,
                    onSelect: _sending != null ? null : () => _send(d),
                    child: Container(
                      color: Brand.surfaceCard,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(
                        children: [
                          const Icon(Icons.tv_rounded, color: Brand.sky),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(d.address, style: const TextStyle(color: Brand.textMuted, fontSize: 12)),
                              ],
                            ),
                          ),
                          if (_sending == d.address)
                            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          else if (_sent.contains(d.address))
                            const Row(
                              children: [
                                Icon(Icons.check_circle_rounded, color: Brand.cyberMint, size: 20),
                                SizedBox(width: 6),
                                Text('Sent', style: TextStyle(color: Brand.cyberMint)),
                              ],
                            )
                          else
                            const Text('Send', style: TextStyle(color: Brand.cyberMint, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: Brand.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
