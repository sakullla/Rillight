import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.item,
    this.width,
    this.height,
    this.preferBackdrop = false,
    this.maxWidth,
  });

  final EmbyItem item;
  final double? width;
  final double? height;
  final bool preferBackdrop;
  final int? maxWidth;

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  Future<Uint8List?>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  @override
  void didUpdateWidget(MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.primaryImageTag != widget.item.primaryImageTag ||
        oldWidget.item.backdropImageTag != widget.item.backdropImageTag ||
        oldWidget.preferBackdrop != widget.preferBackdrop) {
      _future = _load();
    }
  }

  Future<Uint8List?> _load() async {
    final client = AuthScope.of(context).client;
    final maxWidth = widget.maxWidth ?? widget.width?.round() ?? 280;
    Future<Uint8List?> fetch(String type, String? tag) async {
      try {
        final bytes = await client.getItemImage(
          widget.item.id,
          type: type,
          tag: tag,
          maxWidth: maxWidth,
        );
        if (bytes.isEmpty) {
          return null;
        }
        return Uint8List.fromList(bytes);
      } catch (_) {
        return null;
      }
    }

    if (widget.preferBackdrop) {
      final backdrop = await fetch('Backdrop', widget.item.backdropImageTag);
      if (backdrop != null) {
        return backdrop;
      }
    }
    return fetch('Primary', widget.item.primaryImageTag);
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    if (!widget.preferBackdrop && widget.item.primaryImageTag == null) {
      return PosterPlaceholder(width: width, height: height);
    }
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return _loadingBox(context, width, height);
        }
        if (bytes == null || bytes.isEmpty) {
          return PosterPlaceholder(width: width, height: height);
        }
        return Image.memory(
          bytes,
          width: width,
          height: height,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            return PosterPlaceholder(width: width, height: height);
          },
        );
      },
    );
  }

  Widget _loadingBox(BuildContext context, double? width, double? height) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
