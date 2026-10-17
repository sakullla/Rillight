import '../app/tv_widgets.dart';
import '../app/presentation_environment.dart';

import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/l10n/app_localizations.dart';
import '../media_server/authentication.dart';
import '../media_server/capabilities.dart';
import '../media_server/errors.dart';
import 'auth_controller.dart';
import 'login_widgets.dart';
import 'provider_connect_controller.dart';
import 'server_list_store.dart';
import 'server_paste_draft.dart';

import 'package:rillight/app/ui/app_icons.dart';

Future<void> showProviderAccountSettings(BuildContext context) {
  final l = AppLocalizations.of(context);
  final uri = Uri.parse('https://app.plex.tv/desktop/#!/settings/account');
  return showAppDialog<void>(
    context: context,
    builder: (dialog) => AppDialog(
      title: Text(l.providerAccountManage),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.providerAccountInstructions),
          AppSelectableText(uri.toString()),
        ],
      ),
      actions: [
        AppButton(
          onPressed: () => Navigator.pop(dialog),
          variant: AppButtonVariant.plain,
          child: Text(l.cancelAction),
        ),
        AppButton(
          onPressed: () async {
            try {
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
                  context.mounted) {
                showAppNotice(context, l.providerBrowserFailure);
              }
            } catch (_) {
              if (context.mounted) {
                showAppNotice(context, l.providerBrowserFailure);
              }
            }
          },
          variant: AppButtonVariant.filled,
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
    return await showAppDialog<bool>(
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
    this.initialDraft,
    this.showTypePicker = false,
  });
  final AuthController auth;
  final SavedServer? existing;
  final AccessRegion region;
  final bool home;
  final String? initialUserAgent;
  final MediaServerType? initialType;
  final bool inline;
  final VoidCallback? onConnected;
  final ServerPasteDraft? initialDraft;
  final bool showTypePicker;
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
  final displayName = TextEditingController(),
      extraLines = TextEditingController();
  HomeUser? homeUser;
  bool _passwordVisible = false;
  bool _completionScheduled = false;
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
    controller.addListener(_completeWhenDone);
    if (widget.initialType != null && widget.existing == null) {
      controller.type = widget.initialType!;
    }
    if (widget.inline) {
      _releasePresentation = widget.auth.retainAuthorizationPresentation();
    }
    address.text = widget.existing?.baseUrl ?? '';
    username.text = widget.existing?.username ?? '';
    userAgent.text = controller.userAgent;
    final draft = widget.initialDraft;
    if (draft != null) {
      controller.type = draft.serviceType;
      displayName.text = draft.name;
      address.text = draft.lines.firstOrNull ?? '';
      extraLines.text = draft.lines.skip(1).join('\n');
      username.text = draft.username;
      password.text = draft.password;
    }
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
    controller.removeListener(_completeWhenDone);
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
    displayName.dispose();
    extraLines.dispose();
    super.dispose();
  }

  void _completeWhenDone() {
    if (!mounted ||
        _completionScheduled ||
        controller.busy ||
        controller.stage != ProviderConnectStage.done) {
      return;
    }
    _completionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && controller.stage == ProviderConnectStage.done) _finish();
    });
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
          leading: icon == null ? null : Icon(icon, fill: AppIcons.filled),
        ),
      );
    }
    final obscured = secret && !_passwordVisible;
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppTextField(
        key: Key(id),
        controller: value,
        obscureText: obscured,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: !secret,
        autofillHints: autofillHints,
        textInputAction: action,
        onSubmitted: onSubmitted,
        label: label,
        placeholder: hint,
        prefix: icon == null
            ? null
            : Icon(icon, fill: AppIcons.filled, size: 20),
        suffix: secret && keyboardType != TextInputType.number
            ? AppIconButton(
                key: Key('$id-visibility'),
                tooltip: _passwordVisible ? l.hidePassword : l.showPassword,
                onPressed: () =>
                    setState(() => _passwordVisible = !_passwordVisible),
                icon: Icon(
                  AppIcons.visibility,
                  fill: _passwordVisible ? AppIcons.filled : AppIcons.outline,
                  size: 20,
                ),
              )
            : null,
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
        leading: icon == null ? null : Icon(icon, fill: AppIcons.filled),
        onPressed: onPressed,
        child: Center(child: Text(busy ? l.connecting : label)),
      );
    }
    final child = BusyLabel(busy: busy, label: label, busyLabel: l.connecting);
    final style = AppButtonStyle(minimumSize: const Size(48, 48));
    return icon == null || busy
        ? AppButton(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            variant: AppButtonVariant.filled,
            child: child,
          )
        : AppButton.icon(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, fill: AppIcons.filled, size: 20),
            label: child,
            variant: AppButtonVariant.filled,
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
        leading: icon == null ? null : Icon(icon, fill: AppIcons.filled),
        onPressed: onPressed,
        child: Center(child: Text(label)),
      );
    }
    final scheme = AppUiTheme.of(context).colorScheme;
    final style = AppButtonStyle(
      minimumSize: const Size(48, 48),
      backgroundColor: scheme.surfaceContainerHighest,
      foregroundColor: scheme.onSurface,
    );
    return icon == null
        ? AppButton(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            variant: AppButtonVariant.tinted,
            child: Text(label),
          )
        : AppButton.icon(
            key: Key(id),
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, fill: AppIcons.filled, size: 20),
            label: Text(label),
            variant: AppButtonVariant.tinted,
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
        leading: icon == null ? null : Icon(icon, fill: AppIcons.filled),
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return icon == null
        ? AppButton(
            key: key,
            onPressed: onPressed,
            variant: AppButtonVariant.plain,
            child: Text(label),
          )
        : AppButton.icon(
            key: key,
            onPressed: onPressed,
            icon: Icon(icon, fill: AppIcons.filled, size: 18),
            label: Text(label),
            variant: AppButtonVariant.plain,
          );
  }

  Future<void> _openUri(Uri uri) async {
    final l = AppLocalizations.of(context);
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        showAppNotice(context, l.providerBrowserFailure);
      }
    } catch (_) {
      if (mounted) {
        showAppNotice(context, l.providerBrowserFailure);
      }
    }
  }

  Widget _sectionLabel(String text) {
    final theme = AppUiTheme.of(context);
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final userAgentInput = _input(
      'provider-user-agent',
      userAgent,
      _tv ? l.tvUserAgentOptional : l.userAgent,
      icon: AppIcons.badge,
      hint: _tv ? null : l.userAgentHint,
    );
    final advanced = _tv
        ? userAgentInput
        : LoginAdvancedSection(
            toggleKey: const Key('provider-advanced'),
            initiallyExpanded: false,
            children: [userAgentInput],
          );
    void prepareDraft() {
      c.displayName = displayName.text.trim().isEmpty
          ? null
          : displayName.text.trim();
      c.extraLines
        ..clear()
        ..addAll(
          [
                // Plex authorization discovers the primary connection. Every
                // pasted endpoint must still join the same identity transaction.
                if (c.type == MediaServerType.plex) address.text,
                extraLines.text,
              ]
              .join('\n')
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty),
        );
    }

    void submit() {
      prepareDraft();
      c.password(address.text, username.text, password.text);
    }

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
        if (widget.existing == null && !_tv)
          _input(
            'provider-display-name',
            displayName,
            l.serversPasteName,
            action: TextInputAction.next,
          ),
        if (widget.initialDraft != null) ...[
          _input(
            'provider-address',
            address,
            l.serverAddress,
            keyboardType: TextInputType.url,
            icon: AppIcons.link,
            action: TextInputAction.next,
          ),
          AppTextField(
            key: const Key('provider-extra-lines'),
            controller: extraLines,
            label: l.serversPasteExtra,
            minLines: 2,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
          ),
          SizedBox(height: 16 * s),
        ],
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
          c.busy
              ? null
              : () {
                  prepareDraft();
                  c.authorize(address.text);
                },
          icon: AppIcons.openInNew,
          busy: c.busy,
        ),
        SizedBox(height: 8 * s),
        advanced,
      ];
    }
    return [
      if (widget.existing == null && !_tv)
        _input(
          'provider-display-name',
          displayName,
          l.serversPasteName,
          action: TextInputAction.next,
        ),
      AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _input(
              'provider-address',
              address,
              l.serverAddress,
              keyboardType: TextInputType.url,
              icon: AppIcons.link,
              hint: l.serverAddressHint,
              action: TextInputAction.next,
              autofillHints: const [AutofillHints.url],
            ),
            _input(
              'provider-username',
              username,
              l.username,
              icon: AppIcons.person,
              action: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
            ),
            _input(
              'provider-password',
              password,
              l.password,
              secret: true,
              icon: AppIcons.lock,
              action: TextInputAction.done,
              onSubmitted: c.busy ? null : (_) => submit(),
              autofillHints: const [AutofillHints.password],
            ),
          ],
        ),
      ),
      if (widget.initialDraft != null) ...[
        const SizedBox(height: 12),
        AppTextField(
          key: const Key('provider-extra-lines'),
          controller: extraLines,
          label: l.serversPasteExtra,
          minLines: 2,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
        ),
      ],
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
          c.busy
              ? null
              : () {
                  prepareDraft();
                  c.authorize(address.text);
                },
          icon: AppIcons.bolt,
        ),
      ],
      if (!_tv) ...[const SizedBox(height: 8), advanced],
    ];
  }

  List<Widget> _authorization(AppLocalizations l, ProviderConnectController c) {
    final theme = AppUiTheme.of(context);
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
                  AppSelectableText(
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
              AppIconButton(
                key: const Key('provider-copy-code'),
                tooltip: l.providerCopyCode,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (!mounted) return;
                  showAppNotice(context, l.providerCodeCopied);
                },
                icon: const Icon(
                  AppIcons.copy,
                  fill: AppIcons.filled,
                  size: 20,
                ),
              ),
          ],
        ),
      ),
      if (c.attempt!.verificationUri case final uri?) ...[
        SizedBox(height: 12 * s),
        AppSelectableText(
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
          icon: AppIcons.openInNew,
        ),
      ],
      SizedBox(height: 14 * s),
      Row(
        children: [
          if (expired)
            Icon(
              AppIcons.error,
              fill: AppIcons.filled,
              size: 18 * s,
              color: scheme.error,
            )
          else
            SizedBox.square(
              dimension: 16 * s,
              child: CupertinoActivityIndicator(),
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
            icon: AppIcons.refresh,
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
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final s = _tv ? TvDesign.scaleOf(context) : 1.0;
    final visible = [
      for (final resource in resources)
        if (widget.existing == null ||
            resource.server.id == widget.existing!.verifiedServerId)
          resource,
    ];
    IconData kindIcon(ServerConnectionKind kind) => switch (kind) {
      ServerConnectionKind.local => AppIcons.lan,
      ServerConnectionKind.remote => AppIcons.globe,
      ServerConnectionKind.relay => AppIcons.swap,
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
          Icon(kindIcon(connection.kind), fill: AppIcons.filled, size: 18 * s),
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
          Icon(AppIcons.chevronRight, fill: AppIcons.filled, size: 20 * s),
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
        child: AppButton(
          key: key,
          style: AppButtonStyle(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            foregroundColor: scheme.onSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          onPressed: onPressed,
          variant: AppButtonVariant.outlined,
          child: label,
        ),
      );
    }

    return [
      if (c.users.isNotEmpty) ...[
        _sectionLabel(l.providerChooseHome),
        AppDropdown<HomeUser>(
          key: const Key('provider-home-user'),
          value: homeUser,
          items: [
            for (final user in c.users)
              AppMenuEntry(
                value: user,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(user.name, overflow: TextOverflow.ellipsis),
                    ),
                    if (user.requiresPin)
                      Icon(
                        AppIcons.lock,
                        fill: AppIcons.filled,
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
            icon: AppIcons.tag,
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
            icon: AppIcons.group,
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
    final theme = AppUiTheme.of(context);
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
              color: const Color(0xff34c759).withValues(alpha: .18),
            ),
            child: Icon(
              AppIcons.check,
              fill: AppIcons.filled,
              size: 20 * s,
              color: const Color(0xff66bb6a),
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
                AppIcons.checkbox,
                fill: c.selectedLibraries.contains(library.key)
                    ? AppIcons.filled
                    : AppIcons.outline,
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
                AppSwitchTile(
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
          icon: AppIcons.refresh,
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
                          child: const AppLoadingBar(minHeight: 3),
                        ),
                      ),
                    if ((!widget.inline || widget.showTypePicker) &&
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
                    : AppButton(
                        key: const Key('provider-cancel'),
                        onPressed: () => Navigator.pop(context, false),
                        variant: AppButtonVariant.plain,
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
                    : AppButton.icon(
                        key: const Key('provider-finish'),
                        onPressed: c.busy ? null : _finish,
                        icon: const Icon(
                          AppIcons.check,
                          fill: AppIcons.filled,
                          size: 18,
                        ),
                        label: Text(l.providerFinish),
                        variant: AppButtonVariant.filled,
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
      : AppDialog(
          maxWidth: 528,
          insetPadding: insetPadding,
          title: Row(
            children: [
              Icon(
                AppIcons.library,
                fill: AppIcons.filled,
                size: 22,
                color: AppUiTheme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(child: title),
            ],
          ),
          content: content,
          actions: actions,
        );
}
