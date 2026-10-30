import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:venera_plus/features/comic_source/models.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/features/local_comics/import_export/comic_export.dart';
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_service.dart';
import 'package:venera_plus/features/metadata/metadata_store.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/network/images.dart';

const _reference = MetadataReference(
  provider: MetadataProviderId.ehentai,
  id: '42424242',
  token: 'abcdef0123',
  sourceUrl: 'https://e-hentai.org/g/42424242/abcdef0123/',
);

MetadataResult _result({String title = 'Sample title', String? coverUrl}) =>
    MetadataResult(
      reference: _reference,
      title: title,
      authors: const ['Sample artist'],
      tags: const {
        'language': ['japanese'],
        'group': ['Sample studio'],
      },
      coverUrl: coverUrl,
      fetchedAt: DateTime.utc(2026, 10, 30),
    );

ComicDetails _details() => ComicDetails.fromJson({
  'title': 'Original title',
  'subtitle': 'Original author',
  'cover': 'original-cover',
  'description': 'Original description',
  'tags': {
    'author': ['Original author'],
    'original': ['kept'],
  },
  'chapters': {'chapter-1': 'Original chapter'},
  'chapterPageCounts': {'chapter-1': 3},
  'chapterGroups': {'chapter-1': 'Original group'},
  'sourceKey': 'webdav-test',
  'comicId': '/books/sample.cbz',
  'externalIds': {'bangumi': '123'},
  'maxPage': 3,
  'url': 'https://storage.example/books/sample.cbz',
  'stars': 4.0,
});

class _Gateway implements MetadataGateway {
  @override
  MetadataReference parseReference(
    String input, {
    MetadataProviderId? provider,
  }) => _reference;

  @override
  Future<MetadataResult> fetch(MetadataReference reference) async => _result();

  @override
  bool isAllowedCoverUri(MetadataProviderId provider, Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'covers.example' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _FailingStore extends MetadataStore {
  _FailingStore({required super.databasePath, required super.coverDirectory});
  bool fail = false;
  @override
  void save(MetadataBinding binding) {
    if (fail) throw StateError('Simulated database write failure');
    super.save(binding);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late MetadataStore store;
  late MetadataService service;
  late _Adapter adapter;
  late Uint8List png;

  MetadataService makeService(MetadataStore target) {
    final dio = Dio()..httpClientAdapter = adapter;
    return MetadataService.withDependencies(
      gateway: _Gateway(),
      store: target,
      coverDio: dio,
      gatewayFactory: (_, _) => _Gateway(),
    );
  }

  setUp(() {
    LocalManager.resetForTesting();
    MetadataStore.resetForTesting();
    temporary = Directory.systemTemp.createTempSync('venera-metadata-');
    App.dataPath = '${temporary.path}/data';
    App.cachePath = '${temporary.path}/cache';
    Directory(App.dataPath).createSync(recursive: true);
    png = Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 3)));
    adapter = _Adapter(
      (_) => ResponseBody.fromBytes(
        png,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      ),
    );
    store = MetadataStore(
      databasePath: '${App.dataPath}/metadata_overrides.db',
      coverDirectory: '${App.dataPath}/metadata_covers',
    );
    service = makeService(store);
  });

