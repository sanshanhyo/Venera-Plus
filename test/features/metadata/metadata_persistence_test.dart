import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/favorites/local_favorite_image.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/metadata/metadata.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

const _source = 'metadata-persistence-test';

MetadataBinding _binding(String source, String id, {int revision = 1}) =>
    MetadataBinding(
      sourceKey: source,
      comicId: id,
      result: MetadataResult(
        reference: const MetadataReference(
          provider: MetadataProviderId.jmcomic,
          id: '123',
          sourceUrl: 'https://example.com/album/123',
        ),
        title: 'Visible title $revision',
        authors: const ['Visible author'],
        tags: const {
          'genre': ['visible'],
        },
        coverUrl: 'https://example.com/cover-$revision.jpg',
      ),
      cacheCover: false,
      updatedAt: DateTime.utc(2026, 11, 9, 0, 0, revision),
    );

ComicDetails _details() => ComicDetails.fromJson({
  'title': 'Original title',
  'subtitle': 'Original author',
  'cover': 'https://example.com/original.jpg',
  'tags': <String, List<String>>{},
  'chapters': {'one': 'Chapter one', 'two': 'Chapter two'},
  'chapterPageCounts': {'one': 3, 'two': 4},
  'sourceKey': _source,
  'comicId': 'book',
});

