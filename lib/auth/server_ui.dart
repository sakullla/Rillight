import 'dart:ui' show ImageFilter;

import '../app/l10n/app_localizations.dart';
import '../app/ui/app_icons.dart';
import '../app/ui/ui.dart';
import '../media_server/capabilities.dart';
import 'auth_scope.dart';
import 'login_widgets.dart';
import 'server_list_store.dart';

/// Shared visual language for the server hub, line picker and editor.
///
/// The server experience is a control surface, not a settings form: every
/// server owns a recognisable avatar, connection state reads as a dot and a
/// short phrase, and rare or destructive actions stay one level down. Groups
/// follow the inset grouped-list pattern (title outside, hairline rows
/// inside) so desktop, phone and the player menu read the same way.
abstract final class ServerUi {
  static const double panelWidth = 660;
  static const double panelHeight = 820;
  static const double panelRadius = 24;
  static const double cardRadius = 16;
  static const double rowRadius = 12;

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

  /// Curated avatar gradients, ordered so neighbouring slots contrast (a
  /// collision moves to the next slot).
  static const List<(Color, Color)> _palette = [
    (Color(0xFF6D5DFC), Color(0xFF3B2FC9)), // indigo
    (Color(0xFFF5A524), Color(0xFFE2661B)), // amber
    (Color(0xFF14B8A6), Color(0xFF0E7C86)), // teal
    (Color(0xFFEC4899), Color(0xFFBE185D)), // pink
    (Color(0xFF3B9DF8), Color(0xFF2563EB)), // azure
    (Color(0xFFF97362), Color(0xFFD9365E)), // coral
    (Color(0xFF34C77B), Color(0xFF15803D)), // green
    (Color(0xFFB45CF0), Color(0xFF7C3AED)), // violet
    (Color(0xFFFB923C), Color(0xFFC2410C)), // orange
    (Color(0xFF22D3EE), Color(0xFF0E7490)), // cyan
    (Color(0xFF8B9BB4), Color(0xFF475569)), // slate
    (Color(0xFF84CC16), Color(0xFF3F6212)), // lime
  ];

  static int _hashOf(String seed) {
    var hash = 0x811C9DC5;
    for (final unit in seed.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }

  /// Stable gradient for one server, seeded by the persistent server id so
  /// renaming keeps the colour users have learned.
  ///
  /// With [among] (every saved server id) colours are unique for up to twelve
  /// servers: slots are claimed in a fixed id order and a taken slot moves to
  /// the next one. Without it the hash slot is used directly.
  static (Color, Color) gradientOf(String seed, {Iterable<String>? among}) {
    final count = _palette.length;
    if (among != null) {
      final ids = {...among, seed}.toList()..sort();
      if (ids.length <= count) {
        final used = <int>{};
        for (final id in ids) {
          var slot = _hashOf(id) % count;
          while (used.contains(slot)) {
            slot = (slot + 1) % count;
          }
          used.add(slot);
          if (id == seed) return _palette[slot];
        }
      }
    }
    return _palette[_hashOf(seed) % count];
  }

  /// [gradientOf] against the saved servers visible from [context].
  static (Color, Color) gradientFor(BuildContext context, String seed) =>
      gradientOf(
        seed,
        among: AuthScope.maybeOf(context)?.savedServers
            .map((server) => server.id),
      );

  static String monogramOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final first = trimmed.runes.first;
    return String.fromCharCode(first).toUpperCase();
  }

  /// Raised surface used for cards and grouped rows in either theme.
  static Color groupColor(AppColorScheme colors) =>
      colors.brightness == Brightness.dark
      ? colors.surfaceContainer
      : colors.surfaceContainerLowest;

  /// Subtle stroke that separates a raised group from the panel background.
  static Color groupStroke(AppColorScheme colors) => colors.outlineVariant
      .withValues(alpha: colors.brightness == Brightness.dark ? .55 : .8);