  tearDown(() {
    ImageDownloader.debugResetSourceImageLoading();
    ComicType.configureSourceKeyResolver(null);
    LocalManager.resetForTesting();
    store.dispose();
    MetadataStore.resetForTesting();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test(
    'metadata persists across reopen and preserves reading and Bangumi identity',
    () async {
      final base = _details();
      await service.save(
        sourceKey: base.sourceKey,
        comicId: base.id,
        result: _result(),
        cacheCover: false,
      );
      expect(adapter.requests, isEmpty);
      final applied = service.applyDetails(base);
      expect(applied.title, 'Sample title');
      expect(applied.subTitle, 'Sample artist');
      expect(applied.description, base.description);
      expect(applied.cover, base.cover);
      expect(applied.tags['author'], ['Sample artist']);
      expect(applied.sourceKey, base.sourceKey);
      expect(applied.id, base.id);
      expect(applied.chapters, same(base.chapters));
      expect(applied.chapterPageCounts, same(base.chapterPageCounts));
      expect(applied.chapterGroups, same(base.chapterGroups));
      expect(applied.maxPage, base.maxPage);
      expect(applied.url, base.url);
      expect(applied.stars, base.stars);
      expect(applied.externalIds, {'bangumi': '123', 'ehentai': '42424242'});
      store.dispose();
      store = MetadataStore(
        databasePath: '${App.dataPath}/metadata_overrides.db',
        coverDirectory: '${App.dataPath}/metadata_covers',
      );
      service = makeService(store);
      expect(
        service.find(base.sourceKey, base.id)!.result.reference.token,
        'abcdef0123',
      );
      expect(service.applyDetails(base).title, 'Sample title');
      expect(adapter.requests, isEmpty);
      await service.remove(base.sourceKey, base.id);
      expect(service.applyDetails(applied), same(base));
    },
  );

  test(
    'disabling cover cache makes zero image requests and memory loads write no files',
    () async {
      final saved = await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: _result(coverUrl: 'https://covers.example/sample.png'),
        cacheCover: false,
      );
      expect(saved.binding.coverPath, isNull);
      expect(adapter.requests, isEmpty);
      final key = store.coverKey(saved.binding)!;
      expect(await service.loadCoverKey(key), png);
      expect(await service.loadCoverKey(key), png);
      expect(adapter.requests, hasLength(2));
      expect(Directory(store.coverDirectory).existsSync(), isFalse);
      expect(Directory('${App.cachePath}/cache').existsSync(), isFalse);
    },
  );

  test(
    'thumbnail override bypasses source configuration and global disk cache',
    () async {
      final saved = await service.save(
        sourceKey: 'webdav-test',
        comicId: '/book',
        result: _result(coverUrl: 'https://covers.example/sample.png'),
        cacheCover: false,
      );
      configureMetadataCoverLoading(service);
      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (_, _) => throw StateError(
          'A local metadata cover must not use source credentials',
        ),
      );
      final events = await ImageDownloader.loadThumbnail(
        store.coverKey(saved.binding)!,
        'webdav-test',
        '/book',
      ).toList();
      expect(events.single.imageBytes, png);
      expect(adapter.requests, hasLength(1));
      expect(Directory('${App.cachePath}/cache').existsSync(), isFalse);
    },
  );

