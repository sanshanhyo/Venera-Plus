import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_shell/home_page.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_controller.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_view.dart';
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
    expect(find.text('original_chapter9.pdf'), findsOneWidget);
    expect(find.text('original_chapter8.pdf'), findsOneWidget);
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
          .widget<OutlinedButton>(find.byKey(const Key('cloud-home-next')))
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
    expect(find.text('original_chapter9.pdf'), findsOneWidget);
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
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(controller.directory, '/Comic/Folder0/');
    expect(find.text('Unsupported file'), findsOneWidget);
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
}

Future<void> _show(
  WidgetTester tester,
  _BrowserController controller, {
  bool active = true,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 640);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(360, 640),
          padding: const EdgeInsets.only(bottom: 24),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: CloudHomeView(controller: controller, isActive: active),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
}

class _BrowserController extends CloudHomeController {
  String current = '/Comic/';
  final preloads = <({int start, int count})>[];
  final overrides = <String, CloudHomeDirectoryOverride>{};
  Completer<void>? gate;

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
  List<CloudHomeItem> get items => current == '/Comic/'
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
        ];

  @override
  Future<void> preload({required int start, required int count}) async {
    preloads.add((start: start, count: count));
    await gate?.future;
  }

  @override
  Future<void> openDirectory(String path) async {
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
