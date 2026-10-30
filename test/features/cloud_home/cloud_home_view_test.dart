import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_shell/home_page.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_controller.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_view.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_settings_view.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  setUp(() {
    final previous = appdata.settings['homeCloudVolumeKeys'];
    final language = appdata.settings['language'];
    appdata.settings['homeCloudVolumeKeys'] = false;
    appdata.settings['language'] = 'en-US';
    addTearDown(() {
      appdata.settings['homeCloudVolumeKeys'] = previous;
      appdata.settings['language'] = language;
    });
  });

  testWidgets('one screen does not scroll and preloads the following screen', (
    tester,
  ) async {
    final controller = _BrowserController();
    await _show(tester, controller);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.physics, isA<NeverScrollableScrollPhysics>());
    final visibleCount =
        (grid.childrenDelegate as SliverChildBuilderDelegate).childCount!;
    expect(visibleCount, lessThan(controller.items.length));
    expect(controller.preloads.last, (start: 0, count: visibleCount * 2));
    expect(
      find.byKey(const ValueKey('cloud-entry-/Comic/Folder0/')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('cloud-home-next')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cloud-entry-/Comic/Folder0/')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('cloud-entry-/Comic/Folder$visibleCount/')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning to a parent restores its screen', (tester) async {
    final controller = _BrowserController();
    await _show(tester, controller);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final capacity =
        (grid.childrenDelegate as SliverChildBuilderDelegate).childCount!;
    await tester.tap(find.byKey(const Key('cloud-home-next')));
    await tester.pumpAndSettle();
    final page = tester
        .widget<Text>(find.byKey(const Key('cloud-home-page-number')))
        .data;
    await tester.tap(find.text('Folder$capacity'));
    await tester.pumpAndSettle();
    expect(find.text('original_chapter9'), findsOneWidget);
    expect(find.text('original_chapter8'), findsOneWidget);
    expect(find.text('Read Chapter'), findsNothing);
    await tester.tap(find.byKey(const Key('cloud-home-parent')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('cloud-home-page-number'))).data,
      page,
    );
    expect(find.text('Folder$capacity'), findsOneWidget);
  });

  testWidgets('slow preloads do not block paging or folder navigation', (
    tester,
  ) async {
    final controller = _BrowserController();
    await _show(tester, controller);
    final gate = Completer<void>();
    controller.gate = gate;
    await tester.tap(find.byKey(const Key('cloud-home-next')));
    await tester.tap(find.byKey(const Key('cloud-home-next')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('cloud-home-next')))
          .onPressed,
      isNotNull,
    );
    final waitingPage = tester
        .widget<Text>(find.byKey(const Key('cloud-home-page-number')))
        .data!;
    expect(waitingPage.startsWith('2 /'), isTrue);
    final firstVisible = find
        .byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data?.startsWith('Folder') == true,
        )
        .first;
    await tester.tap(firstVisible);
    await tester.pumpAndSettle();
    expect(find.text('original_chapter9'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('hidden home does not preload and recognition is overridable', (
    tester,
  ) async {
    final controller = _BrowserController();
    await _show(tester, controller, active: false);
    expect(controller.preloads, isEmpty);
    await tester.longPress(find.text('Folder0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Treat as folder'));
    await tester.pumpAndSettle();
    expect(
      controller.overrides['/Comic/Folder0/'],
      CloudHomeDirectoryOverride.folder,
    );
  });

  testWidgets('unsupported files do not open the reader', (tester) async {
    final controller = _BrowserController()..current = '/Comic/Folder0/';
    await _show(tester, controller);
    await tester.tap(find.text('notes'));
    await tester.pumpAndSettle();
    expect(controller.directory, '/Comic/Folder0/');
    expect(find.text('TXT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing screen size keeps the current first entry visible', (
    tester,
  ) async {
    final controller = _BrowserController();
    await _show(tester, controller);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final capacity =
        (grid.childrenDelegate as SliverChildBuilderDelegate).childCount!;
    await tester.tap(find.byKey(const Key('cloud-home-next')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(800, 480);
    await tester.pumpAndSettle();
    expect(find.text('Folder$capacity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('screen pagination fits a small display at text scale $scale', (
      tester,
    ) async {
      final controller = _BrowserController();
      await _show(tester, controller, scale: scale);
      expect(tester.takeException(), isNull);
      final footer = tester.getRect(find.byKey(const Key('cloud-home-next')));
      expect(footer.bottom, lessThanOrEqualTo(640));
      final visibleEntries = find.byWidgetPredicate(
        (widget) =>
            widget is Material &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('cloud-entry-'),
      );
      for (final element in visibleEntries.evaluate()) {
        final box = element.renderObject! as RenderBox;
        expect(
          box.localToGlobal(Offset.zero).dy + box.size.height,
          lessThanOrEqualTo(footer.top + 1),
        );
      }
    });
  }

  testWidgets(
    'landscape Home with shell bars and large text uses a compact pager',
    (tester) async {
      final previousView = appdata.settings['homeView'];
      appdata.settings['homeView'] = 'cloud';
      addTearDown(() => appdata.settings['homeView'] = previousView);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 360);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _BrowserController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(title: const Text('Home')),
            body: HomePage(cloudController: controller),
            bottomNavigationBar: NavigationBar(
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.book), label: 'Library'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cloud-home-next')), findsOneWidget);
      expect(
        tester.widget<GridView>(find.byType(GridView)).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      final next = tester.getRect(find.byKey(const Key('cloud-home-next')));
      final bottomBar = tester.getRect(find.byType(NavigationBar));
      expect(next.bottom, lessThanOrEqualTo(bottomBar.top));
      await tester.tap(find.byKey(const Key('cloud-home-next')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('cloud-entry-/Comic/Folder0/')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('bookshelf has multiple frameless covers with titles below', (
    tester,
  ) async {
    final controller = _BrowserController();
    await _show(tester, controller);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, greaterThanOrEqualTo(2));
    expect(delegate.mainAxisExtent!, lessThan(300));
    final first = find.byKey(const ValueKey('cloud-entry-/Comic/Folder0/'));
    final card = tester.widget<Material>(first);
    expect(card.color, Colors.transparent);
    expect(card.shape, isNull);
    expect(
      find.descendant(of: first, matching: find.byIcon(Icons.more_vert)),
      findsNothing,
    );
    final cover = tester.getRect(
      find.byKey(const ValueKey('cloud-cover-/Comic/Folder0/')),
    );
    final title = tester.getRect(
      find.byKey(const ValueKey('cloud-title-/Comic/Folder0/')),
    );
    final type = tester.getRect(
      find.byKey(const ValueKey('cloud-type-/Comic/Folder0/')),
    );
    expect(cover.width / cover.height, closeTo(.75, .001));
    expect(title.top, greaterThan(cover.bottom));
    expect(type.top, greaterThan(title.bottom));
    expect(
      find.descendant(of: first, matching: find.text('Folder')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('slightly short shelf keeps a second row by trimming covers', (
    tester,
  ) async {
    final controller = _BrowserController();
    await _show(tester, controller, size: const Size(600, 600));
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 4);
    expect((grid.childrenDelegate as SliverChildBuilderDelegate).childCount, 8);
    final cover = tester.getSize(
      find.byKey(const ValueKey('cloud-cover-/Comic/Folder0/')),
    );
    expect(cover.width / cover.height, closeTo(.75, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'PDF collections open comic details instead of directory navigation',
    (tester) async {
      final controller = _BrowserController()
        ..customItems = const [
          CloudHomeItem(
            entry: RemoteEntry(
              name: 'Paper Garden',
              path: '/Comic/Paper Garden/',
              isDirectory: true,
            ),
            kind: CloudHomeItemKind.pdfCollection,
            fileCount: 3,
          ),
        ];
      (CloudHomeItem, String)? opened;
      await _show(
        tester,
        controller,
        onOpenComic: (item, id) => opened = (item, id),
      );
      await tester.tap(find.text('Paper Garden'));
      await tester.pumpAndSettle();
      expect(opened?.$1.kind, CloudHomeItemKind.pdfCollection);
      expect(opened?.$2, 'canonical:/Comic/Paper Garden/');
      expect(controller.directory, '/Comic/');
      expect(controller.openedDirectories, isEmpty);
      expect(find.text('PDF'), findsOneWidget);
      expect(find.textContaining('3 files'), findsNothing);
    },
  );

  testWidgets(
    'quick tap recognizes an uncached PDF collection before navigation',
    (tester) async {
      final controller = _BrowserController()
        ..resolvedKind = CloudHomeItemKind.pdfCollection;
      String? opened;
      await _show(tester, controller, onOpenComic: (_, id) => opened = id);
      await tester.tap(find.text('Folder0'));
      await tester.pumpAndSettle();
      expect(opened, 'canonical:/Comic/Folder0/');
      expect(controller.openedDirectories, isEmpty);
      expect(controller.directory, '/Comic/');
    },
  );

  testWidgets('changing directory discards an obsolete recognition result', (
    tester,
  ) async {
    final gate = Completer<CloudHomeItem?>();
    final controller = _BrowserController()..resolveGate = gate;
    var opened = false;
    await _show(tester, controller, onOpenComic: (_, id) => opened = true);
    await tester.tap(find.text('Folder0'));
    await tester.pump();
    controller.current = '/Comic/Elsewhere/';
    controller.notifyListeners();
    gate.complete(
      const CloudHomeItem(
        entry: RemoteEntry(
          name: 'Folder0',
          path: '/Comic/Folder0/',
          isDirectory: true,
        ),
        kind: CloudHomeItemKind.pdfCollection,
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(controller.openedDirectories, isEmpty);
  });

  testWidgets('hidden and restored Home does not open a pending old item', (
    tester,
  ) async {
    final gate = Completer<CloudHomeItem?>();
    final controller = _BrowserController()..resolveGate = gate;
    final active = ValueNotifier(true);
    addTearDown(controller.dispose);
    addTearDown(active.dispose);
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, visible, _) => CloudHomeView(
              controller: controller,
              isActive: visible,
              onOpenComic: (_, id) => opened = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folder0'));
    await tester.pump();
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump();
    gate.complete(
      const CloudHomeItem(
        entry: RemoteEntry(
          name: 'Folder0',
          path: '/Comic/Folder0/',
          isDirectory: true,
        ),
        kind: CloudHomeItemKind.pdfCollection,
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(controller.openedDirectories, isEmpty);
  });

  testWidgets(
    'Home settings select imported libraries without selecting accounts again',
    (tester) async {
      final controller = _BrowserController()
        ..availableLibraries = const [
          _demoLibrary,
          RemoteLibrary(
            id: 'second',
            sourceKey: 'second-source',
            accountId: 'different-account',
            directories: ['/Books/', '/Magazine/'],
            name: 'Second library',
          ),
        ];
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showCloudHomeSettings(context, controller: controller),
                child: const Text('Configure'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Configure'));
      await tester.pumpAndSettle();
      expect(find.text('Comic Library'), findsOneWidget);
      expect(find.text('Comic library home'), findsOneWidget);
      expect(find.text('Cloud Storage Account'), findsNothing);
      expect(find.text('Add Cloud Storage Account'), findsNothing);
      await tester.tap(find.byKey(const Key('cloud-home-library')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second library').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cloud-home-start-directory')));
      await tester.pumpAndSettle();
      expect(controller.directoryQueries, [
        (libraryId: 'second', directory: null),
      ]);
      expect(find.text('Books'), findsOneWidget);
      expect(find.text('Magazine'), findsOneWidget);
      expect(find.text('Server root'), findsNothing);
      await tester.tap(find.byKey(const Key('cloud-home-select-start-page')));
      await tester.pumpAndSettle();
      expect(find.text('Comic library home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unmounted Home guides to imported libraries', (tester) async {
    final controller = _BrowserController()..mounted = false;
    await _show(tester, controller);
    expect(find.text('Choose an imported comic library'), findsOneWidget);
    expect(find.text('Select a cloud folder'), findsNothing);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets(
    'writes synthetic bookshelf previews for CI visual review',
    (tester) async {
      final output = Platform.environment['CLOUD_HOME_CAPTURE_DIR']!;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previousView = appdata.settings['homeView'];
      appdata.settings['homeView'] = 'cloud';
      addTearDown(() => appdata.settings['homeView'] = previousView);
      final scratch = Directory.systemTemp.createTempSync(
        'cloud-bookshelf-preview-',
      );
      addTearDown(() async => scratch.delete(recursive: true));
      late List<String> covers;
      await tester.runAsync(() async {
        await _loadPreviewFont();
        covers = await _writeSyntheticCovers(scratch);
      });
      final controller = _BrowserController()
        ..customItems = [
          for (var i = 0; i < 24; i++)
            CloudHomeItem(
              entry: RemoteEntry(
                name: _previewTitles[i % _previewTitles.length],
                path: '/Comic/Book$i/',
                isDirectory: true,
              ),
              kind: i % 4 == 0
                  ? CloudHomeItemKind.directory
                  : CloudHomeItemKind.pdfCollection,
              cover: 'file://${covers[i % covers.length]}',
            ),
        ];
      addTearDown(controller.dispose);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final imageContext = tester.element(find.byType(SizedBox).first);
      await tester.runAsync(() async {
        for (final item in controller.items) {
          await precacheImage(
            CachedImageProvider(
              item.cover!,
              sourceKey: controller.sourceKey,
              cid: controller.comicIdFor(item.path),
            ),
            imageContext,
          );
        }
      });
      for (final configuration in [
        (
          size: const Size(360, 720),
          scale: 1.0,
          name: 'cloud-bookshelf-360.png',
        ),
        (
          size: const Size(600, 960),
          scale: 1.0,
          name: 'cloud-bookshelf-600.png',
        ),
        (
          size: const Size(640, 360),
          scale: 2.0,
          name: 'cloud-bookshelf-landscape-large.png',
        ),
      ]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = configuration.size;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: 'BookshelfPreview',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff466a64),
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(configuration.scale)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(
                appBar: AppBar(title: const Text('Home')),
                body: HomePage(cloudController: controller),
                bottomNavigationBar: NavigationBar(
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_books_outlined),
                      label: 'Library',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(output)..createSync(recursive: true);
          await File(
            '${directory.path}/${configuration.name}',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
    skip: Platform.environment['CLOUD_HOME_CAPTURE_DIR'] == null,
  );
}

const _previewTitles = [
  'Sky Atlas',
  'Paper Garden',
  'Night Train',
  'Quiet Harbor',
  'Blue Orbit',
  'Morning Light',
];

Future<void> _loadPreviewFont() async {
  final flutter = Platform.environment['FLUTTER_ROOT'];
  final candidates = [
    if (flutter != null)
      '$flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
    if (flutter != null)
      '$flutter/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ];
  final file = candidates
      .map(File.new)
      .where((file) => file.existsSync())
      .firstOrNull;
  if (file == null) throw StateError('No CI preview typeface is available');
  final loader = FontLoader('BookshelfPreview')
    ..addFont(Future.value(ByteData.sublistView(await file.readAsBytes())));
  await loader.load();
}

Future<List<String>> _writeSyntheticCovers(Directory directory) async {
  const palette = [
    Color(0xff8ab9ab),
    Color(0xffe7c680),
    Color(0xffb3c5d3),
    Color(0xffbf8c7e),
    Color(0xff778fa4),
    Color(0xffd9d0b7),
  ];
  final paths = <String>[];
  for (var i = 0; i < palette.length; i++) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 240, 320),
      Paint()..color = palette[i],
    );
    canvas.drawCircle(
      Offset(155, 183 + i * 5),
      66,
      Paint()..color = const Color(0xfff7ead5).withValues(alpha: .75),
    );
    canvas.drawRect(
      Rect.fromLTWH(31 + i * 4, 152, 49, 168),
      Paint()..color = const Color(0xff244e4c).withValues(alpha: .75),
    );
    canvas.drawRect(
      Rect.fromLTWH(100 + i * 3, 222, 31, 98),
      Paint()..color = const Color(0xff244e4c).withValues(alpha: .55),
    );
    final title = TextPainter(
      text: TextSpan(
        text: _previewTitles[i].toUpperCase().replaceFirst(' ', '\n'),
        style: const TextStyle(
          fontFamily: 'BookshelfPreview',
          color: Color(0xff172d2b),
          fontSize: 34,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 218);
    title.paint(canvas, const Offset(15, 17));
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 320);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${directory.path}/cover-$i.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    paths.add(file.path);
  }
  return paths;
}

Future<void> _show(
  WidgetTester tester,
  _BrowserController controller, {
  bool active = true,
  double scale = 1,
  Size size = const Size(360, 640),
  void Function(CloudHomeItem item, String comicId)? onOpenComic,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.only(bottom: 24),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: CloudHomeView(
            controller: controller,
            isActive: active,
            onOpenComic: onOpenComic,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
}

const _demoLibrary = RemoteLibrary(
  id: 'demo',
  sourceKey: 'test-cloud-home',
  accountId: 'test',
  directories: ['/Comic/'],
  name: 'Demo library',
);

class _BrowserController extends CloudHomeController {
  bool mounted = true;
  List<RemoteLibrary> availableLibraries = const [_demoLibrary];
  List<CloudHomeItem>? customItems;
  final openedDirectories = <String>[];
  final directoryQueries = <({String libraryId, String? directory})>[];

  @override
  List<RemoteLibrary> get libraries => availableLibraries;
  @override
  RemoteLibrary? get mountedLibrary =>
      mounted ? availableLibraries.first : null;
  @override
  CloudHomeLibraryMount? get mount =>
      mounted ? const CloudHomeLibraryMount(libraryId: 'demo') : null;
  @override
  bool get isVirtualLibraryRoot => current.isEmpty;
  @override
  String comicIdFor(String absolutePath) => 'canonical:$absolutePath';
  @override
  Future<List<RemoteEntry>> listLibraryDirectories(
    String libraryId, {
    String? directory,
  }) async {
    directoryQueries.add((libraryId: libraryId, directory: directory));
    final library = availableLibraries.firstWhere(
      (library) => library.id == libraryId,
    );
    return [
      for (final root in library.directories)
        RemoteEntry(
          name: root.split('/').where((part) => part.isNotEmpty).last,
          path: root,
          isDirectory: true,
        ),
    ];
  }

  String current = '/Comic/';
  final preloads = <({int start, int count})>[];
  final overrides = <String, CloudHomeDirectoryOverride>{};
  Completer<void>? gate;
  Completer<CloudHomeItem?>? resolveGate;
  CloudHomeItemKind? resolvedKind;

  @override
  Future<CloudHomeItem?> resolveItemForOpen(CloudHomeItem item) async =>
      resolveGate != null
      ? await resolveGate!.future
      : item.copyWith(kind: resolvedKind);

  @override
  Future<void> initialize() async {}

  @override
  RemoteLocation get location =>
      const RemoteLocation(accountId: 'test', directory: '/Comic/');
  @override
  String get directory => current;
  @override
  String get sourceKey => 'test-cloud-home';
  @override
  bool get canGoUp => current != '/Comic/';
  @override
  bool get isLoading => false;
  @override
  bool get isRefreshing => false;
  @override
  String? get error => null;
  @override
  List<CloudHomeItem> get items =>
      customItems ??
      (current == '/Comic/'
          ? List.generate(
              30,
              (i) => CloudHomeItem(
                entry: RemoteEntry(
                  name: 'Folder$i',
                  path: '/Comic/Folder$i/',
                  isDirectory: true,
                ),
                kind: CloudHomeItemKind.directory,
              ),
            )
          : [
              for (final name in [
                'original_chapter9.pdf',
                'original_chapter8.pdf',
                'notes.txt',
              ])
                CloudHomeItem(
                  entry: RemoteEntry(
                    name: name,
                    path: '$current$name',
                    isDirectory: false,
                  ),
                  kind: name.endsWith('.pdf')
                      ? CloudHomeItemKind.comicFile
                      : CloudHomeItemKind.unsupported,
                ),
            ]);

  @override
  Future<void> preload({required int start, required int count}) async {
    preloads.add((start: start, count: count));
    await gate?.future;
  }

  @override
  Future<void> openDirectory(String path) async {
    openedDirectories.add(path);
    current = path;
    notifyListeners();
  }

  @override
  Future<void> goUp() => openDirectory('/Comic/');
  @override
  Future<void> refresh() async => notifyListeners();
  @override
  CloudHomeDirectoryOverride directoryOverride(String path) =>
      overrides[path] ?? CloudHomeDirectoryOverride.automatic;
  @override
  Future<void> setDirectoryOverride(
    String path,
    CloudHomeDirectoryOverride value,
  ) async {
    overrides[path] = value;
    notifyListeners();
  }
}
