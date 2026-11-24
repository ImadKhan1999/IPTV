import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../data/library_store.dart';
import '../../data/updater.dart';
import '../platform.dart';
import '../theme.dart';

/// Looks for a new version. With [quiet] (app start) nothing is shown unless one exists,
/// and GitHub is asked at most once a day.
Future<void> checkForUpdates(BuildContext context, {bool quiet = false}) async {
  final store = context.read<LibraryStore>();
  if (!AppPlatform.isAndroid && !Platform.isWindows) {
    if (!quiet) _snack(context, 'Updates for this platform come from the GitHub releases page.');
    return;
  }
  if (quiet) {
    if (AppVersion.name.endsWith('-dev')) return; // local builds
    final last = store.lastUpdateCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 20)) return;
  }
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
    return;
  }
  if (!context.mounted) return;
  if (info == null) {
    if (!quiet) _snack(context, 'You have the latest version (${AppVersion.label}).');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => UpdateDialog(info: info!),
  );
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
