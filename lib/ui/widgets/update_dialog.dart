import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/library_store.dart';
import '../../data/updater.dart';
import '../platform.dart';
import '../theme.dart';

/// Looks for a new version. With [quiet] (automatic checks) nothing is shown unless one exists.
/// Returns true when an update dialog was shown.
Future<bool> checkForUpdates(BuildContext context, {bool quiet = false, String? skipVersion}) async {
  final store = context.read<LibraryStore>();
  if (!AppPlatform.isAndroid && !Platform.isWindows) {
    if (!quiet) _snack(context, 'Updates for this platform come from the GitHub releases page.');
    return false;
  }
  if (quiet && AppVersion.name.endsWith('-dev')) return false; // local builds
  UpdateInfo? info;
  try {
    info = await Updater().check(
      android: AppPlatform.isAndroid,
      windows: Platform.isWindows,
      abis: await AppPlatform.abis(),
    );
    await store.markUpdateCheck();
  } catch (e) {
    if (!quiet && context.mounted) _snack(context, 'Could not check for updates. Check your internet connection.');
    return false;
  }
  if (!context.mounted) return false;
  if (info == null) {
    if (!quiet) _snack(context, 'You have the latest version (${AppVersion.label}).');
    return false;
  }
  if (quiet && info.version == skipVersion) return false;
  await showDialog<void>(
    context: context,
    builder: (_) => UpdateDialog(info: info!),
  );
  UpdateWatcher.lastOffered = info.version;
  return true;
}

/// Checks for updates by itself: every time the app is opened or brought back,
/// and again at random moments (every 30-90 minutes) while it runs, even during playback.
///
/// If the person taps "Later", the same version isn't offered again by the random checks
/// for a few hours; opening the app again always offers it.
class UpdateWatcher extends StatefulWidget {
  const UpdateWatcher({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  /// The version the last dialog offered.
  static String? lastOffered;

  @override
  State<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends State<UpdateWatcher> with WidgetsBindingObserver {
  final _random = Random();
  Timer? _timer;
  bool _checking = false;
  DateTime? _lastCheck;
  DateTime? _laterAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer(const Duration(seconds: 4), () => _check(opened: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Opening the app from the TV home screen resumes it: check again unless we just did.
    final last = _lastCheck;
    if (last == null || DateTime.now().difference(last) > const Duration(minutes: 2)) {
      _schedule(const Duration(seconds: 3), opened: true);
    }
  }

  void _schedule(Duration after, {bool opened = false}) {
    _timer?.cancel();
    _timer = Timer(after, () => _check(opened: opened));
  }

  Future<void> _check({bool opened = false}) async {
    if (_checking) return;
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      _schedule(const Duration(seconds: 10), opened: opened);
      return;
    }
    _checking = true;
    _lastCheck = DateTime.now();
    try {
      final snoozed = !opened && _laterAt != null && DateTime.now().difference(_laterAt!) < const Duration(hours: 3);
      final shown = await checkForUpdates(ctx, quiet: true, skipVersion: snoozed ? UpdateWatcher.lastOffered : null);
      // Still here after the dialog closed means "Later" (installing closes or replaces the app).
      if (shown) _laterAt = DateTime.now();
    } finally {
      _checking = false;
      _schedule(Duration(minutes: 30 + _random.nextInt(61)));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  double? _progress;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final file = await Updater().download(widget.info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (AppPlatform.isAndroid) {
        final ok = await AppPlatform.installApk(file.path);
        if (!ok) throw Exception('installer');
        if (mounted) Navigator.pop(context);
      } else if (Platform.isWindows) {
        // The installer replaces the app files, so close the app once it has started.
        await Process.start(file.path, ['/SILENT', '/SP-', '/CLOSEAPPLICATIONS'], mode: ProcessStartMode.detached);
        exit(0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = AppPlatform.isAndroid
              ? 'Could not install. Allow "Install unknown apps" for iPTV in Android settings, then try again.'
              : 'Download failed. Check your internet connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final busy = _progress != null;
    return AlertDialog(
      title: Text('Update to ${info.version}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You have ${AppVersion.label}.', style: const TextStyle(color: Brand.textSecondary)),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: Text(info.notes)),
              ),
            ],
            if (info.assetUrl == null) ...[
              const SizedBox(height: 12),
              Text('Download it from ${info.pageUrl}', style: const TextStyle(color: Brand.textSecondary)),
            ],
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
              const SizedBox(height: 6),
              Text('Downloading ${((_progress ?? 0) * 100).round()}%'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Brand.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Later')),
        if (info.assetUrl != null)
          FilledButton.icon(
            autofocus: true,
            onPressed: busy ? null : _install,
            icon: const Icon(Icons.system_update_rounded),
            label: const Text('Update now'),
          ),
      ],
    );
  }
}
