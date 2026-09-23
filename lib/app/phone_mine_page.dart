import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';

/// 手机「我的」：线路、添加服务器、倍速和退出。
class PhoneMinePage extends StatefulWidget {
  const PhoneMinePage({super.key});

  @override
  State<PhoneMinePage> createState() => _PhoneMinePageState();
}

class _PhoneMinePageState extends State<PhoneMinePage> {
  PlayerSettingsStore? _store;
  double _rate = 1;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) {
      return;
    }
    _loaded = true;
    unawaited(() async {
      _store =
          PlayerScope.of(context).settingsStore ??
          await openPlayerSettingsStore();
      final settings = await _store!.read();
      if (mounted) {
        setState(() => _rate = settings.playbackRate ?? 1);
      }
    }());
  }

  Future<void> _lines() async {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .65,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              l10n.mobileLine,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final server in auth.savedServers) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('${server.name} · ${server.username}'),
              ),
              for (final line in server.lines)
                ListTile(
                  title: Text(line.hostLabel),
                  selected:
                      auth.session?.server.id == server.id &&
                      auth.session?.server.activeLine?.id == line.id,
                  onTap: () async {
                    Navigator.pop(context);
                    await auth.switchTo(server.id, lineId: line.id);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ListView(
      key: const PageStorageKey('mobile-mine-scroll'),
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          auth.session?.username ?? '',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(auth.session?.server.name ?? ''),
        const SizedBox(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns_outlined),
          title: Text(l10n.mobileLine),
          onTap: _lines,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.add),
          title: Text(l10n.mobileAddServer),
          onTap: () => context.push('${AppRoutes.connect}?add=1'),
        ),
        const Divider(),
        Text(l10n.mobileSpeed),
        Wrap(
          spacing: 8,
          children: [
            for (final rate in [.5, 1.0, 1.25, 1.5, 2.0])
              ChoiceChip(
                label: Text('${rate}x'),
                selected: _rate == rate,
                onSelected: (_) async {
                  await _store?.write(PlayerSettings(playbackRate: rate));
                  if (mounted) {
                    setState(() => _rate = rate);
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(AppSpacing.huge, AppSpacing.huge),
          ),
          onPressed: auth.isBusy ? null : auth.logout,
          child: Text(l10n.logout),
        ),
      ],
    );
  }
}
