import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/parental.dart';
import 'welcome_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final session = context.watch<Session>();
    final account = session.account;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 20),

        // Playlists ---------------------------------------------------------------
        const _Section('Playlists'),
        for (final p in store.profiles)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(
                p.id == store.activeProfile?.id ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: p.id == store.activeProfile?.id ? Brand.cyberMint : Brand.textMuted,
              ),
              title: Text(p.name),
              subtitle: Text(p.kind.label),
              onTap: () async {
                if (p.id != store.activeProfile?.id) {
                  Parental.lockAll();
                  await session.connect(p);
                }
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_rounded),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddPlaylistScreen(existing: p))),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Remove "${p.name}"?'),
                          content: const Text('Its favorites and watch history are removed too.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(
                              autofocus: true,
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      );
                      if (yes != true) return;
                      final wasActive = p.id == store.activeProfile?.id;
                      await store.removeProfile(p.id);
                      await session.cache.clearGroup(p.id);
                      if (wasActive) {
                        session.disconnect();
                        final next = store.activeProfile;
                        if (next != null) await session.connect(next);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddPlaylistScreen())),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add playlist'),
          ),
        ),
        if (account != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 28,
                runSpacing: 8,
                children: [
                  if (account.status != null) _Fact('Status', account.status!),
                  if (account.expiresAt != null)
                    _Fact(
                      'Expires',
                      '${account.expiresAt!.year}-${account.expiresAt!.month.toString().padLeft(2, '0')}-${account.expiresAt!.day.toString().padLeft(2, '0')}',
                    ),
                  if (account.maxConnections != null)
                    _Fact('Connections', '${account.activeConnections ?? 0} / ${account.maxConnections}'),
                ],
              ),
            ),
          ),
        ],

        // Playlist data ----------------------------------------------------------
        const _Section('Playlist data'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.sync_rounded),
          title: const Text('Refresh playlist now'),
          subtitle: Text(
            session.state == SessionState.connecting
                ? 'Downloading channels, movies, series and TV guide…'
                : [
                    if (session.cachedAt != null) 'Saved on this device ${_ago(session.cachedAt!)}',
                    'Opens instantly from the saved copy. Refresh to get new channels now.',
                  ].join('. '),
          ),
          onTap: session.state == SessionState.connecting
              ? null
              : () async {
                  final p = store.activeProfile;
                  if (p == null) return;
                  final ok = await session.connect(p, refresh: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(ok ? 'Playlist refreshed' : 'Refresh failed: ${session.error}')),
                    );
                  }
                },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.update_rounded),
          title: const Text('Check for playlist changes'),
          subtitle: const Text('The saved copy is used right away and updated in the background after this time.'),
          trailing: DropdownButton<int>(
            value: const [0, 6, 12, 24, 72, 168].contains(store.player.refreshHours) ? store.player.refreshHours : 24,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Every launch')),
              DropdownMenuItem(value: 6, child: Text('Every 6 hours')),
              DropdownMenuItem(value: 12, child: Text('Every 12 hours')),
              DropdownMenuItem(value: 24, child: Text('Daily')),
              DropdownMenuItem(value: 72, child: Text('Every 3 days')),
              DropdownMenuItem(value: 168, child: Text('Weekly')),
            ],
            onChanged: (v) => store.updatePlayer(store.player.copyWith(refreshHours: v)),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_note_rounded),
          title: const Text('TV guide'),
          subtitle: Text(
            session.guideLoading
                ? 'Loading…'
                : session.guide.isEmpty
                ? 'Uses your provider\'s guide, or the EPG URL set on the playlist.'
                : '${session.guide.channelCount} channels with guide data',
          ),
        ),

        // Player -----------------------------------------------------------------
        const _Section('Player'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Hardware decoding'),
          subtitle: const Text('Smoother playback and less battery. Turn off if a channel shows a black screen.'),
          value: store.player.hardwareDecoding,
          onChanged: (v) => store.updatePlayer(store.player.copyWith(hardwareDecoding: v)),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Buffer'),
          subtitle: const Text('More buffer rides out slow connections but starts a little slower.'),
          trailing: DropdownButton<int>(
            value: store.player.bufferSeconds,
            items: [
              for (final s in [3, 5, 8, 15, 30]) DropdownMenuItem(value: s, child: Text('$s s')),
            ],
            onChanged: (v) => store.updatePlayer(store.player.copyWith(bufferSeconds: v)),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Live stream format (Xtream)'),
          subtitle: const Text('MPEG-TS works for most providers; try HLS if channels stutter.'),
          trailing: DropdownButton<String>(
            value: store.player.liveFormat,
            items: const [
              DropdownMenuItem(value: 'ts', child: Text('MPEG-TS')),
              DropdownMenuItem(value: 'm3u8', child: Text('HLS')),
            ],
            onChanged: (v) => store.updatePlayer(store.player.copyWith(liveFormat: v)),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Play next episode automatically'),
          value: store.player.autoPlayNextEpisode,
          onChanged: (v) => store.updatePlayer(store.player.copyWith(autoPlayNextEpisode: v)),
        ),

        // Parental control -------------------------------------------------------
        const _Section('Parental control'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.pin_rounded),
          title: Text(store.hasPin ? 'Change PIN' : 'Set a PIN'),
          subtitle: const Text('Locked categories ask for this PIN.'),
          onTap: () async {
            if (store.hasPin && !await Parental.askPin(context, title: 'Current PIN')) return;
            if (!context.mounted) return;
            final pin = await showDialog<String>(
              context: context,
              builder: (_) => const PinDialog(title: 'New PIN'),
            );
            if (pin == null || !context.mounted) return;
            final again = await showDialog<String>(
              context: context,
              builder: (_) => const PinDialog(title: 'Repeat PIN'),
            );
            if (again != pin) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PINs did not match')));
              }
              return;
            }
            await store.setPin(pin);
            Parental.lockAll();
          },
        ),
        if (store.hasPin)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_open_rounded),
            title: const Text('Remove PIN'),
            onTap: () async {
              if (await Parental.askPin(context)) await store.setPin(null);
            },
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lock adult categories'),
          subtitle: Text(store.hasPin ? 'Adult categories need the PIN.' : 'Adult categories are hidden.'),
          value: store.hideAdult,
          onChanged: (v) async {
            if (!v && store.hasPin && !await Parental.askPin(context)) return;
            await store.setHideAdult(v);
          },
        ),
        if (session.source != null && store.hasPin)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.category_rounded),
            title: const Text('Choose locked categories'),
            onTap: () async {
              if (!await Parental.askPin(context)) return;
              if (context.mounted) {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const _LockedCategoriesScreen()));
              }
            },
          ),

        // History -----------------------------------------------------------------
        const _Section('History'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history_toggle_off_rounded),
          title: const Text('Clear watch history'),
          onTap: () {
            final id = store.activeProfile?.id;
            if (id != null) store.clearHistory(id);
          },
        ),

        // About ---------------------------------------------------------------------
        const _Section('About'),
        const Row(
          children: [
            AppLogo(size: 44),
            SizedBox(width: 16),
            Text('Version 1.0.0', style: TextStyle(color: Brand.textSecondary)),
          ],
        ),
        const SizedBox(height: 12),
        const ImadLabsMark(size: 26, prefix: 'Made by '),
        const SizedBox(height: 8),
        const Text(
          'iPTV is a player only. It does not include any channels or content; add the playlist from your own provider.',
          style: TextStyle(color: Brand.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(color: Brand.cyberMint, fontWeight: FontWeight.w700, letterSpacing: 1.2, fontSize: 12),
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Brand.textMuted, fontSize: 12)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}

