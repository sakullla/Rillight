import '../app/tv_widgets.dart';
import '../app/presentation_environment.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/l10n/app_localizations.dart';
import '../media_server/authentication.dart';
import '../media_server/capabilities.dart';
import '../media_server/errors.dart';
import 'auth_controller.dart';
import 'provider_connect_controller.dart';
import 'server_list_store.dart';

Future<void> showProviderAccountSettings(BuildContext context) {
  final l = AppLocalizations.of(context);
  final uri = Uri.parse('https://app.plex.tv/desktop/#!/settings/account');
  return showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l.providerAccountManage),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.providerAccountInstructions),
          SelectableText(uri.toString()),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(l.cancelAction),
        ),
        FilledButton(
          onPressed: () async {
            try {
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
                  context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(l.providerBrowserFailure)),
                );
              }
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(l.providerBrowserFailure)),
                );
              }
            }
          },
          child: Text(l.providerOpenBrowser),
        ),
      ],
    ),
  );
}

Future<bool?> showProviderConnect(
  BuildContext context,
  AuthController auth, {
  SavedServer? existing,
  AccessRegion region = AccessRegion.ordinary,
  bool home = false,
  String? userAgent,
}) async {
  final release = auth.retainAuthorizationPresentation();
  try {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProviderConnectDialog(
        auth: auth,
        existing: existing,
        region: region,
        home: home,
        initialUserAgent: userAgent,
      ),
    );
  } finally {
    release();
  }
}

class ProviderConnectDialog extends StatefulWidget {
  const ProviderConnectDialog({
    super.key,
    required this.auth,
    this.existing,
    this.region = AccessRegion.ordinary,
    this.home = false,
    this.initialUserAgent,
  });
  final AuthController auth;
  final SavedServer? existing;
  final AccessRegion region;
  final bool home;
  final String? initialUserAgent;
  @override
  State<ProviderConnectDialog> createState() => _ProviderConnectDialogState();
}

