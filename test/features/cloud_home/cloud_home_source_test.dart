import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/cloud_home/cloud_home_source.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/features/webdav_library/remote_archive_comic.dart';
import 'package:venera_plus/features/webdav_library/webdav_library_cache.dart';
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

void main() {
  late Directory temporary;
  late _Store store;
  late _Accounts accounts;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'venera-cloud-home-source-',
    );
    App.dataPath = temporary.path;
    App.cachePath = temporary.path;
    appdata.settings.replaceAll({
      remoteStorageAccountsSetting: [_account.toJson()],
    });
    store = _Store();
    accounts = _Accounts(store);
  });

  tearDown(() async {
    for (final relation in readCloudHomeSources()) {
      ComicSourceManager().remove(relation.sourceKey);
    }
    WebDavLibraryEngines.cancelAll();
    WebDavLibrarySource.resetCacheForTesting();
    accounts.dispose();
    await temporary.delete(recursive: true);
  });

  test(
    'file sources are stable, retained, and never start recursive indexing',
    () async {
      const first = RemoteLocation(accountId: 'drive', directory: '/Comic/');
      final firstKey = await ensureCloudHomeSource(first, accounts: accounts);
      expect(
        firstKey,
        cloudHomeLibrary(
          const RemoteLocation(accountId: 'drive', directory: 'Comic'),
        ).sourceKey,
      );
      expect(ComicSource.find(firstKey)!.explorePages, isEmpty);
      expect(store.calls, isEmpty);
      await WebDavLibraryEngines.find(firstKey)!.synchronize(force: true);
      expect(store.calls, isEmpty);

      final otherKey = await ensureCloudHomeSource(
        const RemoteLocation(accountId: 'drive', directory: '/Other/'),
        accounts: accounts,
      );
      expect(otherKey, isNot(firstKey));
      expect(readCloudHomeSources(), hasLength(2));
      expect(ComicSource.find(firstKey), isNotNull);
      expect(
        findCloudHomeSource(firstKey)!.id,
        WebDavLibraryEngines.find(firstKey)!.libraryId,
      );

      store.entries['/Comic/book/'] = [
        const RemoteEntry(
          name: '1.jpg',
          path: '/Comic/book/1.jpg',
          isDirectory: false,
        ),
      ];
      final details = await ComicSource.find(firstKey)!.loadComicInfo!(
        '/Comic/book/',
      );
      expect(details.error, isFalse);
      final pages = await ComicSource.find(firstKey)!.loadComicPages!(
        '/Comic/book/',
        null,
      );
      expect(pages.data, ['/Comic/book/1.jpg']);
      expect(store.calls, ['/Comic/book/']);
    },
  );

  test(
    'reader snapshot is invalidated when a directly listed PDF changes',
    () async {
      const location = RemoteLocation(accountId: 'drive', directory: '/Comic/');
      final key = await ensureCloudHomeSource(location, accounts: accounts);
      final library = findCloudHomeSource(key)!;
      final configKey = 'remote-library:${library.id}';
      final archive = RemoteArchiveComic(
        path: '/Comic/book.pdf',
        size: 100,
        eTag: 'old',
        pdfPageCount: 1,
      );
      WebDavLibraryCache.instance.upsertSnapshot(
        configKey,
        WebDavLibraryCachedComic(
          id: '/Comic/book.pdf',
          sortIndex: 0,
          title: 'book',
          author: '',
          tags: [],
          cover: archive.imageKey(),
          remoteETag: 'old',
          remoteModifiedAt: null,
          snapshot: {
            'formatVersion': webDavLibrarySnapshotFormatVersion,
            'title': 'book',
            'cover': archive.imageKey(),
            'archive': archive.toJson(),
          },
        ),
      );
      final engine = WebDavLibraryEngines.find(key)!;
      await engine.prepareDirectoryBrowserEntry(
        const RemoteEntry(
          name: 'book.pdf',
          path: '/Comic/book.pdf',
          isDirectory: false,
          size: 100,
          eTag: 'old',
        ),
      );
      expect(
        WebDavLibraryCache.instance.find(configKey, '/Comic/book.pdf')!.isReady,
        isTrue,
      );
      await engine.prepareDirectoryBrowserEntry(
        const RemoteEntry(
          name: 'book.pdf',
          path: '/Comic/book.pdf',
          isDirectory: false,
          size: 200,
          eTag: 'new',
        ),
      );
      final changed = WebDavLibraryCache.instance.find(
        configKey,
        '/Comic/book.pdf',
      )!;
      expect(changed.id, '/Comic/book.pdf');
      expect(changed.isReady, isFalse);
      expect(store.calls, isEmpty);
    },
  );

  test(
    'account alias remapping preserves home bindings and source identities',
    () async {
      final original = cloudHomeLibrary(
        const RemoteLocation(accountId: 'old-drive', directory: '/Comic/'),
      );
      appdata.settings[homeRemoteSourcesSetting] = [
        {...original.toJson(), 'accountId': 'drive'},
      ];
      final restored = cloudHomeLibrary(
        const RemoteLocation(accountId: 'drive', directory: '/Comic/'),
      );
      expect(restored.sourceKey, original.sourceKey);
      expect(restored.id, original.id);
      expect(restored.accountId, 'drive');
      expect(findCloudHomeSource(restored.sourceKey)!.id, restored.id);
    },
  );

  test('malformed imported home relations do not block valid sources', () {
    final valid = cloudHomeLibrary(
      const RemoteLocation(accountId: 'drive', directory: '/Comic/'),
    );
    appdata.settings[homeRemoteSourcesSetting] = [
      {'id': 3, 'sourceKey': []},
      {
        ...valid.toJson(),
        'directories': ['../outside'],
      },
      valid.toJson(),
    ];
    expect(readCloudHomeSources().single.sourceKey, valid.sourceKey);
  });
}

class _Accounts extends RemoteStorageAccounts {
  _Accounts(this.store);
  final _Store store;
  @override
  RemoteFileStore storeFor(String accountId) => store;
}

class _Store implements RemoteFileStore {
  final entries = <String, List<RemoteEntry>>{};
  final calls = <String>[];
  @override
  StorageAccount get account => _account;
  @override
  Future<List<RemoteEntry>> list(String directory) async {
    calls.add(directory);
    return entries[directory] ?? [];
  }

  @override
  Future<void> cancelAll() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
