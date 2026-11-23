import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../data/library_store.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// First-run screen: brand hero on the left, the add-playlist form on the right.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 900;
    final hero = Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          const AppLogo(size: 64),
          const SizedBox(height: 24),
          Text(
            'Live TV, movies and series\nfrom your IPTV provider.',
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(height: 1.3),
          ),
          const SizedBox(height: 12),
          const Text(
            'Works with M3U playlists, Xtream Codes and Stalker portals.',
            style: TextStyle(color: Brand.textSecondary),
          ),
          const SizedBox(height: 28),
          const ImadLabsMark(size: 26, prefix: 'by '),
        ],
      ),
    );
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.6, -0.4),
            radius: 1.3,
            colors: [Color(0xFF111C33), Brand.deepVoid],
          ),
        ),
        child: SafeArea(
          child: wide
              ? Row(
                  children: [
                    Expanded(child: Center(child: hero)),
                    const Expanded(child: Center(child: AddPlaylistForm())),
                  ],
                )
              : SingleChildScrollView(child: Column(children: [hero, const AddPlaylistForm()])),
        ),
      ),
    );
  }
}

class AddPlaylistScreen extends StatelessWidget {
  const AddPlaylistScreen({super.key, this.existing});

  final PlaylistProfile? existing;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(existing == null ? 'Add playlist' : 'Edit playlist')),
    body: Center(child: AddPlaylistForm(existing: existing, popOnDone: true)),
  );
}

class AddPlaylistForm extends StatefulWidget {
  const AddPlaylistForm({super.key, this.existing, this.popOnDone = false});

  final PlaylistProfile? existing;
  final bool popOnDone;

  @override
  State<AddPlaylistForm> createState() => _AddPlaylistFormState();
}

class _AddPlaylistFormState extends State<AddPlaylistForm> {
  late SourceKind _kind = widget.existing?.kind ?? SourceKind.xtream;
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _user = TextEditingController(text: widget.existing?.username ?? '');
  late final _pass = TextEditingController(text: widget.existing?.password ?? '');
  late final _mac = TextEditingController(text: widget.existing?.mac ?? '00:1A:79:');
  late final _epg = TextEditingController(text: widget.existing?.epgUrl ?? '');
  late final _ua = TextEditingController(text: widget.existing?.userAgent ?? '');
  bool _advanced = false;
  bool _busy = false;
  String? _error;
  bool _obscure = true;

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _pass, _mac, _epg, _ua]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validate() {
    if (_url.text.trim().isEmpty) {
      return switch (_kind) {
        SourceKind.m3u => 'Enter the playlist URL.',
        SourceKind.xtream => 'Enter the server URL.',
        SourceKind.stalker => 'Enter the portal URL.',
      };
    }
    if (_kind == SourceKind.xtream && (_user.text.trim().isEmpty || _pass.text.isEmpty)) {
      return 'Enter the username and password.';
    }
    if (_kind == SourceKind.stalker && !RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(_mac.text.trim())) {
      return 'Enter the MAC address as 00:1A:79:XX:XX:XX.';
    }
    return null;
  }

  String _defaultName() {
    final host = Uri.tryParse(_url.text.trim().contains('://') ? _url.text.trim() : 'http://${_url.text.trim()}')?.host;
    return (host == null || host.isEmpty) ? _kind.label : host;
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final store = context.read<LibraryStore>();
    final session = context.read<Session>();
    final profile = PlaylistProfile(
      id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim().isEmpty ? _defaultName() : _name.text.trim(),
      kind: _kind,
      url: _url.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      mac: _mac.text.trim().toUpperCase(),
      epgUrl: _epg.text.trim(),
      userAgent: _ua.text.trim(),
      addedAt: widget.existing?.addedAt,
    );
    final ok = await session.connect(profile);
    if (!mounted) return;
    if (ok) {
      await store.upsertProfile(profile);
      await store.setActiveProfile(profile.id);
      if (widget.popOnDone && mounted) Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = session.error;
      });
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
    TextInputType? type,
    Widget? suffix,
    bool autofocus = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: type,
        autofocus: autofocus,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.existing == null ? 'Add your playlist' : 'Edit playlist',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    for (final k in SourceKind.values)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: TvFocusable(
                            autofocus: k == _kind && widget.existing == null,
                            selected: k == _kind,
                            borderRadius: 10,
                            scale: 1.03,
                            onSelect: widget.existing != null ? null : () => setState(() => _kind = k),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              color: k == _kind ? Brand.cyberMint.withValues(alpha: 0.14) : Brand.surfaceHover,
                              child: Column(
                                children: [
                                  Icon(switch (k) {
                                    SourceKind.m3u => Icons.playlist_play_rounded,
                                    SourceKind.xtream => Icons.dns_rounded,
                                    SourceKind.stalker => Icons.router_rounded,
                                  }, color: k == _kind ? Brand.cyberMint : Brand.textSecondary),
                                  const SizedBox(height: 4),
                                  Text(
                                    switch (k) {
                                      SourceKind.m3u => 'M3U URL',
                                      SourceKind.xtream => 'Xtream',
                                      SourceKind.stalker => 'Stalker',
                                    },
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: k == _kind ? Brand.textPrimary : Brand.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _field(_name, 'Name (optional)', hint: 'My provider'),
                _field(
                  _url,
                  switch (_kind) {
                    SourceKind.m3u => 'Playlist URL or file path',
                    SourceKind.xtream => 'Server URL',
                    SourceKind.stalker => 'Portal URL',
                  },
                  hint: switch (_kind) {
                    SourceKind.m3u => 'http://provider.com/get.php?...&type=m3u_plus',
                    SourceKind.xtream => 'http://provider.com:8080',
                    SourceKind.stalker => 'http://portal.com:8080/c/',
                  },
                  type: TextInputType.url,
                ),
                if (_kind == SourceKind.xtream) ...[
                  _field(_user, 'Username'),
                  _field(
                    _pass,
                    'Password',
                    obscure: _obscure,
                    suffix: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ],
                if (_kind == SourceKind.stalker) _field(_mac, 'MAC address', hint: '00:1A:79:XX:XX:XX'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _advanced = !_advanced),
                    icon: Icon(_advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                    label: const Text('Advanced'),
                  ),
                ),
                if (_advanced) ...[
                  _field(_epg, 'EPG (XMLTV) URL (optional)', type: TextInputType.url),
                  _field(_ua, 'User-Agent (optional)'),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Brand.error, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_error!, style: const TextStyle(color: Brand.error)),
                        ),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Brand.deepVoid),
                        )
                      : const Icon(Icons.login_rounded),
                  label: Text(_busy ? 'Connecting…' : 'Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
