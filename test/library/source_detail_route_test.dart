import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

import 'package:rillight/player/player_host_command.dart';

class _ImageDisk implements MediaImageDiskStore {
  @override
  Future<Uint8List?> read(String key) async => null;
  @override
  Future<void> write(String key, Uint8List bytes) async {}
  @override
  Future<void> remove(String key) async {}
  @override
  Future<void> clear() async {}
}

class _Transport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final host = options.uri.host;
    final path = options.uri.path;
    if (path.contains('/Images/')) {
      return ResponseBody.fromBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aO1sAAAAASUVORK5CYII=',
        ),
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    }
    Object data = {'Items': [], 'TotalRecordCount': 0};
    if (path.endsWith('/System/Info/Public')) {
      data = {'Id': host, 'ServerName': host};
    } else if (path.endsWith('/Users/user-$host')) {
      data = {'Id': 'user-$host', 'Name': 'synthetic'};
    } else if (path.endsWith('/Similar')) {
      data = {
        'Items': [
          {'Id': 'similar', 'Name': '$host-similar', 'Type': 'Movie'},
        ],
        'TotalRecordCount': 1,
      };
    } else if (RegExp(r'/Items/[^/]+$').hasMatch(path)) {
      final id = path.split('/').last;
      data = {
        'Id': id,
        'Name': '$host-$id-detail',
        'Type': id == 'library' ? 'CollectionFolder' : 'Movie',
        if (id != 'library') 'ParentId': 'library',
        if (id != 'library') 'ImageTags': {'Primary': 'synthetic-$host'},
      };
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    for (final id in ['same-id', 'different-b-id']) {
      testWidgets(
        '${environment.presentation.name} Auth A receives B detail $id without naked-ID fallback',
        (tester) async {
          tester.view.physicalSize = const Size(1440, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          MediaImageCache.instance.clearMemory();
          MediaImageCache.instance.debugSetDiskStore(_ImageDisk());
          addTearDown(() {
            MediaImageCache.instance.clearMemory();
            MediaImageCache.instance.debugSetDiskStore(null);
          });
          final transport = _Transport();
          EmbyClient client() => EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'test',
              deviceId: 'detail',
              version: '1',
            ),
            dio: Dio()..httpClientAdapter = transport,
          );
          final store = MemoryServerListStore(
            ServerListSnapshot(
              lastServerId: 'a',
              servers: [
                for (final server in ['a', 'b'])
                  SavedServer(
                    id: server,
                    name: server,
                    username: 'synthetic',
                    libraryIds: const ['library'],
                    scopeKnown: true,
                    lines: [ServerLine(id: 'line', address: 'https://$server')],
                  ),
              ],
            ),
          );
          final credentials = MemoryCredentialStore({
            for (final server in ['a', 'b'])
              server: StoredCredentials(
                accessToken: 'token-$server',
                userId: 'user-$server',
                username: 'synthetic',
              ),
          });
          final registry = SourceSessionRegistry(
            access: RegionAccessController(),
            store: store,
            credentials: credentials,
            createClient: client,
          );
          await tester.runAsync(registry.load);
          final b = (await tester.runAsync(
            () => registry.authenticate('b'),
          ))!.account;
          final auth = AuthController(
            client: client(),
            credentials: credentials,
            servers: store,
            sources: registry,
          );
          await tester.runAsync(auth.restore);
          final router = createAppRouter(auth: auth, environment: environment);
          await tester.pumpWidget(
            RillightApp(auth: auth, router: router, environment: environment),
          );
          await tester.pumpAndSettle();
          transport.requests.clear();
          final permit = registry.permit(b, libraryId: 'library');
          router.go(
            AppRoutes.item(id),
            extra: PlayerHostOpenItemCommand(
              itemId: id,
              source: SourceReference(account: b, itemId: id),
              libraryId: 'library',
              regionGeneration: permit.regionGeneration,
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          expect(find.byType(DetailSourceScope), findsOneWidget);
          expect(find.text('b-$id-detail'), findsWidgets);
          expect(auth.session!.server.id, 'a');
          // Source-local cards remain usable, but unadapted bare-ID shelf
          // expansion must not leave this scope and request selected Auth A.
          if (environment.isDesktop) {
            final similarShelf = tester.widget<MediaShelf>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is MediaShelf &&
                    widget.shelfId == CatalogKeys.shelfSimilar,
              ),
            );
            expect(similarShelf.onMore, isNull);
          } else if (!environment.isTv) {
            final more = tester.widget<TextButton>(
              find.byKey(CatalogKeys.shelfMore(CatalogKeys.shelfSimilar)),
            );
            expect(more.onPressed, isNull);
          }
          final scope = tester.widget<DetailSourceScope>(
            find.byType(DetailSourceScope),
          );
          expect(scope.cache.hasSession, isFalse);
          expect(
            transport.requests.where(
              (r) => r.uri.path.contains('/Images/') && r.uri.host == 'a',
            ),
            isEmpty,
          );
          expect(
            transport.requests.where(
              (r) => r.uri.path.contains('/Images/') && r.uri.host == 'b',
            ),
            isNotEmpty,
          );
          expect(
            transport.requests.where(
              (r) => r.uri.path.contains('/Items/$id') && r.uri.host == 'a',
            ),
            isEmpty,
          );
          expect(
            transport.requests.where(
              (r) => r.uri.path.contains('/Items/$id') && r.uri.host == 'b',
            ),
            isNotEmpty,
          );
          // A mismatched source is rejected by the in-process receiver too,
          // not only by the IPC codec.
          router.go(
            AppRoutes.item('mismatch'),
            extra: PlayerHostOpenItemCommand(
              itemId: 'mismatch',
              source: SourceReference(account: b, itemId: id),
              libraryId: 'library',
              regionGeneration: permit.regionGeneration,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(DetailSourceScope), findsNothing);
          expect(
            transport.requests.where(
              (r) => r.uri.path.contains('/Items/mismatch'),
            ),
            isEmpty,
          );
          // A stale explicit command must stay denied, never render selected A.
          router.go(
            AppRoutes.item('denied'),
            extra: PlayerHostOpenItemCommand(
              itemId: 'denied',
              source: SourceReference(account: b, itemId: 'denied'),
              libraryId: 'library',
              regionGeneration: permit.regionGeneration + 1,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(DetailSourceScope), findsNothing);
          expect(
            transport.requests.where(
              (r) => r.uri.path.contains('/Items/denied'),
            ),
            isEmpty,
          );
          router.go(
            AppRoutes.item(id),
            extra: PlayerHostOpenItemCommand(
              itemId: id,
              source: SourceReference(account: b, itemId: id),
              libraryId: 'library',
              regionGeneration: permit.regionGeneration,
            ),
          );
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          expect(find.byType(DetailSourceScope), findsOneWidget);
          await registry.configureScope(
            'b',
            participates: false,
            libraryIds: {},
          );
          await tester.pumpAndSettle();
          expect(find.byType(DetailSourceScope), findsNothing);
          expect(find.text('b-$id-detail'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          auth.dispose();
          // CatalogShell's optional real-I/O socket can complete DNS after
          // disposal. Advance its stagger timer and let the receipt settle;
          // this bounded drain is not native/network acceptance evidence.
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
        },
        tags: ['integration'],
      );
    }
  }
}
