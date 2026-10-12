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
import '../app/theme/tokens.dart';
import 'auth_controller.dart';
import 'login_widgets.dart';
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
    this.initialType,
    this.inline = false,
    this.onConnected,
  });
  final AuthController auth;
  final SavedServer? existing;
  final AccessRegion region;
  final bool home;
  final String? initialUserAgent;
  final MediaServerType? initialType;
  final bool inline;
  final VoidCallback? onConnected;
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
  bool _passwordVisible = false;
  VoidCallback? _releasePresentation;
  @override
  void initState() {
    super.initState();
    controller = ProviderConnectController(
      auth: widget.auth,
      existing: widget.existing,
      region: widget.region,
      userAgent: widget.initialUserAgent,
    );
    if (widget.initialType != null && widget.existing == null) {
      controller.type = widget.initialType!;
    }
    if (widget.inline) {
      _releasePresentation = widget.auth.retainAuthorizationPresentation();
    }
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
        if (!widget.inline && route?.isActive == true) {
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
    final release = _releasePresentation;
    if (release != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    }
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
      if (widget.inline) {
        widget.onConnected?.call();
      } else {
        Navigator.pop(context, true);
      }
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

  bool get _tv => PresentationScope.maybeOf(context)?.isTv == true;

  Widget _input(
    String id,
    TextEditingController value,
    String label, {
    bool secret = false,
    TextInputType? keyboardType,
    IconData? icon,
    String? hint,
    TextInputAction? action,
    ValueChanged<String>? onSubmitted,
    Iterable<String>? autofillHints,
  }) {
    if (_tv) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TvInput(
          key: Key(id),
          label: label,
          controller: value,
          secret: secret,
          keyboardType: keyboardType,
          placeholder: hint,
          leading: icon == null ? null : Icon(icon),
        ),
      );
    }
    final obscured = secret && !_passwordVisible;
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        key: Key(id),
        controller: value,
        obscureText: obscured,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: !secret,
        autofillHints: autofillHints,
        textInputAction: action,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          suffixIcon: secret && keyboardType != TextInputType.number
              ? IconButton(
                  key: Key('$id-visibility'),
                  tooltip: _passwordVisible ? l.hidePassword : l.showPassword,
                  onPressed: () =>
                      setState(() => _passwordVisible = !_passwordVisible),
                  icon: Icon(
                    _passwordVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                )
              : null,
        ),
      ),
    );
  }

  /// 主操作:桌面/手机为实心按钮,TV 为强调的遥控器按钮。
  Widget _primary(
    String id,
    String label,
    VoidCallback? onPressed, {
    IconData? icon,
    bool busy = false,
  }) {
    final l = AppLocalizations.of(context);
    if (_tv) {
      return TvAction(
        key: Key(id),
        emphasized: true,
        expand: true,
        leading: icon == null ? null : Icon(icon),
        onPressed: onPressed,
        child: Center(child: Text(busy ? l.connecting : label)),
      );
    }
    final child = BusyLabel(busy: busy, label: label, busyLabel: l.connecting);
    final style = FilledButton.styleFrom(minimumSize: const Size(48, 48));
    return icon == null || busy
        ? FilledButton(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            child: child,
          )
        : FilledButton.icon(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            label: child,
          );
  }

  /// 次要操作:浅色实底,不使用描边按钮(描边按钮只留给线路选择)。
  Widget _secondary(
    String id,
    String label,
    VoidCallback? onPressed, {
    IconData? icon,
  }) {
    if (_tv) {
      return TvAction(
        key: Key(id),
        expand: true,
        leading: icon == null ? null : Icon(icon),
        onPressed: onPressed,
        child: Center(child: Text(label)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      backgroundColor: scheme.surfaceContainerHighest,
      foregroundColor: scheme.onSurface,
    );
    return icon == null
        ? FilledButton.tonal(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            child: Text(label),
          )
        : FilledButton.tonalIcon(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            label: Text(label),
          );
  }

  Widget _quiet(
    String label,
    VoidCallback? onPressed, {
    Key? key,
    IconData? icon,
  }) {
    if (_tv) {
      return TvAction(
        key: key,
        variant: TvActionVariant.ghost,
        leading: icon == null ? null : Icon(icon),
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return icon == null
        ? TextButton(key: key, onPressed: onPressed, child: Text(label))
        : TextButton.icon(
            key: key,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
  }

  Future<void> _openUri(Uri uri) async {
    final l = AppLocalizations.of(context);
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(l.providerBrowserFailure)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(l.providerBrowserFailure)));
      }
    }
  }

  Widget _sectionLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _typeSwitcher(ProviderConnectController c) {
    final onChanged = c.busy || widget.existing != null
        ? null
        : (MediaServerType type) {
            password.clear();
            pin.clear();
            c.reset(type);
          };
    if (_tv) {
      return KeyedSubtree(
        key: const Key('provider-type'),
        child: TvProviderSwitcher(
          value: c.type,
          keyPrefix: 'provider-type',
          onChanged: onChanged,
        ),
      );
    }
    return ProviderSwitcher(
      containerKey: const Key('provider-type'),
      keyPrefix: 'provider-type',
      value: c.type,
      onChanged: onChanged,
    );
  }

  List<Widget> _credentials(AppLocalizations l, ProviderConnectController c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final userAgentInput = _input(
      'provider-user-agent',
      userAgent,
      _tv ? l.tvUserAgentOptional : l.userAgent,
      icon: Icons.badge_outlined,
      hint: _tv ? null : l.userAgentHint,
    );
    final advanced = _tv
        ? userAgentInput
        : LoginAdvancedSection(
            toggleKey: const Key('provider-advanced'),
            initiallyExpanded: userAgent.text.trim().isNotEmpty,
            children: [userAgentInput],
          );
    void submit() => c.password(address.text, username.text, password.text);
    if (c.type == MediaServerType.plex) {
      final s = _tv ? TvDesign.scaleOf(context) : 1.0;
      Widget step(int index, String text) => Padding(
        padding: EdgeInsets.only(top: 8 * s),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22 * s,
              height: 22 * s,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MediaServerType.plex.brandColor.withValues(alpha: .18),
              ),
              child: Text(
                '$index',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: _tv ? null : scheme.onSurface,
                ),
              ),
            ),
            SizedBox(width: 10 * s),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 2 * s),
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      return [
        Container(
          padding: EdgeInsets.all(16 * s),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(14 * s),
            border: Border.all(
              color: MediaServerType.plex.brandColor.withValues(alpha: .28),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ServerTypeMark(type: MediaServerType.plex, size: 32 * s),
                  SizedBox(width: 12 * s),
                  Expanded(
                    child: Text(
                      l.loginPlexTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              // TV 上提示行已说明流程,省掉步骤让授权钮留在首屏。
              if (!_tv) ...[
                SizedBox(height: 4 * s),
                step(1, l.loginPlexStep1),
                step(2, l.loginPlexStep2),
                step(3, l.loginPlexStep3),
              ],
            ],
          ),
        ),
        SizedBox(height: 16 * s),
        _primary(
          'provider-authorize',
          l.providerPlexAuthorize,
          c.busy ? null : () => c.authorize(address.text),
          icon: Icons.open_in_new_rounded,
          busy: c.busy,
        ),
        SizedBox(height: 8 * s),
        advanced,
      ];
    }
    return [
      AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _input(
              'provider-address',
              address,
              l.serverAddress,
              keyboardType: TextInputType.url,
              icon: Icons.link_rounded,
              hint: l.serverAddressHint,
              action: TextInputAction.next,
              autofillHints: const [AutofillHints.url],
            ),
            _input(
              'provider-username',
              username,
              l.username,
              icon: Icons.person_outline_rounded,
              action: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
            ),
            _input(
              'provider-password',
              password,
              l.password,
              secret: true,
              icon: Icons.lock_outline_rounded,
              action: TextInputAction.done,
              onSubmitted: c.busy ? null : (_) => submit(),
              autofillHints: const [AutofillHints.password],
            ),
          ],
        ),
      ),
      if (_tv) userAgentInput,
      const SizedBox(height: 14),
      _primary(
        'provider-password-submit',
        l.connect,
        c.busy ? null : submit,
        busy: c.busy && c.stage == ProviderConnectStage.credentials,
      ),
      if (c.type == MediaServerType.jellyfin) ...[
        const SizedBox(height: 12),
        const LoginOrDivider(),
        const SizedBox(height: 12),
        _secondary(
          'provider-authorize',
          l.providerQuickConnect,
          c.busy ? null : () => c.authorize(address.text),
          icon: Icons.bolt_rounded,
        ),
      ],
      if (!_tv) ...[const SizedBox(height: 8), advanced],
    ];
  }

  List<Widget> _authorization(AppLocalizations l, ProviderConnectController c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _tv ? TvDesign.scaleOf(context) : 1.0;
    final status = c.authorizationStatus;
    final expired =
        status != AuthorizationStatus.pending &&
        status != AuthorizationStatus.authorized;
    final code = c.attempt!.code;
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ServerTypeMark(type: c.type, size: 32 * s),
          SizedBox(width: 12 * s),
          Expanded(
            child: Text(
              c.type == MediaServerType.plex
                  ? l.providerPlexInstructions
                  : l.providerQuickInstructions,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      SizedBox(height: 16 * s),
      Container(
        padding: EdgeInsets.fromLTRB(16 * s, 12 * s, 8 * s, 12 * s),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(color: c.type.brandColor.withValues(alpha: .4)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.providerAuthorizationCodeLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: 4 * s),
                  SelectableText(
                    code,
                    key: const Key('provider-authorization-code'),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4 * s,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (!_tv)
              IconButton(
                key: const Key('provider-copy-code'),
                tooltip: l.providerCopyCode,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (!mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text(l.providerCodeCopied)),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 20),
              ),
          ],
        ),
      ),
      if (c.attempt!.verificationUri case final uri?) ...[
        SizedBox(height: 12 * s),
        SelectableText(
          uri.toString(),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        SizedBox(height: 8 * s),
        _secondary(
          'provider-open-browser',
          l.providerOpenBrowser,
          () => unawaited(_openUri(uri)),
          icon: Icons.open_in_new_rounded,
        ),
      ],
      SizedBox(height: 14 * s),
      Row(
        children: [
          if (expired)
            Icon(Icons.error_outline_rounded, size: 18 * s, color: scheme.error)
          else
            SizedBox.square(
              dimension: 16 * s,
              child: CircularProgressIndicator(strokeWidth: 2 * s),
            ),
          SizedBox(width: 10 * s),
          Expanded(
            child: Text(
              status == AuthorizationStatus.pending
                  ? l.providerWaitingAuthorization
                  : status == AuthorizationStatus.authorized
                  ? l.providerDiscovering
                  : l.providerAuthorizationExpired,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: expired ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
          _quiet(
            l.providerRestart,
            () => c.reset(),
            key: const Key('provider-restart'),
            icon: Icons.refresh_rounded,
          ),
        ],
      ),
    ];
  }

  List<Widget> _resources(
    AppLocalizations l,
    ProviderConnectController c,
    Iterable<AuthorizedServerResource> resources,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _tv ? TvDesign.scaleOf(context) : 1.0;
    final visible = [
      for (final resource in resources)
        if (widget.existing == null ||
            resource.server.id == widget.existing!.verifiedServerId)
          resource,
    ];
    IconData kindIcon(ServerConnectionKind kind) => switch (kind) {
      ServerConnectionKind.local => Icons.lan_rounded,
      ServerConnectionKind.remote => Icons.public_rounded,
      ServerConnectionKind.relay => Icons.sync_alt_rounded,
    };
    String kindLabel(ServerConnectionKind kind) => switch (kind) {
      ServerConnectionKind.local => l.providerLocal,
      ServerConnectionKind.remote => l.providerRemote,
      ServerConnectionKind.relay => l.providerRelay,
    };
    Widget connectionButton(
      AuthorizedServerResource resource,
      ServerConnection connection,
    ) {
      final key = ValueKey(
        'provider-resource-${resource.server.id}-${connection.uri}',
      );
      final onPressed = c.busy
          ? null
          : () => c.selectResource(resource, connection);
      final label = Row(
        children: [
          Icon(kindIcon(connection.kind), size: 18 * s),
          SizedBox(width: 10 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kindLabel(connection.kind),
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  connection.uri.toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _tv ? null : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20 * s),
        ],
      );
      if (_tv) {
        return Padding(
          padding: EdgeInsets.only(top: 6 * s),
          child: TvAction(
            key: key,
            variant: TvActionVariant.tile,
            onPressed: onPressed,
            child: label,
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton(
          key: key,
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            foregroundColor: scheme.onSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          onPressed: onPressed,
          child: label,
        ),
      );
    }

    return [
      if (c.users.isNotEmpty) ...[
        _sectionLabel(l.providerChooseHome),
        DropdownButtonFormField<HomeUser>(
          key: const Key('provider-home-user'),
          initialValue: homeUser,
          isExpanded: true,
          decoration: InputDecoration(
            hintText: l.providerHomeManage,
            prefixIcon: const Icon(Icons.people_outline_rounded, size: 20),
          ),
          items: [
            for (final user in c.users)
              DropdownMenuItem(
                value: user,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(user.name, overflow: TextOverflow.ellipsis),
                    ),
                    if (user.requiresPin)
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
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
          const SizedBox(height: 4),
          _input(
            'provider-home-pin',
            pin,
            l.providerHomePin,
            secret: true,
            keyboardType: TextInputType.number,
            icon: Icons.pin_outlined,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Text(
              l.providerHomePinHint,
              key: const Key('provider-home-pin-hint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        if (homeUser != null) ...[
          const SizedBox(height: 8),
          _secondary(
            'provider-home-switch',
            l.providerSwitchHome,
            c.busy ? null : () => c.selectHome(homeUser!, pin.text),
            icon: Icons.switch_account_outlined,
          ),
        ],
        const SizedBox(height: 18),
      ],
      _sectionLabel(l.providerChooseResource),
      if (visible.isEmpty && !c.busy)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            l.providerNoResources,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      for (final resource in visible)
        Container(
          margin: EdgeInsets.only(bottom: 10 * s),
          padding: EdgeInsets.all(12 * s),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(14 * s),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .6),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ServerTypeMark(type: c.type, size: 24 * s),
                  SizedBox(width: 10 * s),
                  Expanded(
                    child: Text(
                      '${resource.server.serverName} · ${resource.user.name}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (resource.owned != null)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 8 * s,
                        vertical: 2 * s,
                      ),
                      decoration: BoxDecoration(
                        color:
                            (resource.owned!
                                    ? c.type.brandColor
                                    : scheme.secondary)
                                .withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        resource.owned! ? l.providerOwned : l.providerShared,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              for (final connection in resource.connections)
                connectionButton(resource, connection),
            ],
          ),
        ),
    ];
  }

  List<Widget> _libraries(AppLocalizations l, ProviderConnectController c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _tv ? TvDesign.scaleOf(context) : 1.0;
    final all =
        c.libraries.isNotEmpty &&
        c.libraries.keys.every(c.selectedLibraries.contains);
    void toggle(String id, bool selected) => setState(() {
      selected ? c.selectedLibraries.add(id) : c.selectedLibraries.remove(id);
    });
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32 * s,
            height: 32 * s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.green.withValues(alpha: .18),
            ),
            child: Icon(
              Icons.check_rounded,
              size: 20 * s,
              color: Colors.green.shade400,
            ),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Text(
              l.providerChooseLibraries,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      SizedBox(height: 12 * s),
      if (c.libraries.isNotEmpty)
        Row(
          children: [
            Expanded(
              child: Text(
                '${c.selectedLibraries.length}/${c.libraries.length}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            _quiet(
              all ? l.providerSelectNone : l.providerSelectAll,
              c.busy
                  ? null
                  : () => setState(() {
                      if (all) {
                        c.selectedLibraries.clear();
                      } else {
                        c.selectedLibraries.addAll(c.libraries.keys);
                      }
                    }),
              key: const Key('provider-libraries-all'),
            ),
          ],
        ),
      if (_tv)
        for (final library in c.libraries.entries)
          Padding(
            padding: EdgeInsets.only(top: 6 * s),
            child: TvAction(
              variant: TvActionVariant.tile,
              selected: c.selectedLibraries.contains(library.key),
              onPressed: c.busy
                  ? null
                  : () => toggle(
                      library.key,
                      !c.selectedLibraries.contains(library.key),
                    ),
              leading: Icon(
                c.selectedLibraries.contains(library.key)
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
              ),
              child: Text(library.value),
            ),
          )
      else if (c.libraries.isNotEmpty)
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .7),
            ),
          ),
          child: Column(
            children: [
              for (final library in c.libraries.entries)
                CheckboxListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  secondary: Icon(
                    Icons.video_library_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  title: Text(library.value),
                  value: c.selectedLibraries.contains(library.key),
                  onChanged: c.busy
                      ? null
                      : (selected) => toggle(library.key, selected == true),
                ),
            ],
          ),
        ),
      if (c.libraries.isEmpty && !c.busy)
        Text(
          l.providerNoLibraries,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: _quiet(
          l.sourceDiscoverLibraries,
          c.busy ? null : c.retryLibraries,
          icon: Icons.refresh_rounded,
        ),
      ),
    ];
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
      final s = _tv ? TvDesign.scaleOf(context) : 1.0;
      return Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: FocusTraversalGroup(
          child: _ProviderPresentation(
            inline: widget.inline,
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
                    if (c.busy)
                      Padding(
                        padding: EdgeInsets.only(bottom: 12 * s),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: const LinearProgressIndicator(minHeight: 3),
                        ),
                      ),
                    if (!widget.inline &&
                        c.stage == ProviderConnectStage.credentials) ...[
                      _typeSwitcher(c),
                      SizedBox(height: 10 * s),
                      ProviderHint(type: c.type),
                      SizedBox(height: 14 * s),
                    ],
                    if (c.failure != null)
                      Padding(
                        padding: EdgeInsets.only(bottom: 12 * s),
                        child: LoginErrorBanner(
                          message: _failure(l, c.failure!),
                          textKey: const Key('provider-error'),
                        ),
                      ),
                    if (c.stage == ProviderConnectStage.credentials)
                      ..._credentials(l, c),
                    if (c.stage == ProviderConnectStage.authorization)
                      ..._authorization(l, c),
                    if (c.stage == ProviderConnectStage.resources)
                      ..._resources(l, c, resources),
                    if (c.stage == ProviderConnectStage.libraries)
                      ..._libraries(l, c),
                  ],
                ),
              ),
            ),
            actions: [
              if (!widget.inline)
                _tv
                    ? TvAction(
                        key: const Key('provider-cancel'),
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(l.cancelAction),
                      )
                    : TextButton(
                        key: const Key('provider-cancel'),
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(l.cancelAction),
                      ),
              if (c.stage == ProviderConnectStage.libraries)
                _tv
                    ? TvAction(
                        key: const Key('provider-finish'),
                        emphasized: true,
                        onPressed: c.busy ? null : _finish,
                        child: Text(l.providerFinish),
                      )
                    : FilledButton.icon(
                        key: const Key('provider-finish'),
                        onPressed: c.busy ? null : _finish,
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: Text(l.providerFinish),
                      ),
            ],
          ),
        ),
      );
    },
  );
}

class _ProviderPresentation extends StatelessWidget {
  const _ProviderPresentation({
    required this.inline,
    required this.insetPadding,
    required this.title,
    required this.content,
    required this.actions,
  });
  final bool inline;
  final EdgeInsets insetPadding;
  final Widget title, content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => inline
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            content,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    actions[i],
                  ],
                ],
              ),
            ],
          ],
        )
      : AlertDialog(
          insetPadding: insetPadding,
          title: Row(
            children: [
              Icon(
                Icons.dns_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(child: title),
            ],
          ),
          content: content,
          actions: actions,
        );
}