  /// Semantic success colour; the app scheme has no dedicated token and the
  /// tertiary hue is not reliably green across themes.
  static Color success(AppColorScheme colors) =>
      colors.brightness == Brightness.dark
      ? const Color(0xFF4ADE80)
      : const Color(0xFF16A34A);

  static Color warning(AppColorScheme colors) =>
      colors.brightness == Brightness.dark
      ? const Color(0xFFFBBF24)
      : const Color(0xFFB45309);
}

enum ServerTone { neutral, current, success, warning, error }

Color serverToneColor(AppColorScheme colors, ServerTone tone) => switch (tone) {
  ServerTone.current => colors.primary,
  ServerTone.success => ServerUi.success(colors),
  ServerTone.warning => ServerUi.warning(colors),
  ServerTone.error => colors.error,
  ServerTone.neutral => colors.onSurfaceVariant,
};

/// Identity mark shared by the list, editor hero, line picker and TV rows.
///
/// Named servers get a stable gradient avatar with their initial (or the
/// chosen icon) and a small provider badge, so two Emby servers no longer
/// look identical. Without a name it falls back to the provider tile.
class ServerIdentityBadge extends StatelessWidget {
  const ServerIdentityBadge({
    super.key,
    required this.type,
    this.iconId,
    this.size = 52,
    this.locked = false,
    this.name,
    this.seed,
    this.showProvider = true,
  });

