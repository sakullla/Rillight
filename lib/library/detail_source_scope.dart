import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app/presentation_environment.dart';
import 'aggregation_page.dart';
import '../app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';

/// A detail subtree owns a source lease, never another authentication authority.
class DetailSourceScope extends InheritedWidget {
  const DetailSourceScope({
    super.key,
    required this.origin,
    required this.cache,
    required this.imagePolicy,
    required super.child,
  });
  final PlaybackOrigin origin;
  final CatalogCache cache;
  final MediaImageSourcePolicy imagePolicy;
  static MediaImageSourcePolicy? imagePolicyOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DetailSourceScope>()
      ?.imagePolicy;
  static CatalogCache cacheOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailSourceScope>()?.cache ??
      CatalogScope.of(context).cache;
  @override
  bool updateShouldNotify(DetailSourceScope oldWidget) =>
      origin != oldWidget.origin;
  static PlaybackOrigin? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailSourceScope>()?.origin;
  static EmbyClient clientOf(BuildContext context) {
    final origin = maybeOf(context);
    origin?.permit.requireValid();
    return origin?.client ?? AuthScope.of(context).client;
  }

  static PlayerHostOpenItemCommand? command(
    BuildContext context,
    String id, {
    String? seasonId,
  }) {
    final origin = maybeOf(context);
    if (origin == null) return null;
    origin.permit.requireValid();
    return PlayerHostOpenItemCommand(
      itemId: id,
      seasonId: seasonId,
      source: SourceReference(account: origin.source.account, itemId: id),
      libraryId: origin.libraryId,
      regionGeneration: origin.permit.regionGeneration,
    );
  }
}

class SourceDetailGate extends StatefulWidget {
  const SourceDetailGate({
    super.key,
    required this.auth,
    required this.itemId,
    required this.command,
    required this.child,
    this.showComparison = true,
  });
  final bool showComparison;
  final AuthController auth;
  final String itemId;
  final PlayerHostOpenItemCommand? command;
  final Widget child;
  @override
  State<SourceDetailGate> createState() => _SourceDetailGateState();
}

