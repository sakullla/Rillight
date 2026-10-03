import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home_sections.dart';

/// 轮播图、继续观看、下一集的显示开关。桌面顶栏「⋯」、手机编辑页和电视首页共用。
Future<void> showHomeDisplayDialog(BuildContext context) {
  final catalog = CatalogScope.of(context);
  final sections = PhoneHomeSectionController.app();
  final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
  unawaited(sections.load(serverId));
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final l10n = AppLocalizations.of(context);
      final viewport = MediaQuery.sizeOf(context);
      final width = AppViewport.fit(420, viewport.width - 48, viewport);
      final height = AppViewport.fit(480, viewport.height * 0.88, viewport);
      return Dialog(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        child: LiquidGlass(
          kind: LiquidGlassKind.panel,
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Text(
                    l10n.phoneHomeEdit,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([sections, catalog]),
                    builder: (context, _) {
                      return PhoneHomeSectionEditor(
                        controller: sections,
                        libraries: catalog.libraries,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