  test(
    'cached covers survive reopen and are removed when policy changes or binding is removed',
    () async {
      final result = _result(coverUrl: 'https://covers.example/sample.png');
      var saved = await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: result,
        cacheCover: true,
      );
      final firstFile = store.coverFile(saved.binding.coverPath!);
      expect(firstFile.readAsBytesSync(), png);
      expect(adapter.requests, hasLength(1));
      store.dispose();
      store = MetadataStore(
        databasePath: '${App.dataPath}/metadata_overrides.db',
        coverDirectory: '${App.dataPath}/metadata_covers',
      );
      service = makeService(store);
      expect(await service.loadBindingCover(service.find('local', '1')!), png);
      expect(adapter.requests, hasLength(1));
      saved = await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: result,
        cacheCover: false,
      );
      expect(saved.binding.coverPath, isNull);
      expect(firstFile.existsSync(), isFalse);
      expect(adapter.requests, hasLength(1));
      saved = await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: result,
        cacheCover: true,
      );
      final lastFile = store.coverFile(saved.binding.coverPath!);
      await service.remove('local', '1');
      expect(lastFile.existsSync(), isFalse);
      expect(service.find('local', '1'), isNull);
    },
  );

  test(
    'cover download failure saves metadata with an explicit warning',
    () async {
      adapter.respond = (_) => ResponseBody.fromString('Unavailable', 503);
      final saved = await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: _result(coverUrl: 'https://covers.example/sample.png'),
        cacheCover: true,
      );
      expect(saved.coverError, isNotNull);
      expect(saved.binding.coverPath, isNull);
      expect(saved.binding.cacheCover, isTrue);
      expect(service.find('local', '1')!.result.title, 'Sample title');
    },
  );

  test(
    'database failure keeps prior metadata and cover and removes new orphan',
    () async {
      store.dispose();
      final failing = _FailingStore(
        databasePath: '${App.dataPath}/metadata_overrides.db',
        coverDirectory: '${App.dataPath}/metadata_covers',
      );
      store = failing;
      service = makeService(store);
      final old = await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: _result(coverUrl: 'https://covers.example/sample.png'),
        cacheCover: true,
      );
      failing.fail = true;
      await expectLater(
        service.save(
          sourceKey: 'local',
          comicId: '1',
          result: _result(
            title: 'Replacement',
            coverUrl: 'https://covers.example/new.png',
          ),
          cacheCover: true,
        ),
        throwsStateError,
      );
      expect(service.find('local', '1')!.result.title, 'Sample title');
      expect(store.coverFile(old.binding.coverPath!).existsSync(), isTrue);
      expect(Directory(store.coverDirectory).listSync(), hasLength(1));
    },
  );

  test(
    'cover redirects are checked before requesting a different host',
    () async {
      adapter.respond = (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://127.0.0.1/private'],
        },
      );
      await expectLater(
        service.loadCover(_result(coverUrl: 'https://covers.example/start')),
        throwsA(isA<MetadataCoverException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.followRedirects, isFalse);
    },
  );

  test(
    'non-images, invalid image data and oversized responses cannot become cached covers',
    () async {
      for (final response in [
        ResponseBody.fromString(
          '<html>Challenge</html>',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        ),
        ResponseBody.fromString(
          'not an image',
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png'],
          },
        ),
        ResponseBody.fromBytes(
          png,
          200,
          headers: {
            Headers.contentTypeHeader: ['image/png'],
            Headers.contentLengthHeader: [
              '${MetadataService.maximumCoverBytes + 1}',
            ],
          },
        ),
      ]) {
        adapter.respond = (_) => response;
        await expectLater(
          service.loadCover(_result(coverUrl: 'https://covers.example/sample')),
          throwsA(isA<MetadataCoverException>()),
        );
      }
      expect(Directory(store.coverDirectory).existsSync(), isFalse);
    },
  );

  test(
    'JM origins persist locally and invalid settings do not replace them',
    () async {
      await service.configureJm(
        baseUrl: 'https://jm.example/',
        coverBaseUrl: 'https://covers.example',
      );
      expect(service.jmBaseUrl, 'https://jm.example');
      store.dispose();
      store = MetadataStore(
        databasePath: '${App.dataPath}/metadata_overrides.db',
        coverDirectory: '${App.dataPath}/metadata_covers',
      );
      service = makeService(store);
      expect(service.jmBaseUrl, 'https://jm.example');
      await expectLater(
        service.configureJm(
          baseUrl: 'https://localhost/',
          coverBaseUrl: 'https://covers.example',
        ),
        throwsFormatException,
      );
      expect(service.jmBaseUrl, 'https://jm.example');
    },
  );

  test(
    'local imported metadata updates display and leaves original database fields recoverable',
    () async {
      store.dispose();
      store = MetadataStore.app;
      service = makeService(store);
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      final original = LocalComic(
        id: '1',
        title: 'Original local',
        subtitle: 'Original artist',
        tags: const ['original'],
        directory: 'book',
        chapters: null,
        cover: 'cover.png',
        comicType: ComicType.local,
        downloadedChapters: [],
        createdAt: DateTime(2026),
      );
      await manager.add(original);
      var changes = 0;
      manager.addListener(() => changes++);
      await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: _result(),
        cacheCover: false,
      );
      final enriched = manager.find('1', ComicType.local)!;
      expect(enriched.title, 'Sample title');
      expect(enriched.subtitle, 'Sample artist');
      expect(enriched.id, original.id);
      expect(enriched.sourceKey, original.sourceKey);
      expect(enriched.comicType, original.comicType);
      expect(enriched.directory, original.directory);
      expect(changes, 1);
      // Other local-manager updates must never promote the display overlay to base data.
      await manager.add(enriched);
      await service.remove('local', '1');
      final restored = manager.find('1', ComicType.local)!;
      expect(restored.title, 'Original local');
      expect(restored.subtitle, 'Original artist');
      expect(restored.cover, 'cover.png');
      expect(restored.tags, ['original']);
    },
  );

  test(
    'chapter updates retain original metadata and export manifests retain physical covers',
    () async {
      store.dispose();
      store = MetadataStore.app;
      service = makeService(store);
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      final book = LocalComic(
        id: '1',
        title: 'Original book',
        subtitle: 'Original artist',
        tags: const ['original'],
        directory: 'book',
        chapters: ComicChapters.fromJsonOrNull({'one': 'One'}),
        cover: 'cover.png',
        comicType: ComicType.local,
        downloadedChapters: ['one'],
        createdAt: DateTime(2026),
      );
      Directory('${manager.path}/book').createSync(recursive: true);
      File('${manager.path}/book/cover.png').writeAsBytesSync(png);
      await manager.add(book);
      await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: _result(coverUrl: 'https://covers.example/sample.png'),
        cacheCover: false,
      );
      final enriched = manager.find('1', ComicType.local)!;
      expect(enriched.cover, startsWith('$metadataCoverScheme:'));
      final exported = ComicExportInfo.fromLocalComic(enriched);
      final restored = ComicExportInfo.fromJson(
        jsonDecode(jsonEncode(exported.toJson())),
      );
      final imported = LocalComic(
        id: restored.id,
        title: restored.title,
        subtitle: restored.subtitle,
        tags: restored.tags,
        directory: restored.directory,
        chapters: ComicChapters.fromJsonOrNull(restored.chapters),
        cover: restored.cover,
        comicType: ComicType(restored.comicType),
        downloadedChapters: restored.downloadedChapters,
        createdAt: DateTime.fromMillisecondsSinceEpoch(restored.createdAt),
      );
      expect(imported.storedCover, 'cover.png');
      expect(imported.coverFile.readAsBytesSync(), png);
      expect(restored.title, 'Original book');
      manager.isDownloaded(
        '1',
        ComicType.local,
        1,
        ComicChapters.fromJsonOrNull({'one': 'One', 'two': 'Two'}),
      );
      await Future<void>.delayed(Duration.zero);
      await service.remove('local', '1');
      final current = manager.find('1', ComicType.local)!;
      expect(current.title, 'Original book');
      expect(current.subtitle, 'Original artist');
      expect(current.tags, ['original']);
      expect(current.cover, 'cover.png');
      expect(current.chapters!.length, 2);
    },
  );

  for (final deletion in ['remove', 'batch', 'last chapter']) {
    test(
      'local $deletion clears binding and cover before an import can reuse its ID',
      () async {
        store.dispose();
        store = MetadataStore.app;
        service = makeService(store);
        LocalManager.debugSkipComicSourceInit = true;
        final manager = LocalManager();
        await manager.init();
        final old = LocalComic(
          id: '1',
          title: 'Old book',
          subtitle: '',
          tags: const [],
          directory: 'old',
          chapters: ComicChapters.fromJsonOrNull({'one': 'One'}),
          cover: 'old.png',
          comicType: ComicType.local,
          downloadedChapters: ['one'],
          createdAt: DateTime(2026),
        );
        await manager.add(old);
        final saved = await service.save(
          sourceKey: 'local',
          comicId: '1',
          result: _result(coverUrl: 'https://covers.example/sample.png'),
          cacheCover: true,
        );
        final cached = store.coverFile(saved.binding.coverPath!);
        switch (deletion) {
          case 'batch':
            manager.batchDeleteComics([old], false, false);
          case 'last chapter':
            manager.deleteComicChapters(old, ['one']);
          default:
            manager.remove('1', ComicType.local);
        }
        expect(service.find('local', '1'), isNull);
        expect(cached.existsSync(), isFalse);
        final reused = manager.findValidId(ComicType.local);
        expect(reused, '1');
        await manager.add(
          LocalComic(
            id: reused,
            title: 'Different book',
            subtitle: '',
            tags: const [],
            directory: 'new',
            chapters: null,
            cover: 'new.png',
            comicType: ComicType.local,
            downloadedChapters: [],
            createdAt: DateTime(2026),
          ),
        );
        expect(manager.find(reused, ComicType.local)!.title, 'Different book');
        expect(manager.find(reused, ComicType.local)!.cover, 'new.png');
      },
    );
  }

  test(
    'removing a downloaded remote copy retains its remote metadata binding',
    () async {
      store.dispose();
      store = MetadataStore.app;
      service = makeService(store);
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      ComicType.configureSourceKeyResolver((value) => 'webdav-test');
      final type = ComicType.fromKey('webdav-test');
      await manager.add(
        LocalComic(
          id: '/book',
          title: 'Remote',
          subtitle: '',
          tags: const [],
          directory: 'remote',
          chapters: null,
          cover: 'cover.png',
          comicType: type,
          downloadedChapters: [],
          createdAt: DateTime(2026),
        ),
      );
      final saved = await service.save(
        sourceKey: 'webdav-test',
        comicId: '/book',
        result: _result(coverUrl: 'https://covers.example/sample.png'),
        cacheCover: true,
      );
      manager.remove('/book', type);
      expect(service.find('webdav-test', '/book'), isNotNull);
      expect(store.coverFile(saved.binding.coverPath!).existsSync(), isTrue);
    },
  );

  test(
    'local search and name sorting use visible metadata and removal restores original results',
    () async {
      store.dispose();
      store = MetadataStore.app;
      service = makeService(store);
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      for (final book in [('1', 'A original'), ('2', 'M other')]) {
        await manager.add(
          LocalComic(
            id: book.$1,
            title: book.$2,
            subtitle: '',
            tags: const ['original-tag'],
            directory: book.$1,
            chapters: null,
            cover: 'cover.png',
            comicType: ComicType.local,
            downloadedChapters: [],
            createdAt: DateTime(2026),
          ),
        );
      }
      await service.save(
        sourceKey: 'local',
        comicId: '1',
        result: _result(title: 'Z matched'),
        cacheCover: false,
      );
      expect(manager.search('Z matched').single.id, '1');
      expect(manager.search('sample artist').single.id, '1');
      expect(manager.search('japanese').single.id, '1');
      expect(manager.getComics(LocalSortType.name).map((book) => book.id), [
        '1',
        '2',
      ]);
      // Duplicate detection during import remains tied to the original stored title.
      expect(manager.findByName('A original')!.id, '1');
      expect(manager.findByName('Z matched'), isNull);
      await service.remove('local', '1');
      expect(manager.search('Z matched'), isEmpty);
      expect(manager.search('A original').single.id, '1');
      expect(manager.getComics(LocalSortType.name).map((book) => book.id), [
        '2',
        '1',
      ]);
    },
  );
}
