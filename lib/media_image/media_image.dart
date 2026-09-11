import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({super.key, required this.item, this.width, this.height});

  final EmbyItem item;
  final double? width;
  final double? height;

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
        oldWidget.item.primaryImageTag != widget.item.primaryImageTag) {
      _future = _load();
    }
  }

  Future<Uint8List?> _load() async {
    final tag = widget.item.primaryImageTag;
    if (tag == null || tag.isEmpty) {
      return null;
    }
    try {
      final bytes = await AuthScope.of(
        context,
      ).client.getPrimaryImage(widget.item.id, tag: tag);
      if (bytes.isEmpty) {
        return null;
      }
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = widget.height;
    if (widget.item.primaryImageTag == null) {
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