class _SourceDetailGateState extends State<SourceDetailGate> {
  PlaybackOrigin? _origin;
  MediaImageSourcePolicy? _imagePolicy;
  bool _resolved = false;
  // Sessionless source-local cache: no writes into selected Auth's namespace,
  // and no persistent private detail projection surviving revocation.
  final _cache = CatalogCache();
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_changed);
    widget.auth.sources.addSourceRevocation(_revoked);
    widget.auth.regionAccess.addListener(_changed);
    _resolve();
  }

  Future<void> _resolve() async {
    var command = widget.command;
    try {
      if (command == null) {
        // A legacy address is explicitly bound to the selected ordinary
        // service. It cannot enter a private region or infer another service.
        final selected = widget.auth.session?.server;
        if (selected == null || selected.region != AccessRegion.ordinary) {
          return;
        }
        final allowed = widget.auth.sources
            .project(AccessRegion.ordinary)
            .where(
              (s) => s.id == selected.id && s.participates && s.scopeKnown,
            );
        if (allowed.length != 1 || allowed.single.libraryIds.isEmpty) return;
        final account = await widget.auth.sources.acquireAccount(
          selected.id,
          region: AccessRegion.ordinary,
          libraryId: allowed.single.libraryIds.first,
        );
        final permit = widget.auth.sources.permit(account);
        var item = await permit.dispatch((c) => c.getItem(widget.itemId));
        final visited = <String>{};
        while (!allowed.single.libraryIds.contains(item.id)) {
          if (!visited.add(item.id) ||
              item.parentId == null ||
              visited.length > 32) {
            return;
          }
          item = await permit.dispatch((c) => c.getItem(item.parentId!));
        }
        command = PlayerHostOpenItemCommand(
          itemId: widget.itemId,
          source: SourceReference(account: account, itemId: widget.itemId),
          libraryId: item.id,
          regionGeneration: permit.regionGeneration,
        );
      }
      if (command.source == null ||
          command.itemId != widget.itemId ||
          command.source!.itemId != widget.itemId) {
        return;
      }
      final account = command.source!.account;
      final registry = widget.auth.sources;
      final permit = registry.permit(account, libraryId: command.libraryId);
      if (command.libraryId == null ||
          command.regionGeneration != permit.regionGeneration) {
        return;
      }
      permit.requireValid();
      var item = await permit.dispatch((c) => c.getItem(widget.itemId));
      final visited = <String>{};
      while (item.id != command.libraryId) {
        if (!visited.add(item.id) ||
            item.parentId == null ||
            visited.length > 32) {
          return;
        }
        item = await permit.dispatch((c) => c.getItem(item.parentId!));
      }
      final client = await permit.dispatch(
        (c) async => c.withRequestGuard(permit.requireValid),
      );
      permit.requireValid();
      if (!mounted) return;
      _origin = PlaybackOrigin(
        source: command.source!,
        work: command.source!,
        libraryId: command.libraryId!,
        permit: permit,
        client: client,
      );
      _imagePolicy = MediaImageSourcePolicy(_origin!);
    } catch (_) {
      // A denied or failed source never falls back to selected Auth.
    } finally {
      if (mounted) setState(() => _resolved = true);
    }
  }

  void _revoked(String serverId) {
    if (_origin?.source.account.configuredServerId == serverId) {
      _imagePolicy?.revoke();
      _origin = null;
      _changed();
    }
  }

  void _changed() {
    if (_imagePolicy?.isValid == false) _imagePolicy?.revoke();
    final command = widget.command;
    if (mounted && command?.source != null) {
      var valid = false;
      try {
        final permit = widget.auth.sources.permit(
          command!.source!.account,
          libraryId: command.libraryId,
        );
        valid =
            permit.isValid &&
            command.regionGeneration == permit.regionGeneration;
      } catch (_) {
        /* An unavailable account is not a legacy fallback. */
      }
      if (!valid) {
        final desktop =
            context
                .getInheritedWidgetOfExactType<PresentationScope>()
                ?.environment
                .isDesktop ??
            true;
        // Replace the whole deep stack and clear route extras, not just pixels.
        final router = GoRouter.maybeOf(context);
        final revokedUri = router?.routerDelegate.currentConfiguration.uri;
        // Redact the invalid lease immediately in build, then replace history
        // after that frame. Mutating the Navigator while source revocation
        // is notifying its mounted subtree races its render/semantics teardown.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Overlay revocation can pop this detail before the frame completes.
          // The invalid deep stack still must be replaced, even if its gate
          // has already unmounted; otherwise unlocking restores private data.
          if (router == null) return;
          final current = router.routerDelegate.currentConfiguration;
          // Imperative push keeps the base URI/extra on currentConfiguration;
          // the top player's lease lives in its own match instead.
          final topExtra = router.state.extra;
          final topSource = switch (topExtra) {
            PlayerHostOpenItemCommand(:final source) => source,
            PlayerOpenRequest(:final source) => source,
            _ => null,
          };
          if (topSource != null &&
              topSource.account != command!.source!.account) {
            return;
          }
          // go() publishes intent before its async parser updates the delegate.
          // Protect that intent too, not only the previously committed stack.
          final information = router.routeInformationProvider.value;
          final informationState = information.state;
          final extra = informationState is RouteInformationState
              ? informationState.extra
              : current.extra;
          final currentSource = switch (extra) {
            PlayerHostOpenItemCommand(:final source) => source,
            PlayerOpenRequest(:final source) => source,
            _ => null,
          };
          // A covered detail owns only its revoked source, not a newer route
          // or an independently authorized player on top of it. An overlay
          // pop may already have returned to the anonymous private root;
          // that old deep stack still needs clearing after the gate unmounts.
          if (currentSource != null &&
              currentSource.account != command!.source!.account) {
            return;
          }
          if (currentSource == null &&
              information.uri != revokedUri &&
              information.uri.path != '/private') {
            return;
          }
          router.go(desktop ? '/aggregation' : '/', extra: null);
        });
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // No gate may leave private bytes behind without a revocation listener.
    if (_imagePolicy?.allowsDisk == false) _imagePolicy?.revoke();
    widget.auth.removeListener(_changed);
    widget.auth.sources.removeSourceRevocation(_revoked);
    widget.auth.regionAccess.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final origin = _origin;
    if (origin == null || !origin.permit.isValid) {
      if (!_resolved) return const Center(child: CircularProgressIndicator());
      final l = AppLocalizations.of(context);
      return Center(
        child: Text(
          widget.command?.source?.account.region == AccessRegion.private &&
                  !widget.auth.regionAccess.allows(AccessRegion.private)
              ? l.aggregationPrivateLocked
              : l.aggregationUnavailableDetail,
        ),
      );
    }
    return DetailSourceScope(
      origin: origin,
      cache: _cache,
      imagePolicy: _imagePolicy!,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (widget.showComparison)
            const Positioned(
              right: 16,
              bottom: 24,
              child: SourceComparisonAction(),
            ),
        ],
      ),
    );
  }
}