  final MediaServerType type;
  final String? iconId;
  final double size;
  final bool locked;
  final String? name;
  final String? seed;
  final bool showProvider;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = AppUiTheme.of(context).colorScheme;
    final custom = ServerUi.customIcon(iconId);
    final radius = BorderRadius.circular(size * .3);
    final label = locked
        ? l.serversLocked
        : name == null
        ? type.label
        : '${type.label} · $name';
    if (name == null && seed == null) {
      // Provider tile: used where no specific server exists yet.
      final accent = ServerUi.accentOf(type);
      final dark = colors.brightness == Brightness.dark;
      return Semantics(
        label: label,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: Color.alphaBlend(
              accent.withValues(alpha: dark ? .22 : .12),
              colors.surfaceContainerHigh,
            ),
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
    final (start, end) = ServerUi.gradientFor(context, seed ?? name!);
    final badge = size * .4;
    final face = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: locked
              ? [
                  Color.lerp(start, colors.surfaceContainerHighest, .72)!,
                  Color.lerp(end, colors.surfaceContainerHighest, .72)!,
                ]
              : [start, end],
        ),
        boxShadow: locked
            ? null
            : [
                BoxShadow(
                  color: end.withValues(alpha: .32),
                  blurRadius: size * .22,
                  offset: Offset(0, size * .08),
                ),
              ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Soft top highlight gives the tile a little depth.
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.center,
                colors: [
                  const Color(0xFFFFFFFF).withValues(alpha: .18),
                  const Color(0x00FFFFFF),
                ],
              ),
            ),
          ),
          Center(
            child: locked
                ? Icon(
                    AppIcons.lock,
                    size: size * .42,
                    color: colors.onSurface.withValues(alpha: .78),
                    fill: AppIcons.filled,
                  )
                : custom != null
                ? Icon(
                    custom,
                    size: size * .48,
                    color: const Color(0xFFFFFFFF),
                    fill: AppIcons.filled,
                  )
                : Text(
                    ServerUi.monogramOf(name ?? ''),
                    style: TextStyle(
                      color: const Color(0xFFFFFFFF),
                      fontSize: size * .44,
                      fontWeight: FontWeight.w700,
                      height: 1,
                      letterSpacing: -.5,
                    ),
                  ),
          ),
        ],
      ),
    );
    return Semantics(
      label: label,
      child: SizedBox(
        width: size + (showProvider ? badge * .18 : 0),
        height: size + (showProvider ? badge * .18 : 0),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            face,
            if (showProvider)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: badge,
                  height: badge,
                  padding: EdgeInsets.all(badge * .12),
                  decoration: BoxDecoration(
                    color: ServerUi.groupColor(colors),
                    borderRadius: BorderRadius.circular(badge * .32),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF000000).withValues(alpha: .18),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: ServerTypeMark(type: type, size: badge * .76),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Avatar for a saved server. Keeps the colour stable across renames.
class ServerAvatar extends StatelessWidget {
  const ServerAvatar({
    super.key,
    required this.server,
    this.size = 48,
    this.locked = false,
    this.showProvider = true,
    this.nameOverride,
    this.iconOverride,
  });

  final SavedServer server;
  final double size;
  final bool locked, showProvider;
  final String? nameOverride, iconOverride;

  @override
  Widget build(BuildContext context) => ServerIdentityBadge(
    type: server.serviceType,
    iconId: iconOverride ?? server.iconId,
    size: size,
    locked: locked,
    name: nameOverride ?? server.displayName,
    seed: server.id,
    showProvider: showProvider,
  );
}

/// Coloured status dot. Paired with text so state never relies on colour.
class ServerStatusDot extends StatelessWidget {
  const ServerStatusDot({super.key, required this.tone, this.size = 8});
  final ServerTone tone;
  final double size;
  @override
  Widget build(BuildContext context) {
    final color = serverToneColor(AppUiTheme.of(context).colorScheme, tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: tone == ServerTone.neutral
            ? null
            : [BoxShadow(color: color.withValues(alpha: .45), blurRadius: 6)],
      ),
    );
  }
}

/// Compact tag. Used sparingly: one per row at most.
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
    final dark = colors.brightness == Brightness.dark;
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? .16 : .11),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              Icon(AppIcons.hourglass, size: 12, color: color)
            else if (icon != null)
              Icon(icon, size: 12, color: color, fill: AppIcons.filled)
            else
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 5),
            Text(
              label,
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                height: 1.25,
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

/// Small caption above a group: "连接线路 · 3 条".
class ServerGroupHeader extends StatelessWidget {
  const ServerGroupHeader({
    super.key,
    required this.title,
    this.trailing,
    this.description,
    this.padding = const EdgeInsets.fromLTRB(4, 0, 4, 8),
  });
  final String title;
  final Widget? trailing;
  final String? description;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .2,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 3),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant.withValues(alpha: .85),
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inset grouped list. Rows are separated by hairlines aligned with their
/// text, never by nested cards.
class ServerGroup extends StatelessWidget {
  const ServerGroup({
    super.key,
    required this.children,
    this.title,
    this.trailing,
    this.description,
    this.dividerIndent = 16,
    this.margin = const EdgeInsets.only(bottom: 22),
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final String? title, description;
  final Widget? trailing;
  final double dividerIndent;
  final EdgeInsets margin, padding;

  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          AppDivider(
            height: 1,
            thickness: .6,
            indent: dividerIndent,
            color: colors.outlineVariant.withValues(alpha: .7),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            ServerGroupHeader(
              title: title!,
              trailing: trailing,
              description: description,
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: ServerUi.groupColor(colors),
              borderRadius: BorderRadius.circular(ServerUi.cardRadius),
              border: Border.all(
                color: ServerUi.groupStroke(colors),
                width: .6,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ServerUi.cardRadius),
              child: Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Leading glyph for a grouped row: icon in a tinted rounded square.
class ServerRowIcon extends StatelessWidget {
  const ServerRowIcon(
    this.icon, {
    super.key,
    this.tone = ServerTone.current,
    this.size = 32,
  });
  final IconData icon;
  final ServerTone tone;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    final color = serverToneColor(colors, tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(
          alpha: colors.brightness == Brightness.dark ? .18 : .11,
        ),
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Icon(icon, size: size * .56, color: color, fill: AppIcons.filled),
    );
  }
}

/// One row inside a [ServerGroup]. Hover and keyboard focus are visible; a
/// destructive row is coloured, never only iconised.
class ServerRow extends StatefulWidget {
  const ServerRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.accent = false,
    this.chevron = false,
    this.selected = false,
    this.focusNode,
    this.autofocus = false,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 12, 12),
    this.titleMaxLines = 1,
  });

  final Widget title;
  final Widget? subtitle, leading, trailing;
  final VoidCallback? onTap;
  final bool destructive, accent, chevron, selected, autofocus;
  final FocusNode? focusNode;
  final EdgeInsets padding;
  final int titleMaxLines;

  @override
  State<ServerRow> createState() => _ServerRowState();
}

class _ServerRowState extends State<ServerRow> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final enabled = widget.onTap != null;
    // Only action rows dim when unavailable; information rows never look
    // disabled.
    final actionRow = widget.chevron || widget.accent || widget.destructive;
    final titleColor = !enabled && actionRow && !widget.selected
        ? colors.onSurface.withValues(alpha: .45)
        : widget.destructive
        ? colors.error
        : widget.accent
        ? colors.primary
        : colors.onSurface;
    final highlight = widget.selected
        ? colors.primary.withValues(
            alpha: colors.brightness == Brightness.dark ? .12 : .07,
          )
        : hovered && enabled
        ? colors.onSurface.withValues(alpha: .045)
        : null;
    final content = AnimatedContainer(
      duration: AppMotion.fast,
      constraints: const BoxConstraints(minHeight: 52),
      padding: widget.padding,
      color: highlight,
      child: Row(
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 13),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DefaultTextStyle(
                  style: theme.textTheme.bodyLarge!.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                  maxLines: widget.titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  child: widget.title,
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 2),
                  DefaultTextStyle(
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.35,
                    ),
                    child: widget.subtitle!,
                  ),
                ],
              ],
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(width: 10),
            widget.trailing!,
          ],
          if (widget.chevron) ...[
            const SizedBox(width: 6),
            Icon(
              AppIcons.chevronRight,
              size: 18,
              color: colors.onSurfaceVariant.withValues(alpha: .7),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      selected: widget.selected,
      child: enabled
          ? AppSurfaceAction(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              onTap: widget.onTap,
              onHover: (value) => setState(() => hovered = value),
              borderRadius: BorderRadius.circular(ServerUi.rowRadius),
              child: content,
            )
          : content,
    );
  }
}

