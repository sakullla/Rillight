import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/library/server_library_page.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/media_shelf.dart';
import 'package:rillight/media_image/media_image.dart';

import 'package:rillight/player/player_host_command.dart';

class _ImageDisk implements MediaImageDiskStore {
  final reads = <String>[];
  final writes = <String>[];
  @override
  Future<Uint8List?> read(String key) async {
    reads.add(key);
    return null;
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    writes.add(key);
  }

  @override
  Future<void> remove(String key) async {}
  @override
  Future<void> clear() async {}
}

class _Transport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Completer<void>? imageBarrier;
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
      await imageBarrier?.future;
      return ResponseBody.fromBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
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
        'Type': switch (id) {
          'library' => 'CollectionFolder',
          'episode-no-parent' => 'Episode',
          'season-no-parent' => 'Season',
          'series' => 'Series',
          _ => 'Movie',
        },
        if (id == 'episode-no-parent') 'SeasonId': 'season-no-parent',
        if (id.endsWith('-no-parent')) 'SeriesId': 'series',
        if (id != 'library' && !id.endsWith('-no-parent'))
          'ParentId': 'library',
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
  testWidgets(
    'server shelf play and detail retain source and concrete parent',
    (tester) async {
      final transport = _Transport();
      EmbyClient client() => EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'source-card',
          version: '1',
        ),
        dio: Dio()..httpClientAdapter = transport,
      );
      final store = MemoryServerListStore(
        ServerListSnapshot(
          lastServerId: 'a',
          servers: [
            for (final id in ['a', 'b'])
              SavedServer(
                id: id,
                name: id,
                username: 'synthetic',
                libraryIds: const ['library'],
                scopeKnown: true,
                lines: [ServerLine(id: 'line', address: 'https://$id')],
              ),
          ],
        ),
      );
      final credentials = MemoryCredentialStore({
        for (final id in ['a', 'b'])
          id: StoredCredentials(
            accessToken: 'token-$id',
            userId: 'user-$id',
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
      final account = (await tester.runAsync(
        () => registry.authenticate('b'),
      ))!.account;
      final auth = AuthController(
        client: client(),
        credentials: credentials,
        servers: store,
        sources: registry,
      );
      await tester.runAsync(auth.restore);
      final host = OverlayPlayerWindowHost();
      const item = EmbyItem(
        id: 'episode-no-parent',
        name: 'Episode',
        type: 'Episode',
        parentId: 'virtual-resume-folder',
        seriesId: 'series',
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: scopeServerPosters(
                  account: account,
                  serverId: 'b',
                  child: PosterCard(
                    item: item,
                    wide: true,
                    onTap: () =>
                        openServerItem(context, account: account, item: item),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/item/:id',
            builder: (context, state) => SourceDetailGate(
              auth: auth,
              itemId: state.pathParameters['id']!,
              command: state.extra as PlayerHostOpenItemCommand,
              showComparison: false,
              child: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('source-detail-ready'),
                      PosterCard(item: item, wide: true, onTap: () {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        AuthScope(
          controller: auth,
          child: PlayerWindowScope(
            host: host,
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(find.byType(PosterCard)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PosterCard.playButtonKey(item.id)));
      await tester.pumpAndSettle();
      expect(host.current?.source?.account, account);
      expect(host.current?.itemId, item.id);
      expect(host.current?.libraryId, 'season-no-parent');
      expect(host.current?.autoResume, isTrue);
      await tester.tapAt(
        tester.getTopLeft(find.byType(PosterCard)) + const Offset(12, 12),
      );
      await tester.pumpAndSettle();
      expect(find.text('source-detail-ready'), findsOneWidget);
      expect(
        (router.state.extra as PlayerHostOpenItemCommand).libraryId,
        'season-no-parent',
      );
      expect(auth.session?.server.id, 'a');
      await host.close();
      await pointer.moveTo(tester.getCenter(find.byType(PosterCard)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PosterCard.playButtonKey(item.id)));
      await tester.pumpAndSettle();
      expect(host.current?.source?.account, account);
      expect(host.current?.libraryId, 'season-no-parent');
      expect(
        transport.requests.where(
          (r) => r.uri.host == 'a' && r.path.endsWith('/Items/${item.id}'),
        ),
        isEmpty,
      );
      await pointer.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      host.dispose();
      auth.dispose();
    },
  );
  testWidgets(
    'private B gate keeps poster and chapters off disk and evicts only B on lock',
    (tester) async {
      final cache = MediaImageCache.instance;
      final disk = _ImageDisk();
      cache.clearMemory();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      cache.debugSetDiskStore(disk);
      addTearDown(() {
        cache.clearMemory();
        cache.debugSetDiskStore(null);
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      });
      final transport = _Transport();
      EmbyClient client() => EmbyClient(
        device: const EmbyDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'private-images',
          version: '1',
        ),
        dio: Dio()..httpClientAdapter = transport,
      );
      final access = RegionAccessController();
      await tester.runAsync(() async {
        await access.setPin('1234', '1234', (_) async {});
        expect(await access.unlock('1234'), isTrue);
      });
      final store = MemoryServerListStore(
        ServerListSnapshot(
          lastServerId: 'a',
          servers: [
            for (final server in ['a', 'b'])
              SavedServer(
                id: server,
                name: server,
                username: 'synthetic',
                region: server == 'b'
                    ? AccessRegion.private
                    : AccessRegion.ordinary,
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
        access: access,
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
      final permit = registry.permit(b, libraryId: 'library');
      late BuildContext detailContext;
      final showLatePoster = ValueNotifier(false);
      addTearDown(showLatePoster.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AuthScope(
            controller: auth,
            child: SourceDetailGate(
              auth: auth,
              itemId: 'movie',
              command: PlayerHostOpenItemCommand(
                itemId: 'movie',
                source: SourceReference(account: b, itemId: 'movie'),
                libraryId: 'library',
                regionGeneration: permit.regionGeneration,
              ),
              child: Builder(
                builder: (context) {
                  detailContext = context;
                  return Column(
                    children: [
                      const MediaImage(
                        item: EmbyItem(
                          id: 'movie',
                          name: 'private poster',
                          type: 'Movie',
                          primaryImageTag: 'poster',
                        ),
                        width: 100,
                        height: 100,
                        maxWidth: 100,
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: showLatePoster,
                        builder: (_, show, _) => show
                            ? const MediaImage(
                                item: EmbyItem(
                                  id: 'late-poster',
                                  name: 'late private poster',
                                  type: 'Movie',
                                  primaryImageTag: 'late',
                                ),
                                width: 100,
                                height: 100,
                                maxWidth: 100,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DetailSourceScope), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      final chapter = (await tester.runAsync(
        () => loadChapterImage(
          detailContext,
          itemId: 'movie',
          index: 0,
          tag: 'chapter',
        ),
      ))!;
      // Populate Flutter's chapter decode cache just as Image.memory consumers do.
      await tester.runAsync(
        () => precacheImage(MemoryImage(chapter), detailContext),
      );
      await tester.pumpAndSettle();
      expect(
        disk.reads,
        isEmpty,
        reason: 'private probes and load must never read disk',
      );
      expect(
        disk.writes,
        isEmpty,
        reason: 'private posters and chapters must never write disk',
      );
      final scope = jsonEncode([
        b.region.name,
        b.configuredServerId,
        b.verifiedServerId,
        b.userId,
        'library',
        permit.regionGeneration,
        permit.sessionRevision,
        permit.scopeRevision,
        tester
            .widget<DetailSourceScope>(find.byType(DetailSourceScope))
            .origin
            .client
            .baseUrl
            .toString(),
      ]);
      expect(
        cache.peek(
          serverId: scope,
          itemId: 'movie',
          type: 'Chapter',
          variant: '0',
          tag: 'chapter',
          maxWidth: 160,
        ),
        same(chapter),
      );
      final ordinary = Uint8List.fromList(chapter);
      await tester.runAsync(() async {
        await cache.load(
          serverId: 'ordinary-A',
          itemId: 'movie',
          type: 'Primary',
          maxWidth: 100,
          fetch: () async => ordinary,
        );
        await precacheImage(MemoryImage(ordinary), detailContext);
      });
      final ordinaryWrites = disk.writes.length;
      final ordinaryReads = disk.reads.length;
      transport.imageBarrier = Completer<void>();
      showLatePoster.value = true;
      await tester.pumpAndSettle();
      // The new poster needs a post-layout turn before its real async transport.
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      final lateChapters = <Future<Uint8List?>>[];
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (var index = 1; index <= 9; index++) {
          lateChapters.add(
            loadChapterImage(
              detailContext,
              itemId: 'movie',
              index: index,
              tag: 'late',
            ),
          );
        }
      });
      // Pump both the widget zone and real transport until dispatch, rather
      // than assuming the Windows runner completes it within 20 ms.
      for (var frame = 0; frame < 100; frame++) {
        if (transport.requests.any(
          (r) => r.uri.path.endsWith('/Images/Chapter/1'),
        )) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(
        transport.requests.where(
          (r) => r.uri.path.contains('/Items/late-poster/Images/'),
        ),
        isNotEmpty,
      );
      expect(
        transport.requests.where(
          (r) => r.uri.path.endsWith('/Images/Chapter/9'),
        ),
        isEmpty,
        reason: 'request is queued behind the eight network slots',
      );
      final dispatchedBeforeLock = transport.requests.length;
      expect(
        transport.requests.where(
          (r) => r.uri.host == 'b' && r.uri.path.contains('/Images/Chapter/1'),
        ),
        isNotEmpty,
      );
      await access.lock();
      await tester.pumpAndSettle();
      expect(find.byType(DetailSourceScope), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(
        cache.peek(
          serverId: scope,
          itemId: 'movie',
          type: 'Chapter',
          variant: '0',
          tag: 'chapter',
          maxWidth: 160,
        ),
        isNull,
      );
      expect(
        PaintingBinding.instance.imageCache.containsKey(MemoryImage(chapter)),
        isFalse,
      );
      expect(
        PaintingBinding.instance.imageCache.containsKey(MemoryImage(ordinary)),
        isTrue,
      );
      expect(
        cache.peek(
          serverId: 'ordinary-A',
          itemId: 'movie',
          type: 'Primary',
          maxWidth: 100,
        ),
        same(ordinary),
      );
      expect(
        PaintingBinding.instance.imageCache.currentSize,
        1,
        reason: 'only the ordinary decoded image survives',
      );
      expect(
        cache.peek(
          serverId: scope,
          itemId: 'movie',
          type: 'Primary',
          tag: 'poster',
          maxWidth: 100,
        ),
        isNull,
      );
      transport.imageBarrier!.complete();
      expect(
        await tester.runAsync(() => Future.wait(lateChapters)),
        everyElement(isNull),
      );
      await tester.pumpAndSettle();
      expect(disk.writes.length, ordinaryWrites);
      expect(disk.reads.length, ordinaryReads);
      expect(
        transport.requests.length,
        dispatchedBeforeLock,
        reason:
            'revoked queued chapters never dispatch, and in-flight responses never retry',
      );
      expect(
        cache.peek(
          serverId: scope,
          itemId: 'late-poster',
          type: 'Primary',
          tag: 'late',
          maxWidth: 100,
        ),
        isNull,
      );
      expect(
        cache.peek(
          serverId: scope,
          itemId: 'movie',
          type: 'Chapter',
          variant: '1',
          tag: 'late',
          maxWidth: 160,
        ),
        isNull,
      );
      expect(auth.session!.server.id, 'a');
      await tester.pumpWidget(const SizedBox.shrink());
      auth.dispose();
    },
    tags: ['integration'],
  );

  for (final environment in [
    PresentationEnvironment.desktop,
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    for (final id in ['same-id', 'different-b-id', 'episode-no-parent']) {
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
          if (environment.isDesktop && id != 'episode-no-parent') {
            final similarShelf = tester.widget<MediaShelf>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is MediaShelf &&
                    widget.shelfId == CatalogKeys.shelfSimilar,
              ),
            );
            expect(similarShelf.onMore, isNull);
          } else if (!environment.isTv && id != 'episode-no-parent') {
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

  testWidgets(
    'source detail keeps showComparison off across a related item and shows it without the query',
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
      final account = (await tester.runAsync(
        () => registry.authenticate('b'),
      ))!.account;
      final auth = AuthController(
        client: client(),
        credentials: credentials,
        servers: store,
        sources: registry,
      );
      await tester.runAsync(auth.restore);
      final router = createAppRouter(
        auth: auth,
        environment: PresentationEnvironment.desktop,
      );
      await tester.pumpWidget(
        RillightApp(
          auth: auth,
          router: router,
          environment: PresentationEnvironment.desktop,
        ),
      );
      await tester.pumpAndSettle();
      final permit = registry.permit(account, libraryId: 'library');
      PlayerHostOpenItemCommand commandFor(String itemId) =>
          PlayerHostOpenItemCommand(
            itemId: itemId,
            source: SourceReference(account: account, itemId: itemId),
            libraryId: 'library',
            regionGeneration: permit.regionGeneration,
          );
      router.go(
        AppRoutes.item('movie', showComparison: false),
        extra: commandFor('movie'),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('查找同源'), findsNothing);
      expect(
        tester
            .widget<SourceDetailGate>(find.byType(SourceDetailGate))
            .showComparison,
        isFalse,
      );
      final similar = find.byKey(CatalogKeys.item('similar'));
      await tester.ensureVisible(similar);
      await tester.pump();
      await tester.tap(similar);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/item/similar');
      expect(router.state.uri.queryParameters['showComparison'], '0');
      expect(find.text('查找同源'), findsNothing);
      expect(
        tester
            .widgetList<SourceDetailGate>(find.byType(SourceDetailGate))
            .last
            .showComparison,
        isFalse,
      );
      router.go(AppRoutes.item('movie'), extra: commandFor('movie'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(
        router.state.uri.queryParameters.containsKey('showComparison'),
        isFalse,
      );
      expect(find.text('查找同源'), findsOneWidget);
      expect(
        tester
            .widget<SourceDetailGate>(find.byType(SourceDetailGate))
            .showComparison,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      auth.dispose();
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
