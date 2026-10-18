import 'package:flutter/widgets.dart';

import '../app/l10n/app_localizations.dart';
import '../app/ui/app_icons.dart';
import '../app/ui/ui.dart';
import '../media_server/capabilities.dart';
import 'login_widgets.dart';
import 'server_list_store.dart';

/// Shared visual language for the server hub, line picker and editor.
///
/// The server experience is a control surface, not a settings form: identity
/// marks, connection state and the current line must read at a glance, while
/// destructive or rare actions stay one level down.
abstract final class ServerUi {
  static const double panelWidth = 680;
  static const double panelHeight = 820;
  static const double panelRadius = 28;
  static const double cardRadius = 18;

  static Color accentOf(MediaServerType type) => switch (type) {
    MediaServerType.emby => const Color(0xFF52B54B),
    MediaServerType.jellyfin => const Color(0xFF8862E0),
    MediaServerType.plex => const Color(0xFFE5A00D),
  };

  static IconData? customIcon(String? iconId) => switch (iconId) {
    'home' => AppIcons.home,
    'cinema' => AppIcons.movie,
    'cloud' => AppIcons.globe,
    _ => null,
  };
}

enum ServerTone { neutral, current, success, warning, error }

Color serverToneColor(AppColorScheme colors, ServerTone tone) => switch (tone) {
  ServerTone.current => colors.primary,
  ServerTone.success => colors.tertiary,
  ServerTone.warning => colors.secondary,
  ServerTone.error => colors.error,
  ServerTone.neutral => colors.onSurfaceVariant,
};

/// Identity mark shared by the list, editor hero and TV rows.
///
/// Custom icons replace the provider logo but keep the provider-coloured tile,
/// so an icon change does not erase which service the entry belongs to.
class ServerIdentityBadge extends StatelessWidget {
  const ServerIdentityBadge({
    super.key,
    required this.type,
    this.iconId,
    this.size = 52,
    this.locked = false,
  });

  final MediaServerType type;
  final String? iconId;
  final double size;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    final accent = ServerUi.accentOf(type);
    final dark = colors.brightness == Brightness.dark;
    final custom = locked ? null : ServerUi.customIcon(iconId);
    return Semantics(
      label: locked ? AppLocalizations.of(context).serversLocked : type.label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * .3),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                accent.withValues(alpha: dark ? .34 : .20),
                colors.surfaceContainerHigh,
              ),
              Color.alphaBlend(
                accent.withValues(alpha: dark ? .14 : .07),
                colors.surfaceContainerLowest,
              ),
            ],
          ),
          border: Border.all(color: accent.withValues(alpha: .42)),
        ),
        child: Center(
          child: locked
              ? Icon(
                  AppIcons.lock,
                  size: size * .42,
                  color: colors.onSurfaceVariant,
                )
              : custom != null
              ? Icon(
                  custom,
                  size: size * .48,
                  color: colors.onSurface,
                  fill: AppIcons.filled,
                )
              : ServerTypeMark(type: type, size: size * .52),
        ),
      ),
    );
  }
}

class ServerStatusPill extends StatelessWidget {
  const ServerStatusPill({
    super.key,
    required this.label,
    this.tone = ServerTone.neutral,
    this.icon,
    this.busy = false,
  });

  final String label;
  final ServerTone tone;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final color = serverToneColor(colors, tone);
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: .28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              Icon(AppIcons.hourglass, size: 13, color: color)
            else if (icon != null)
              Icon(icon, size: 13, color: color)
            else
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ServerMetaText extends StatelessWidget {
  const ServerMetaText({
    super.key,
    required this.icon,
    required this.text,
    this.maxLines = 1,
  });

  final IconData icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    return Row(
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Raised section used by the server editor. Sections separate identity,
/// account, connections and protection without adding another page.
class ServerSectionCard extends StatelessWidget {
  const ServerSectionCard({
    super.key,
    required this.title,
    required this.children,
    this.icon,
    this.description,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final IconData? icon;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: dark ? colors.surfaceContainer : colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(ServerUi.cardRadius),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 17, color: colors.primary),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 6),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

/// Elevated identity block for a single server: mark, name and account.
class ServerIdentityCard extends StatelessWidget {
  const ServerIdentityCard({
    super.key,
    required this.server,
    this.trailing,
    this.subtitle,
  });

  final SavedServer server;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ServerUi.cardRadius),
        color: dark ? colors.surfaceContainer : colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          ServerIdentityBadge(
            type: server.serviceType,
            iconId: server.iconId,
            size: 48,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  server.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle ??
                      '${server.serviceType.label} · ${server.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}

/// Compact feedback surface. [action] keeps the next step next to the problem
/// instead of turning the whole list into an error page.
class ServerFeedbackCard extends StatelessWidget {
  const ServerFeedbackCard(
    this.message, {
    super.key,
    this.error = true,
    this.action,
  });

  final String message;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final color = error ? colors.error : colors.primary;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: .22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  error ? AppIcons.error : AppIcons.info,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurface,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            if (action != null)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: action,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
