import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:venera_plus/app_runtime/init.dart';
import 'package:venera_plus/app_shell/library_page.dart';
import 'package:venera_plus/app_shell/main_page.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_panel.dart';
import 'package:venera_plus/features/metadata/metadata_providers.dart';
import 'package:venera_plus/features/metadata/metadata_service.dart';
import 'package:venera_plus/features/metadata/metadata_store.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/main.dart';
import 'package:venera_plus/network/cookie_jar.dart';

import '../fixtures/metadata_smoke_fixtures.dart';

void main() {
  if (!const bool.fromEnvironment('CI_NATIVE_SMOKE')) {
    throw StateError(
      'Metadata UI smoke requires --dart-define=CI_NATIVE_SMOKE=true '
      'on a disposable Android emulator.',
    );
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real app metadata menus, providers, SQLite, cover policy and restoration',
    (tester) async {
      final screenshots = <String, String>{};
      final completedScenes = <String>[];
      final report = <String, dynamic>{
        'fixture': 'synthetic-metadata-and-generated-non-adult-covers',
        'liveNetwork': false,
        'passed': false,
        'requiredScreenshots': metadataSmokeRequiredScreenshots,
        'completedScenes': completedScenes,
        'screenshots': screenshots,
      };
      binding.reportData = {'metadataSmoke': report};
      final repaintKey = GlobalKey();
      final frameworkOnError = FlutterError.onError;
      final frameworkErrorBuilder = ErrorWidget.builder;
      final adapter = MetadataSmokeAdapter();
      String currentScene = 'startup';

      Future<void> settle() => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );

      Future<void> capture(String name, {bool checkErrors = true}) async {
        await tester.pump(const Duration(milliseconds: 250));
        if (checkErrors) expect(tester.takeException(), isNull);
        final boundary = repaintKey.currentContext?.findRenderObject();
        if (boundary is! RenderRepaintBoundary) {
          throw StateError('The real application has no screenshot boundary.');
        }
        final frame = await boundary.toImage(pixelRatio: 1.5);
        try {
          final png = await frame.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) throw StateError('Screenshot encoding failed.');
          screenshots[name] = base64Encode(png.buffer.asUint8List());
          if (metadataSmokeRequiredScreenshots.contains(name)) {
            completedScenes.add(name);
          }
        } finally {
          frame.dispose();
        }
      }

      Future<void> tapKey(String name) async {
        final finder = find.byKey(Key(name));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await settle();
      }

      Future<void> clearSelection() async {
        final cancel = find
            .descendant(
              of: find.byType(LocalComicsPage),
              matching: find.byIcon(Icons.close),
            )
            .hitTestable();
        if (cancel.evaluate().isNotEmpty) {
          await tester.tap(cancel.first);
          await settle();
        }
      }

      Future<void> openPanel({bool captureMenu = false}) async {
        await clearSelection();
        final tile = find
            .descendant(
              of: find.byType(LocalComicsPage),
              matching: find.byType(ComicTile),
            )
            .hitTestable();
        expect(tile, findsOneWidget);
        await tester.longPress(tile);
        await settle();
        final menu = find
            .descendant(
              of: find.byType(LocalComicsPage),
              matching: find.byType(MenuButton),
            )
            .hitTestable();
        expect(menu, findsOneWidget);
        await tester.tap(menu);
        await settle();
        final entry = find.text('Complete information'.tl).hitTestable();
        expect(entry, findsOneWidget);
        if (captureMenu) await capture('01_local_menu');
        await tester.tap(entry);
        await settle();
        expect(find.byType(MetadataPanel), findsOneWidget);
      }

      Future<void> closePanel() async {
        final back = find.descendant(
          of: find.byType(MetadataPanel),
          matching: find.byIcon(Icons.arrow_back_sharp),
        );
        await tester.tap(back);
        await settle();
        expect(find.byType(MetadataPanel), findsNothing);
        await clearSelection();
      }

      try {
        // A full production initialization on a fresh disposable CI install.
        // Restoring the framework handler ensures runtime/layout errors fail CI.
        try {
          await init(deferBackgroundTasks: true);
        } finally {
          FlutterError.onError = frameworkOnError;
        }
        appdata.settings['language'] = 'zh-CN';
        appdata.settings['theme_mode'] = 'light';
        appdata.settings['checkUpdateOnStart'] = false;
        appdata.settings['authorizationRequired'] = false;
        appdata.settings['initialPage'] = 'home';
        appdata.implicitData['lastCheckUpdate'] =
            DateTime.now().millisecondsSinceEpoch;

        final fixtureDirectory = Directory(
          '${LocalManager().path}/metadata_smoke_fixture',
        )..createSync(recursive: true);
        File(
          '${fixtureDirectory.path}/cover.png',
        ).writeAsBytesSync(adapter.ehCover);
        File(
          '${fixtureDirectory.path}/001.png',
        ).writeAsBytesSync(adapter.ehCover);
        await LocalManager().add(
          LocalComic(
            id: smokeComicId,
            title: smokeOriginalTitle,
            subtitle: '原始作者（示例）',
            tags: const ['旅行', '示例'],
            directory: fixtureDirectory.path,
            chapters: null,
            cover: 'cover.png',
            comicType: ComicType.local,
            downloadedChapters: [],
            createdAt: DateTime.utc(2026, 10, 30),
          ),
        );
        await HistoryManager().addHistoryAsync(
          History.fromMap({
            'type': ComicType.local.value,
            'id': smokeComicId,
            'title': smokeOriginalTitle,
            'subtitle': '原始作者（示例）',
            'cover': '',
            'time': DateTime.now().millisecondsSinceEpoch,
            'ep': 1,
            'page': 7,
            'max_page': 24,
            'readEpisode': <String>[],
            'read_duration_ms': 0,
          }),
        );
        await HistoryManager().waitForAsyncWrites();

        Dio fixtureDio() => Dio()..httpClientAdapter = adapter;
        MetadataProviders gateway(Uri base, Uri cover) => MetadataProviders(
          dio: fixtureDio(),
          jmBaseUri: base,
          jmCoverBaseUri: cover,
          requestInterval: Duration.zero,
        );
        final store = MetadataStore.app;
        final service = MetadataService.withDependencies(
          gateway: gateway(
            MetadataProviders.defaultJmBaseUri,
            MetadataProviders.defaultJmCoverBaseUri,
          ),
          store: store,
          coverDio: fixtureDio(),
          gatewayFactory: gateway,
        );
        MetadataService.installForTesting(service);

        await tester.pumpWidget(
          RepaintBoundary(key: repaintKey, child: const MyApp()),
        );
        await settle();
        expect(find.byType(MyApp), findsOneWidget);
        expect(find.byType(MainPage), findsOneWidget);
        expect(tester.takeException(), isNull);

        currentScene = 'local-library-navigation';
        final libraryNavigation = find
            .descendant(
              of: find.byType(MainPage),
              matching: find.byIcon(Icons.local_library_outlined),
            )
            .hitTestable();
        await tester.tap(libraryNavigation);
        await settle();
        final localTab = find.descendant(
          of: find.byType(LibraryPage),
          matching: find.text('Local Comics'.tl),
        );
        await tester.ensureVisible(localTab);
        await tester.tap(localTab);
        await settle();
        expect(find.byType(LocalComicsPage), findsOneWidget);
        expect(find.textContaining(smokeOriginalTitle), findsWidgets);

        currentScene = 'eh-preview';
        await openPanel(captureMenu: true);
        await tester.enterText(
          find.byKey(const Key('metadata-reference')),
          smokeEhReference,
        );
        await tapKey('metadata-fetch');
        expect(find.text(smokeEhTitle), findsOneWidget);
        expect(find.text('示例作者'), findsWidgets);
        expect(service.find('local', smokeComicId), isNull);
        await tester.ensureVisible(
          find.byKey(const Key('metadata-cache-cover')),
        );
        await settle();
        final off = tester.widget<SwitchListTile>(
          find.byKey(const Key('metadata-cache-cover')),
        );
        expect(off.value, isFalse);
        await capture('02_eh_preview_cache_off');
        await tapKey('metadata-cache-cover');
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('metadata-cache-cover')),
              )
              .value,
          isTrue,
        );
        await capture('03_eh_preview_cache_on');

        currentScene = 'eh-save-and-reopen';
        await tapKey('metadata-save');
        final ehBinding = service.find('local', smokeComicId)!;
        expect(ehBinding.result.title, smokeEhTitle);
        expect(ehBinding.coverPath, isNotNull);
        expect(store.coverFile(ehBinding.coverPath!).existsSync(), isTrue);
        final reopened = MetadataStore(
          databasePath: store.databasePath,
          coverDirectory: store.coverDirectory,
        );
        try {
          expect(
            reopened.find('local', smokeComicId)!.result.title,
            smokeEhTitle,
          );
        } finally {
          reopened.dispose();
        }
        await closePanel();
        expect(find.textContaining(smokeEhTitle), findsWidgets);
        await capture('04_eh_saved_local_list');

        currentScene = 'jm-config-and-preview';
        await openPanel();
        await tester.tap(find.byKey(const Key('metadata-provider')));
        await settle();
        await tester.tap(find.text('JMComic').last);
        await settle();
        await tapKey('metadata-jm-settings');
        await tester.enterText(
          find.byKey(const Key('metadata-jm-base-url')),
          smokeJmBaseUrl,
        );
        await tester.enterText(
          find.byKey(const Key('metadata-jm-cover-base-url')),
          smokeJmCoverBaseUrl,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await settle();
        await tester.ensureVisible(
          find.byKey(const Key('metadata-jm-base-url')),
        );
        await settle();
        await capture('05_jm_settings');
        final referenceInput = find.byKey(const Key('metadata-reference'));
        await tester.ensureVisible(referenceInput);
        await tester.enterText(referenceInput, smokeJmReference);
        await tapKey('metadata-fetch');
        expect(find.text(smokeJmTitle), findsOneWidget);
        expect(service.jmBaseUrl, smokeJmBaseUrl);
        expect(service.jmCoverBaseUrl, smokeJmCoverBaseUrl);
        await tapKey('metadata-jm-settings');
        await tester.ensureVisible(
          find.byKey(const Key('metadata-cache-cover')),
        );
        await settle();
        if (tester
            .widget<SwitchListTile>(
              find.byKey(const Key('metadata-cache-cover')),
            )
            .value) {
          await tapKey('metadata-cache-cover');
        }
        await capture('06_jm_preview_cache_off');

        currentScene = 'jm-save-without-cover-cache';
        await tapKey('metadata-save');
        final jmBinding = service.find('local', smokeComicId)!;
        expect(jmBinding.result.reference.provider, MetadataProviderId.jmcomic);
        expect(jmBinding.cacheCover, isFalse);
        expect(jmBinding.coverPath, isNull);
        expect(store.coverFile(ehBinding.coverPath!).existsSync(), isFalse);
        await closePanel();
        expect(find.textContaining(smokeJmTitle), findsWidgets);
        await capture('07_jm_saved_local_list');

        currentScene = 'remove-and-restore';
        await openPanel();
        await tapKey('metadata-remove');
        await tester.tap(find.text('Remove'.tl));
        await settle();
        expect(service.find('local', smokeComicId), isNull);
        await closePanel();
        expect(find.textContaining(smokeOriginalTitle), findsWidgets);
        final restored = LocalManager().find(smokeComicId, ComicType.local)!;
        expect(restored.id, smokeComicId);
        expect(restored.sourceKey, 'local');
        expect(restored.title, smokeOriginalTitle);
        expect(restored.subtitle, '原始作者（示例）');
        expect(restored.cover, 'cover.png');
        expect(HistoryManager().find(smokeComicId, ComicType.local)!.page, 7);
        expect(File('${fixtureDirectory.path}/001.png').existsSync(), isTrue);
        await capture('08_removed_restored');

        expect(completedScenes, metadataSmokeRequiredScreenshots);
        expect(tester.takeException(), isNull);
        report['passed'] = true;
        report['providerRequests'] = adapter.requests;
        report['sqlitePersistenceVerified'] = true;
        report['originalIdentityAndProgressPreserved'] = true;
      } catch (error, stack) {
        report['failedScene'] = currentScene;
        report['error'] = error.toString();
        report['stack'] = stack.toString();
        report['providerRequests'] = adapter.requests;
        try {
          await capture('99_failure', checkErrors: false);
        } catch (_) {
          // The host still receives earlier screenshots; CI also captures adb.
        }
        rethrow;
      } finally {
        FlutterError.onError = frameworkOnError;
        try {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        } finally {
          ErrorWidget.builder = frameworkErrorBuilder;
        }
        MetadataService.installForTesting(null);
        LocalManager.resetForTesting();
        MetadataStore.resetForTesting();
        await HistoryManager().waitForAsyncWrites();
        HistoryManager().close();
        await LocalFavoritesManager().waitForPendingReads();
        LocalFavoritesManager().close();
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
        await shutdownRemoteComicLibraryRuntime();
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