class _ProviderConnectDialogState extends State<ProviderConnectDialog> {
  late final ProviderConnectController controller;
  final address = TextEditingController(),
      username = TextEditingController(),
      userAgent = TextEditingController(),
      password = TextEditingController(),
      pin = TextEditingController();
  HomeUser? homeUser;
  @override
  void initState() {
    super.initState();
    controller = ProviderConnectController(
      auth: widget.auth,
      existing: widget.existing,
      region: widget.region,
      userAgent: widget.initialUserAgent,
    );
    address.text = widget.existing?.baseUrl ?? '';
    username.text = widget.existing?.username ?? '';
    userAgent.text = controller.userAgent;
    userAgent.addListener(() => controller.userAgent = userAgent.text);
    widget.auth.regionAccess.addListener(_accessChanged);
    if (widget.home) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(controller.restoreHome());
      });
    }
  }

  void _accessChanged() {
    if (!widget.auth.regionAccess.allows(widget.region)) {
      controller.reset();
      address.clear();
      username.clear();
      password.clear();
      pin.clear();
      userAgent.clear();
      if (mounted) {
        final route = ModalRoute.of(context);
        if (route?.isActive == true) {
          final navigator = Navigator.of(context);
          // TV input editors are nested routes. Close them with their owner so
          // locking cannot leave an editor displaying a private identity.
          navigator.popUntil((candidate) => identical(candidate, route));
          navigator.pop(false);
        }
      }
    }
  }

  @override
  void dispose() {
    widget.auth.regionAccess.removeListener(_accessChanged);
    controller.dispose();
    userAgent.dispose();
    address.dispose();
    username.dispose();
    password.dispose();
    pin.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await controller.finish();
    if (mounted && controller.stage == ProviderConnectStage.done) {
      Navigator.pop(context, true);
    }
  }

  String _failure(AppLocalizations l, MediaServerFailureKind kind) =>
      switch (kind) {
        MediaServerFailureKind.invalidCredentials =>
          l.providerCredentialsRejected,
        MediaServerFailureKind.forbidden => l.providerPermissionDenied,
        MediaServerFailureKind.rateLimited => l.providerRateLimited,
        MediaServerFailureKind.authorizationExpired ||
        MediaServerFailureKind.sessionExpired => l.providerAuthorizationExpired,
        MediaServerFailureKind.signatureRejected ||
        MediaServerFailureKind.clockSkew => l.providerSignatureFailure,
        MediaServerFailureKind.unsupported => l.providerQuickUnavailable,
        MediaServerFailureKind.certificate => l.providerCertificateFailure,
        _ => l.providerConnectionFailure,
      };

  Widget _input(
    String id,
    TextEditingController value,
    String label, {
    bool secret = false,
    TextInputType? keyboardType,
  }) {
    if (PresentationScope.maybeOf(context)?.isTv == true) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TvInput(
          key: Key(id),
          label: label,
          controller: value,
          secret: secret,
          keyboardType: keyboardType,
        ),
      );
    }
    return TextField(
      key: Key(id),
      controller: value,
      obscureText: secret,
      keyboardType: keyboardType,
      decoration: InputDecoration(labelText: label),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context), c = controller;
      // A dropdown selection is only a pending identity. Resources must match
      // the Home identity that actually authorized them before being offered.
      final resources = c.resources.where(
        (resource) => homeUser == null || resource.homeUserId == homeUser!.id,
      );
      return Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: FocusTraversalGroup(
          child: AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 20,
            ),
            title: Text(l.providerConnectTitle),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (c.busy) const LinearProgressIndicator(),
                    if (c.failure != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _failure(l, c.failure!),
                          key: const Key('provider-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (c.stage == ProviderConnectStage.credentials) ...[
                      DropdownButtonFormField<MediaServerType>(
                        key: const Key('provider-type'),
                        initialValue: c.type,
                        decoration: InputDecoration(
                          labelText: l.providerServiceType,
                        ),
                        items: [
                          for (final type in MediaServerType.values)
                            DropdownMenuItem(
                              value: type,
                              child: Text(switch (type) {
                                MediaServerType.emby => 'Emby',
                                MediaServerType.jellyfin => 'Jellyfin',
                                MediaServerType.plex => 'Plex',
                              }),
                            ),
                        ],
                        onChanged: c.busy || widget.existing != null
                            ? null
                            : (type) {
                                if (type != null) {
                                  password.clear();
                                  pin.clear();
                                  c.reset(type);
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      if (c.type != MediaServerType.plex) ...[
                        _input(
                          'provider-address',
                          address,
                          l.serverAddress,
                          keyboardType: TextInputType.url,
                        ),
                        _input('provider-username', username, l.username),
                        _input(
                          'provider-password',
                          password,
                          l.password,
                          secret: true,
                        ),
                      ],
                      _input('provider-user-agent', userAgent, l.userAgent),
                      const SizedBox(height: 12),
                      if (c.type != MediaServerType.plex)
                        FilledButton(
                          key: const Key('provider-password-submit'),
                          onPressed: c.busy
                              ? null
                              : () => c.password(
                                  address.text,
                                  username.text,
                                  password.text,
                                ),
                          child: Text(l.connect),
                        ),
                      if (c.type != MediaServerType.emby)
                        OutlinedButton(
                          key: const Key('provider-authorize'),
                          onPressed: c.busy
                              ? null
                              : () => c.authorize(address.text),
                          child: Text(
                            c.type == MediaServerType.plex
                                ? l.providerPlexAuthorize
                                : l.providerQuickConnect,
                          ),
                        ),
                    ],
                    if (c.stage == ProviderConnectStage.authorization) ...[
                      Text(
                        c.type == MediaServerType.plex
                            ? l.providerPlexInstructions
                            : l.providerQuickInstructions,
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        c.attempt!.code,
                        key: const Key('provider-authorization-code'),
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      if (c.attempt!.verificationUri case final uri?) ...[
                        SelectableText(uri.toString()),
                        TextButton(
                          onPressed: () async {
                            try {
                              final opened = await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                              if (!opened && context.mounted) {
                                ScaffoldMessenger.maybeOf(
                                  context,
                                )?.showSnackBar(
                                  SnackBar(
                                    content: Text(l.providerBrowserFailure),
                                  ),
                                );
                              }
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.maybeOf(
                                  context,
                                )?.showSnackBar(
                                  SnackBar(
                                    content: Text(l.providerBrowserFailure),
                                  ),
                                );
                              }
                            }
                          },
                          child: Text(l.providerOpenBrowser),
                        ),
                      ],
                      Text(
                        c.authorizationStatus == AuthorizationStatus.pending
                            ? l.providerWaitingAuthorization
                            : c.authorizationStatus ==
                                  AuthorizationStatus.authorized
                            ? l.providerDiscovering
                            : l.providerAuthorizationExpired,
                      ),
                      TextButton(
                        onPressed: () => c.reset(),
                        child: Text(l.providerRestart),
                      ),
                    ],
                    if (c.stage == ProviderConnectStage.resources) ...[
                      Text(l.providerChooseHome),
                      if (c.users.isNotEmpty)
                        DropdownButtonFormField<HomeUser>(
                          key: const Key('provider-home-user'),
                          initialValue: homeUser,
                          isExpanded: true,
                          items: [
                            for (final user in c.users)
                              DropdownMenuItem(
                                value: user,
                                child: Text(
                                  user.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: c.busy
                              ? null
                              : (user) => setState(() {
                                  homeUser = user;
                                  pin.clear();
                                }),
                        ),
                      if (homeUser?.requiresPin == true) ...[
                        _input(
                          'provider-home-pin',
                          pin,
                          l.providerHomePin,
                          secret: true,
                          keyboardType: TextInputType.number,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 8),
                          child: Text(
                            l.providerHomePinHint,
                            key: const Key('provider-home-pin-hint'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                      if (homeUser != null)
                        FilledButton(
                          key: const Key('provider-home-switch'),
                          onPressed: c.busy
                              ? null
                              : () => c.selectHome(homeUser!, pin.text),
                          child: Text(l.providerSwitchHome),
                        ),
                      const SizedBox(height: 12),
                      Text(l.providerChooseResource),
                      if (resources.isEmpty && !c.busy)
                        Text(l.providerNoResources),
                      for (final resource in resources)
                        if (widget.existing == null ||
                            resource.server.id ==
                                widget.existing!.verifiedServerId) ...[
                          Text(
                            '${resource.server.serverName} · ${resource.user.name}${resource.owned == null ? '' : ' · ${resource.owned! ? l.providerOwned : l.providerShared}'}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          for (final connection in resource.connections)
                            OutlinedButton(
                              key: ValueKey(
                                'provider-resource-${resource.server.id}-${connection.uri}',
                              ),
                              onPressed: c.busy
                                  ? null
                                  : () =>
                                        c.selectResource(resource, connection),
                              child: Text(
                                '${switch (connection.kind) {
                                  ServerConnectionKind.local => l.providerLocal,
                                  ServerConnectionKind.remote => l.providerRemote,
                                  ServerConnectionKind.relay => l.providerRelay,
                                }} · ${connection.uri}',
                              ),
                            ),
                        ],
                    ],
                    if (c.stage == ProviderConnectStage.libraries) ...[
                      Text(l.providerChooseLibraries),
                      for (final library in c.libraries.entries)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(library.value),
                          value: c.selectedLibraries.contains(library.key),
                          onChanged: c.busy
                              ? null
                              : (selected) => setState(() {
                                  selected == true
                                      ? c.selectedLibraries.add(library.key)
                                      : c.selectedLibraries.remove(library.key);
                                }),
                        ),
                      if (c.libraries.isEmpty && !c.busy)
                        Text(l.providerNoLibraries),
                      TextButton(
                        onPressed: c.busy ? null : c.retryLibraries,
                        child: Text(l.sourceDiscoverLibraries),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                key: const Key('provider-cancel'),
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.cancelAction),
              ),
              if (c.stage == ProviderConnectStage.libraries)
                FilledButton(
                  key: const Key('provider-finish'),
                  onPressed: c.busy ? null : _finish,
                  child: Text(l.providerFinish),
                ),
            ],
          ),
        ),
      );
    },
  );
}
