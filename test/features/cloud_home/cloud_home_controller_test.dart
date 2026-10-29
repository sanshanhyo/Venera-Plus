import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_cache.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_controller.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_source.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

const _account = StorageAccount(
  id: 'drive',
  backend: StorageBackend.webdav,
  driver: 'WebDAV',
  name: 'Drive',
  authorization: {},
);
const _location = RemoteLocation(accountId: 'drive', directory: '/Comic/');

RemoteEntry _file(String path, {String? eTag}) => RemoteEntry(
  name: path.split('/').last,
  path: path,
  isDirectory: false,
  size: 100,
  eTag: eTag,
);

RemoteEntry _folder(String path) => RemoteEntry(
  name: path.split('/').where((part) => part.isNotEmpty).last,
  path: path,
  isDirectory: true,
);

void main() {
  late Directory temporary;
  late RemoteStorageAccounts storage;
  final controllers = <CloudHomeController>[];

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('venera-cloud-home-');
    App.dataPath = temporary.path;
    App.cachePath = temporary.path;
    appdata.settings.replaceAll({
      remoteStorageAccountsSetting: [_account.toJson()],
      homeRemoteLocationSetting: _location.toJson(),
    });
    storage = RemoteStorageAccounts();
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    storage.dispose();
    await temporary.delete(recursive: true);
  });

  CloudHomeController create(
    _Store store, {
    Future<String?> Function(String sourceKey, String path)? preloadComic,
  }) {
    final controller = CloudHomeController(
      accounts: storage,
      storeFactory: (_) => store,
      cache: CloudHomeDirectoryCache(
        directoryPath: '${temporary.path}/directory-cache',
      ),
      ensureSource: (location) async => cloudHomeLibrary(location).sourceKey,
      preloadComic: preloadComic ?? (_, _) async => null,
    );
    controllers.add(controller);
    return controller;
  }

  test(
    'home lists direct children and keeps the bound root as a browser',
    () async {
      final store = _Store({
        '/Comic/': [
          _folder('/Comic/Comic/'),
          const RemoteEntry(
            name: 'nested/leaked.pdf',
            path: '/Comic/nested/leaked.pdf',
            isDirectory: false,
          ),
          _file('/Comic/.DS_Store'),
        ],
        '/Comic/Comic/': [_file('/Comic/Comic/book.pdf')],
      });
      final controller = create(store);
      await controller.initialize();
      expect(controller.items.map((item) => item.name), ['Comic']);
      expect(controller.directoryKind, CloudHomeItemKind.directory);
      expect(store.calls, ['/Comic/']);
      expect(controller.canGoUp, isFalse);
    },
  );

  test('classification ignores only known auxiliary files', () {
    final pdf = _file('/book/chapter7.PDF');
    expect(
      classifyCloudHomeDirectory([
        pdf,
        _file('/book/cover.jpg'),
        _file('/book/folder.png'),
        _file('/book/metadata.json'),
        _file('/book/chapter7.PDF.metadata.json'),
        _file('/book/ComicInfo.xml'),
        _file('/book/Thumbs.db'),
        _file('/book/.DS_Store'),
      ]),
      CloudHomeItemKind.pdfCollection,
    );
    for (final other in [
      _file('/book/notes.json'),
      _file('/book/other.zip'),
      _file('/book/page.jpg'),
      _folder('/book/other/'),
    ]) {
      expect(
        classifyCloudHomeDirectory([pdf, other]),
        CloudHomeItemKind.directory,
      );
    }
    expect(classifyCloudHomeDirectory([]), CloudHomeItemKind.directory);
    expect(
      classifyCloudHomeDirectory([_file('/book/metadata.json')]),
      CloudHomeItemKind.directory,
    );
  });

  test('pure image leaves remain readable; mixed image trees stay folders', () {
    expect(
      classifyCloudHomeDirectory([
        _file('/book/001.jpg'),
        _file('/book/002.png'),
      ]),
      CloudHomeItemKind.imageComic,
    );
    for (final other in [
      _folder('/book/chapter/'),
      _file('/book/notes.txt'),
      _file('/book/other.pdf'),
    ]) {
      expect(
        classifyCloudHomeDirectory([_file('/book/001.jpg'), other]),
        CloudHomeItemKind.directory,
      );
    }
  });

  test(
    'PDF collections browse original files without chapter mapping',
    () async {
      final store = _Store({
        '/Comic/': [_folder('/Comic/阿衰/')],
        '/Comic/阿衰/': [
          _file('/Comic/阿衰/阿衰_chapter9.pdf'),
          _file('/Comic/阿衰/阿衰_chapter7.pdf'),
          _file('/Comic/阿衰/阿衰_chapter8.pdf'),
        ],
      });
      final warmed = <String>[];
      final controller = create(
        store,
        preloadComic: (_, path) async {
          warmed.add(path);
          return 'cover:$path';
        },
      );
      await controller.initialize();
      await controller.preload(start: 0, count: 2);
      final collection = controller.items.single;
      expect(collection.kind, CloudHomeItemKind.pdfCollection);
      expect(collection.fileCount, 3);
      expect(collection.cover, 'cover:/Comic/阿衰/阿衰_chapter7.pdf');
      expect(warmed, ['/Comic/阿衰/阿衰_chapter7.pdf']);
      await controller.openDirectory(collection.path);
      expect(controller.items.map((item) => item.name), [
        '阿衰_chapter7.pdf',
        '阿衰_chapter8.pdf',
        '阿衰_chapter9.pdf',
      ]);
      expect(controller.items.every((item) => item.isReadable), isTrue);
      expect(controller.items.first.path, '/Comic/阿衰/阿衰_chapter7.pdf');
      expect(controller.directoryKind, CloudHomeItemKind.pdfCollection);
      await controller.goUp();
      expect(controller.directory, '/Comic/');
    },
  );

  test(
    'manual recognition persists and the home root cannot be overridden',
    () async {
      final store = _Store({
        '/Comic/': [_folder('/Comic/book/')],
        '/Comic/book/': [_file('/Comic/book/1.pdf')],
      });
      final first = create(store);
      await first.initialize();
      await first.preload(start: 0, count: 1);
      await first.setDirectoryOverride(
        '/Comic/book/',
        CloudHomeDirectoryOverride.folder,
      );
      expect(first.items.single.kind, CloudHomeItemKind.directory);
      first.dispose();
      final second = create(store);
      await second.initialize();
      await second.preload(start: 0, count: 1);
      expect(second.items.single.kind, CloudHomeItemKind.directory);
      expect(
        second.directoryOverride('/Comic/book/'),
        CloudHomeDirectoryOverride.folder,
      );
      await second.setDirectoryOverride(
        '/Comic/',
        CloudHomeDirectoryOverride.comic,
      );
      expect(second.directoryKind, CloudHomeItemKind.directory);
      await second.setDirectoryOverride(
        '/Comic/book/',
        CloudHomeDirectoryOverride.automatic,
      );
      expect(second.items.single.kind, CloudHomeItemKind.pdfCollection);
    },
  );

  test('directory snapshots survive restart and network failure', () async {
    final first = create(
      _Store({
        '/Comic/': [_file('/Comic/book.pdf')],
      }),
    );
    await first.initialize();
    first.dispose();
    final failed = _Store({})
      ..onList = (_) async => throw StateError('Offline');
    final second = create(failed);
    await second.initialize();
    expect(second.items.single.path, '/Comic/book.pdf');
    expect(second.error, contains('Offline'));
    expect(second.isLoading, isFalse);
    expect(second.refreshedAt, isNotNull);
  });

  test('late directory requests cannot replace a newer navigation', () async {
    final old = Completer<List<RemoteEntry>>();
    final started = Completer<void>();
    final store =
        _Store({
            '/Comic/': [_folder('/Comic/A/'), _folder('/Comic/B/')],
            '/Comic/B/': [_file('/Comic/B/new.pdf')],
          })
          ..onList = (path) async {
            if (path == '/Comic/A/') {
              started.complete();
              return old.future;
            }
            return null;
          };
    final controller = create(store);
    await controller.initialize();
    final previous = controller.openDirectory('/Comic/A/');
    await started.future;
    await controller.openDirectory('/Comic/B/');
    old.complete([_file('/Comic/A/old.pdf')]);
    await previous;
    expect(controller.directory, '/Comic/B/');
    expect(controller.items.single.name, 'new.pdf');
  });

  test('switching bindings discards old prefetch results', () async {
    final old = Completer<List<RemoteEntry>>();
    final started = Completer<void>();
    final store =
        _Store({
            '/Comic/': [_folder('/Comic/A/')],
            '/Other/': [_file('/Other/current.pdf')],
          })
          ..onList = (path) async {
            if (path == '/Comic/A/') {
              started.complete();
              return old.future;
            }
            return null;
          };
    final controller = create(store);
    await controller.initialize();
    final preloading = controller.preload(start: 0, count: 1);
    await started.future;
    await controller.bind(
      const RemoteLocation(accountId: 'drive', directory: '/Other/'),
    );
    old.complete([_file('/Comic/A/stale.pdf')]);
    await preloading;
    expect(controller.directory, '/Other/');
    expect(controller.items.single.name, 'current.pdf');
  });

  test(
    'overlapping prefetches share requests and respect two directory slots',
    () async {
      final gates = <String, Completer<List<RemoteEntry>>>{};
      final store =
          _Store({
              '/Comic/': [
                for (var i = 0; i < 4; i++) _folder('/Comic/folder$i/'),
              ],
            })
            ..onList = (path) async {
              if (path == '/Comic/') return null;
              return (gates[path] ??= Completer<List<RemoteEntry>>()).future;
            };
      final controller = create(store);
      await controller.initialize();
      final preload = controller.preload(start: 0, count: 4);
      final duplicate = controller.preload(start: 0, count: 4);
      await _until(() => gates.length == 2);
      expect(store.maxActive, lessThanOrEqualTo(2));
      gates.values.toList().forEach((gate) => gate.complete([]));
      await _until(() => gates.length == 4);
      for (final gate in gates.values.where((gate) => !gate.isCompleted)) {
        gate.complete([]);
      }
      await Future.wait([preload, duplicate]);
      expect(store.calls.toSet().length, store.calls.length);
      expect(store.maxActive, lessThanOrEqualTo(2));
    },
  );

  test('slow file covers cannot block foreground folder navigation', () async {
    final cover = Completer<String?>();
    final started = Completer<void>();
    final store = _Store({
      '/Comic/': [_folder('/Comic/folder/'), _file('/Comic/book.pdf')],
      '/Comic/folder/': [_file('/Comic/folder/next.pdf')],
    });
    final controller = create(
      store,
      preloadComic: (_, _) {
        if (!started.isCompleted) started.complete();
        return cover.future;
      },
    );
    await controller.initialize();
    final preload = controller.preload(start: 1, count: 1);
    await started.future;
    await controller.openDirectory('/Comic/folder/');
    expect(controller.directory, '/Comic/folder/');
    expect(controller.items.single.name, 'next.pdf');
    cover.complete('old-cover');
    await preload;
    expect(controller.items.single.cover, isNull);
  });

  test(
    'refresh warms the same path again after its remote version changes',
    () async {
      final store = _Store({
        '/Comic/': [_file('/Comic/book.pdf', eTag: 'one')],
      });
      var calls = 0;
      final controller = create(
        store,
        preloadComic: (_, _) async => 'cover-${++calls}',
      );
      await controller.initialize();
      await controller.preload(start: 0, count: 1);
      expect(controller.items.single.cover, 'cover-1');
      store.entries['/Comic/'] = [_file('/Comic/book.pdf', eTag: 'two')];
      await controller.refresh();
      await controller.preload(start: 0, count: 1);
      expect(controller.items.single.entry.eTag, 'two');
      expect(controller.items.single.cover, 'cover-2');
      expect(calls, 2);
    },
  );

  test('mixed image/PDF chapter folders remain browsable', () async {
    final store = _Store({
      '/Comic/': [_folder('/Comic/book/')],
      '/Comic/book/': [
        _folder('/Comic/book/第1话/'),
        _folder('/Comic/book/第2话/'),
      ],
      '/Comic/book/第1话/': [_file('/Comic/book/第1话/001.jpg')],
      '/Comic/book/第2话/': [_file('/Comic/book/第2话/part.pdf')],
    });
    final controller = create(store);
    await controller.initialize();
    await controller.preload(start: 0, count: 1);
    expect(controller.items.single.kind, CloudHomeItemKind.directory);
    await controller.openDirectory('/Comic/book/');
    expect(controller.items.length, 2);
  });

  test(
    'large image chapter trees do not trigger unbounded home probing',
    () async {
      final store = _Store({
        '/Comic/': [_folder('/Comic/book/')],
        '/Comic/book/': [
          for (var i = 0; i < 500; i++) _folder('/Comic/book/第$i话/'),
        ],
      });
      final controller = create(store);
      await controller.initialize();
      await controller.preload(start: 0, count: 1);
      expect(store.calls, ['/Comic/', '/Comic/book/']);
      expect(controller.items.single.kind, CloudHomeItemKind.directory);
      await controller.setDirectoryOverride(
        '/Comic/book/',
        CloudHomeDirectoryOverride.comic,
      );
      expect(controller.items.single.kind, CloudHomeItemKind.imageComic);
    },
  );

  test('external binding changes reach an already initialized home', () async {
    final store = _Store({
      '/Comic/': [_file('/Comic/old.pdf')],
      '/Other/': [_file('/Other/new.pdf')],
    });
    final controller = create(store);
    await controller.initialize();
    appdata.settings[homeRemoteLocationSetting] = const RemoteLocation(
      accountId: 'drive',
      directory: '/Other/',
    ).toJson();
    await _until(
      () => controller.directory == '/Other/' && !controller.isLoading,
    );
    expect(controller.items.single.name, 'new.pdf');
    await expectLater(
      controller.openDirectory('/OtherSibling/'),
      throwsArgumentError,
    );
  });
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Asynchronous operation did not complete');
}

class _Store implements RemoteFileStore {
  _Store(this.entries);
  final Map<String, List<RemoteEntry>> entries;
  Future<List<RemoteEntry>?> Function(String)? onList;
  final calls = <String>[];
  int active = 0;
  int maxActive = 0;

  @override
  StorageAccount get account => _account;

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    calls.add(directory);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      return await onList?.call(directory) ?? entries[directory] ?? const [];
    } finally {
      active--;
    }
  }

  @override
  Future<void> cancelAll() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