class _LockedCategoriesScreen extends StatefulWidget {
  const _LockedCategoriesScreen();

  @override
  State<_LockedCategoriesScreen> createState() => _LockedCategoriesScreenState();
}

class _LockedCategoriesScreenState extends State<_LockedCategoriesScreen> {
  late final Future<List<Category>> _cats = () async {
    final s = context.read<Session>().source!;
    final out = <Category>[];
    for (final t in ContentType.values) {
      try {
        out.addAll(await s.categories(t));
      } catch (_) {}
    }
    return out;
  }();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final profileId = context.read<Session>().profile!.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Locked categories')),
      body: FutureBuilder(
        future: _cats,
        builder: (_, snap) {
          if (!snap.hasData) return const LoadingView();
          final cats = snap.data!;
          return ListView.builder(
            itemCount: cats.length,
            itemBuilder: (_, i) {
              final c = cats[i];
              return CheckboxListTile(
                title: Text(c.name),
                subtitle: Text(switch (c.type) {
                  ContentType.live => 'Live TV',
                  ContentType.movie => 'Movies',
                  ContentType.series => 'Series',
                }),
                value: store.isCategoryLocked(profileId, c),
                onChanged: (c.isAdult && store.hideAdult) ? null : (_) => store.toggleCategoryLock(profileId, c),
              );
            },
          );
        },
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
}
