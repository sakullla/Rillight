import 'package:flutter/services.dart';

import '../app/l10n/app_localizations.dart';
import '../app/ui/ui.dart';
import '../app/ui/app_icons.dart';

/// A single scrollable body and a persistent header; child steps replace the
/// body rather than creating another modal route above the current form.
class ServerFlowFrame extends StatefulWidget {
  const ServerFlowFrame({
    super.key,
    required this.title,
    required this.onBack,
    required this.child,
    this.action,
    this.backLabel,
    this.scroll = true,
  });
  final String title;
  final String? backLabel;
  final VoidCallback onBack;
  final Widget child;
  final Widget? action;
  final bool scroll;
  @override
  State<ServerFlowFrame> createState() => _ServerFlowFrameState();
}

class _ServerFlowFrameState extends State<ServerFlowFrame> {
  final scrollController = ScrollController();
  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onBack,
      },
      child: FocusScope(
        key: ValueKey(widget.title),
        autofocus: true,
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 12, 12),
                child: Row(
                  children: [
                    AppIconButton(
                      key: const Key('server-flow-back'),
                      tooltip: widget.backLabel ?? l.serversBack,
                      onPressed: widget.onBack,
                      minimumSize: const Size(48, 48),
                      icon: const Icon(AppIcons.back),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppUiTheme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (widget.action != null) ...[
                      const SizedBox(width: 8),
                      widget.action!,
                    ],
                  ],
                ),
              ),
              const AppDivider(height: 1),
              Expanded(
                child: widget.scroll
                    ? CupertinoScrollbar(
                        controller: scrollController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: scrollController,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.all(20),
                          child: widget.child,
                        ),
                      )
                    : widget.child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