LocalComic _local() => LocalComic(
  id: 'local-book',
  title: 'Original local',
  subtitle: 'Original local author',
  tags: const ['original'],
  directory: 'local-book',
  chapters: null,
  cover: 'cover.jpg',
  comicType: ComicType.local,
  downloadedChapters: const [],
  createdAt: DateTime.utc(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MetadataStore store;
  late Map<String, dynamic> previousSettings;
  late Map<String, dynamic> previousImplicit;
  String? previousDataPath;
  String? previousCachePath;

  setUp(() {
    try {
      previousDataPath = App.dataPath;
      previousCachePath = App.cachePath;
    } on Error {
      // The first model-only fixture initializes application paths.
    }
    previousSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    directory = Directory.systemTemp.createTempSync('metadata-persistence-');
    App.dataPath = App.cachePath = directory.path;
    MetadataStore.resetForTesting();
    store = MetadataStore.app;
    ComicType.configureSourceKeyResolver(
      (value) => value == _source.hashCode ? _source : null,
    );
  });

  tearDown(() {
    MetadataStore.resetForTesting();
    ComicType.configureSourceKeyResolver(null);
    (appdata.toJson()['settings'] as Map)
      ..clear()
      ..addAll(previousSettings);
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    App.dataPath = previousDataPath ?? Directory.systemTemp.path;
    App.cachePath = previousCachePath ?? Directory.systemTemp.path;
    directory.deleteSync(recursive: true);
  });

  test(
    'favorites retain base fields through copies, persistence and sync',
    () async {
      final previousManager = LocalFavoritesManager.cache;
      LocalFavoritesManager.cache = null;
      final manager = LocalFavoritesManager();
      await manager.init(reconcileReadingBinding: false);
      try {
        manager.createFolder('Main');
        final original = Comic(
          'Original title',
          'https://example.com/original.jpg',
          'book',
          'Original author',
          const ['original'],
          '',
          _source,
          7,
          null,
        );
        var changes = 0;
        manager.addListener(() => changes++);
        store.save(_binding(_source, 'book'));
        expect(changes, 1);
        final enriched = MetadataStore.applyAppComic(original);
        expect(enriched.title, 'Visible title 1');
        final favorite = FavoriteItem.fromComic(enriched);
        final snapshot = ComicUpdateSnapshot.fromChapters(
          {
            'edition': {'one': 'Chapter one', 'two': 'Chapter two'},
          },
          chapterPageCounts: {'one': 3, 'two': 4},
        );
        manager.addComic('Main', favorite, null, snapshot);
        final copied = manager.getComicsWithUpdatesInfo('Main').single;
        manager.updateInfo('Main', copied);
        expect(copied.title, 'Visible title 1');
        expect(copied.cover, startsWith('$metadataCoverScheme:'));
        expect(favorite.toJson(), containsPair('name', 'Original title'));
        expect(favorite.toJson(), containsPair('coverPath', original.cover));
        final folder = jsonDecode(manager.folderToJson('Main')) as Map;
        final saved = (folder['comics'] as List).single as Map;
        expect(saved['name'], 'Original title');
        expect(saved['author'], 'Original author');
        expect(saved['coverPath'], original.cover);
        expect(saved['tags'], ['original']);
        final db = sqlite3.open('${directory.path}/local_favorite.db');
        try {
          final sync = FavoriteSyncData.readSyncRecords(db);
          final comics = sync.values.where(
            (value) => value.containsKey('cover'),
          );
          expect(comics, isNotEmpty);
          expect(
            comics.every((value) => value['cover'] == original.cover),
            isTrue,
          );
        } finally {
          db.close();
        }
        final updateState = manager.getUpdateState('book', favorite.type);
        store.remove(_source, 'book');
        expect(copied.title, 'Original title');
        expect(copied.subtitle, 'Original author');
        expect(copied.cover, original.cover);
        expect(copied.tags, ['original']);
        expect(
          manager.getUpdateState('book', favorite.type).toJson(),
          updateState.toJson(),
        );
      } finally {
        await manager.waitForPendingReads();
        manager.close();
        LocalFavoritesManager.cache = previousManager;
      }
    },
  );

  test(
    'history writes base details while retaining chapter and progress state',
    () async {
      final previousManager = HistoryManager.cache;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();
      try {
        final base = _details();
        var changes = 0;
        manager.addListener(() => changes++);
        store.save(_binding(_source, 'book'));
        expect(changes, 1);
        final history =
            History.fromModel(
                model: MetadataStore.applyAppDetails(base),
                ep: 2,
                page: 3,
                group: 1,
                readChapters: {'1-1'},
                readDurationMs: 1234,
              )
              ..maxChapter = 2
              ..chapterTitle = 'Chapter two'
              ..groupTitle = 'Edition one';
        expect(history.title, 'Visible title 1');
        manager.addHistory(history);
        await manager.waitForAsyncWrites();
        final saved = manager.find('book', base.historyType)!;
        saved.page = 4;
        manager.addHistory(saved);
        await manager.waitForAsyncWrites();
        final db = sqlite3.open('${directory.path}/history.db');
        try {
          final row = db.select('SELECT * FROM history').single;
          expect(row['title'], 'Original title');
          expect(row['subtitle'], 'Original author');
          expect(row['cover'], base.cover);
          expect(row['read_duration_ms'], 1234);
          final sync = HistorySyncData.readSyncRecords(db);
          expect(
            sync.values
                .whereType<Map>()
                .where((value) => value.containsKey('title'))
                .every((value) => value['title'] == 'Original title'),
            isTrue,
          );
        } finally {
          db.close();
        }
        store.remove(_source, 'book');
        final restored = manager.find('book', base.historyType)!;
        expect(restored.title, 'Original title');
        expect(restored.cover, base.cover);
        expect(restored.ep, 2);
        expect(restored.group, 1);
        expect(restored.readEpisode, contains('1-1'));
        expect(restored.readDurationMs, 1234);
        expect(restored.chapterTitle, 'Chapter two');
      } finally {
        await manager.waitForAsyncWrites();
        manager.close();
        HistoryManager.cache = previousManager;
      }
    },
  );

  test(
    'local models and immutable image keys recover when a cover is removed',
    () {
      final local = _local();
      final history = History.fromModel(model: local, ep: 1, page: 1);
      final favorite = FavoriteItem.fromComic(local);
      final originalHistoryKey = HistoryImageProvider(history).key;
      final originalFavoriteKey = LocalFavoriteImageProvider(
        favorite.cover,
        favorite.id,
        favorite.type.value,
      ).key;
      store.save(_binding('local', local.id));
      final firstHistoryProvider = HistoryImageProvider(history);
      final firstFavoriteProvider = LocalFavoriteImageProvider(
        favorite.cover,
        favorite.id,
        favorite.type.value,
      );
      final firstHistoryKey = firstHistoryProvider.key;
      final firstFavoriteKey = firstFavoriteProvider.key;
      expect(history.title, 'Visible title 1');
      expect(FavoriteItem.fromComic(local).storedName, local.storedTitle);
      expect(
        History.fromModel(model: local, ep: 1, page: 1).storedTitle,
        local.storedTitle,
      );
      store.save(_binding('local', local.id, revision: 2));
      expect(firstHistoryProvider.key, firstHistoryKey);
      expect(firstFavoriteProvider.key, firstFavoriteKey);
      expect(HistoryImageProvider(history).key, isNot(firstHistoryKey));
      expect(
        LocalFavoriteImageProvider(
          favorite.cover,
          favorite.id,
          favorite.type.value,
        ).key,
        isNot(firstFavoriteKey),
      );
      store.remove('local', local.id);
      expect(history.title, local.storedTitle);
      expect(favorite.cover, local.storedCover);
      expect(HistoryImageProvider(history).key, originalHistoryKey);
      expect(
        LocalFavoriteImageProvider(
          favorite.cover,
          favorite.id,
          favorite.type.value,
        ).key,
        originalFavoriteKey,
      );
    },
  );

  test(
    'display notifications do not dirty sync and lifecycle keeps data listeners',
    () async {
      final previousManager = LocalFavoritesManager.cache;
      LocalFavoritesManager.cache = null;
      final manager = LocalFavoritesManager();
      DataSync.resetForTesting();
      DataSync.debugDisableWindowCloseHandler = true;
      appdata.settings.remove('syncRemoteLocation');
      appdata.settings['webdav'] = [
        'https://example.com/dav',
        'user',
        'password',
      ];
      appdata.implicitData['webdavSyncMode'] = 'manual';
      appdata.implicitData['webdavSyncPending'] = false;
      await manager.init(reconcileReadingBinding: false);
      try {
        manager.createFolder('Main');
        final sync = DataSync();
        expect(sync.hasConfiguration, isTrue);
        expect(sync.hasPendingChanges, isFalse);
        var displayChanges = 0;
        manager.addListener(() => displayChanges++);
        store.save(_binding('local', 'local-book'));
        expect(displayChanges, 1);
        expect(sync.hasPendingChanges, isFalse);
        manager.addComic('Main', FavoriteItem.fromComic(_local()));
        expect(sync.hasPendingChanges, isTrue);
        appdata.implicitData['webdavSyncPending'] = false;

        await manager.waitForPendingReads();
        manager.close();
        final closedChanges = displayChanges;
        store.save(_binding('local', 'local-book', revision: 2));
        expect(displayChanges, closedChanges);
        await manager.init(reconcileReadingBinding: false);
        final reopenedChanges = displayChanges;
        appdata.implicitData['webdavSyncPending'] = false;
        store.save(_binding('local', 'local-book', revision: 3));
        expect(displayChanges, reopenedChanges + 1);
        expect(sync.hasPendingChanges, isFalse);

        var addedDuringDisplay = false;
        void addDuringDisplay() {
          if (addedDuringDisplay) return;
          addedDuringDisplay = true;
          manager.addComic(
            'Main',
            FavoriteItem(
              id: 'nested',
              name: 'Nested original',
              author: '',
              coverPath: '',
              type: ComicType.local,
              tags: const [],
            ),
          );
        }

        manager.addListener(addDuringDisplay);
        store.save(_binding('local', 'local-book', revision: 4));
        manager.removeListener(addDuringDisplay);
        expect(addedDuringDisplay, isTrue);
        expect(sync.hasPendingChanges, isTrue);

        DataSync.resetForTesting();
        appdata.implicitData['webdavSyncPending'] = false;
        manager.addComic(
          'Main',
          FavoriteItem(
            id: 'after-dispose',
            name: 'After dispose',
            author: '',
            coverPath: '',
            type: ComicType.local,
            tags: const [],
          ),
        );
        expect(appdata.implicitData['webdavSyncPending'], isFalse);
      } finally {
        DataSync.resetForTesting();
        await appdata.writeImplicitData();
        await manager.waitForPendingReads();
        manager.close();
        LocalFavoritesManager.cache = previousManager;
      }
    },
  );
}
