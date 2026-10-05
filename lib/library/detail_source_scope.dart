import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_host_command.dart';
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
  });
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
    final command = widget.command;
    // Legacy selected-server pages retain their existing behavior. Explicit
    // sources never fall back to that selection, including denied commands.
    if (command == null) return;
    try {
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
      _origin = PlaybackOrigin(
        source: command.source!,
        work: command.source!,
        libraryId: command.libraryId!,
        permit: permit,
        client: client,
      );
      _imagePolicy = MediaImageSourcePolicy(_origin!);
    } catch (_) {}
    if (mounted) setState(() {});
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
    if (widget.command == null) return widget.child;
    final origin = _origin;
    if (origin == null || !origin.permit.isValid) {
      return const SizedBox.shrink();
    }
    return DetailSourceScope(
      origin: origin,
      cache: _cache,
      imagePolicy: _imagePolicy!,
      child: widget.child,
    );
  }
}