/// Section used by the editor for form content (text fields, icon picker).
/// Title sits outside the card like every other group.
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
    final colors = AppUiTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ServerGroupHeader(
            title: title,
            trailing: trailing,
            description: description,
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            decoration: BoxDecoration(
              color: ServerUi.groupColor(colors),
              borderRadius: BorderRadius.circular(ServerUi.cardRadius),
              border: Border.all(
                color: ServerUi.groupStroke(colors),
                width: .6,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// Identity row for a single server: avatar, name and account.
class ServerIdentityCard extends StatelessWidget {
  const ServerIdentityCard({
    super.key,
    required this.server,
    this.trailing,
    this.subtitle,
    this.locked = false,
  });

  final SavedServer server;
  final Widget? trailing;
  final String? subtitle;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ServerUi.cardRadius),
        color: ServerUi.groupColor(colors),
        border: Border.all(color: ServerUi.groupStroke(colors), width: .6),
      ),
      child: Row(
        children: [
          ServerAvatar(server: server, size: 42, locked: locked),
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
                const SizedBox(height: 2),
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

/// Large header for the editor: the server as the user knows it, with its
/// state as a few short tags.
class ServerHeroHeader extends StatelessWidget {
  const ServerHeroHeader({
    super.key,
    required this.server,
    required this.title,
    required this.subtitle,
    this.tags = const [],
    this.iconOverride,
  });

  final SavedServer server;
  final String title, subtitle;
  final List<Widget> tags;
  final String? iconOverride;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    final (start, _) = ServerUi.gradientFor(context, server.id);
    final dark = colors.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ServerUi.cardRadius + 4),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              start.withValues(alpha: dark ? .22 : .12),
              ServerUi.groupColor(colors),
            ),
            ServerUi.groupColor(colors),
          ],
        ),
        border: Border.all(color: ServerUi.groupStroke(colors), width: .6),
      ),
      child: Row(
        children: [
          ServerAvatar(
            server: server,
            size: 60,
            nameOverride: title,
            iconOverride: iconOverride,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title.trim().isEmpty ? server.displayName : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.3,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  Wrap(spacing: 6, runSpacing: 6, children: tags),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact feedback banner. [action] keeps the next step next to the problem
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
    final dark = colors.brightness == Brightness.dark;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? .12 : .07),
          borderRadius: BorderRadius.circular(ServerUi.rowRadius),
          border: Border.all(color: color.withValues(alpha: dark ? .22 : .16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    error ? AppIcons.error : AppIcons.info,
                    size: 17,
                    color: color,
                    fill: AppIcons.filled,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurface,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            if (action != null)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: action,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Centred decision view (remove, sign out, impact, unlock). One clear
/// subject, one sentence of consequence and the two choices at the bottom.
class ServerFocusView extends StatelessWidget {
  const ServerFocusView({
    super.key,
    required this.title,
    required this.children,
    this.mark,
    this.message,
  });

  final Widget? mark;
  final String title;
  final String? message;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            if (mark != null) Center(child: mark!),
            if (mark != null) const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -.2,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Server avatar with a small status glyph (lock, warning) in a ring.
class ServerMarkWithGlyph extends StatelessWidget {
  const ServerMarkWithGlyph({
    super.key,
    required this.server,
    required this.glyph,
    this.tone = ServerTone.current,
    this.size = 72,
  });
  final SavedServer server;
  final IconData glyph;
  final ServerTone tone;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    final color = serverToneColor(colors, tone);
    final ring = size * .44;
    return SizedBox(
      width: size + ring * .3,
      height: size + ring * .3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ServerAvatar(server: server, size: size, showProvider: false),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: ring,
              height: ring,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: ServerUi.groupColor(colors),
                  width: 3,
                ),
              ),
              child: Icon(
                glyph,
                size: ring * .52,
                color: colors.brightness == Brightness.dark
                    ? colors.surface
                    : const Color(0xFFFFFFFF),
                fill: AppIcons.filled,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Blurred, dimmed backdrop behind the desktop panel. The page underneath
/// stays recognisable but no longer competes with the panel.
class ServerScrim extends StatelessWidget {
  const ServerScrim({super.key, this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final dark =
        AppUiTheme.of(context).colorScheme.brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: ColoredBox(
            color: const Color(0xFF000000).withValues(alpha: dark ? .5 : .28),
          ),
        ),
      ),
    );
  }
}

/// Cancel + confirm, side by side and equally wide. The confirm side carries
/// the consequence colour so "移除" never looks like "进入".
class ServerDecisionButtons extends StatelessWidget {
  const ServerDecisionButtons({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    required this.cancelLabel,
    required this.onCancel,
    this.confirmKey,
    this.cancelKey,
    this.destructive = false,
    this.busy = false,
  });

  final String confirmLabel, cancelLabel;
  final VoidCallback? onConfirm;
  final VoidCallback onCancel;
  final Key? confirmKey, cancelKey;
  final bool destructive, busy;

  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: AppButton(
            key: cancelKey,
            onPressed: onCancel,
            variant: AppButtonVariant.tinted,
            foregroundColor: colors.onSurface,
            color: colors.onSurface.withValues(alpha: .07),
            minimumSize: const Size(64, 48),
            child: Text(cancelLabel),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppButton(
            key: confirmKey,
            onPressed: busy ? null : onConfirm,
            variant: AppButtonVariant.filled,
            color: destructive ? colors.error : null,
            foregroundColor: destructive ? colors.onError : null,
            minimumSize: const Size(64, 48),
            child: busy
                ? CupertinoActivityIndicator(
                    radius: 9,
                    color: destructive ? colors.onError : colors.onPrimary,
                  )
                : Text(confirmLabel),
          ),
        ),
      ],
    );
  }
}
