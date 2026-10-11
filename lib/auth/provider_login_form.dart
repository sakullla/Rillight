import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../app/presentation_environment.dart';
import '../app/tv_widgets.dart';
import '../media_server/capabilities.dart';
import 'auth_scope.dart';
import 'provider_connect_dialog.dart';
import 'server_list_store.dart';

/// Keeps provider selection and authorization in the current login page.
class ProviderLoginForm extends StatefulWidget {
  const ProviderLoginForm({
    super.key,
    required this.embyForm,
    required this.userAgent,
    this.selectedServer,
  });

  final Widget embyForm;
  final String Function() userAgent;
  final SavedServer? selectedServer;

  @override
  State<ProviderLoginForm> createState() => _ProviderLoginFormState();
}

class _ProviderLoginFormState extends State<ProviderLoginForm> {
  late MediaServerType type =
      widget.selectedServer?.serviceType ?? MediaServerType.emby;

  @override
  void didUpdateWidget(ProviderLoginForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedServer?.id != widget.selectedServer?.id) {
      type = widget.selectedServer?.serviceType ?? MediaServerType.emby;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final tv = PresentationScope.maybeOf(context)?.isTv == true;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final value in MediaServerType.values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: tv
                        ? TvAction(
                            key: Key('login-provider-${value.name}'),
                            emphasized: value == type,
                            onPressed: auth.isBusy
                                ? null
                                : () => setState(() => type = value),
                            child: Center(child: Text(_label(value))),
                          )
                        : ChoiceChip(
                            key: Key('login-provider-${value.name}'),
                            label: Center(child: Text(_label(value))),
                            selected: value == type,
                            showCheckmark: false,
                            onSelected: auth.isBusy
                                ? null
                                : (_) => setState(() => type = value),
                          ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (type == MediaServerType.emby)
            widget.embyForm
          else
            ProviderConnectDialog(
              key: ValueKey((type, widget.selectedServer?.id)),
              auth: auth,
              existing: widget.selectedServer?.serviceType == type
                  ? widget.selectedServer
                  : null,
              initialType: type,
              initialUserAgent: widget.userAgent(),
              inline: true,
              onConnected: () => context.go(AppRoutes.home),
            ),
        ],
      ),
    );
  }

  String _label(MediaServerType value) => switch (value) {
    MediaServerType.emby => 'Emby',
    MediaServerType.jellyfin => 'Jellyfin',
    MediaServerType.plex => 'Plex',
  };
}
