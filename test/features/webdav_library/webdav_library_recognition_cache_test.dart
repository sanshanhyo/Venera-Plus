import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_plus/foundation/app.dart';

void main() {
  late Directory temporary;
  final cache = WebDavLibraryCache.instance;

  setUp(() {
    cache.resetForTesting();
    temporary = Directory.systemTemp.createTempSync('pdf-recognition-cache-');
    App.dataPath = temporary.path;
  });

  tearDown(() {
    cache.resetForTesting();
    temporary.deleteSync(recursive: true);
  });

  test(
    'old initialized indexes request recognition without losing sync state',
    () {
      final old = sqlite3.open('${temporary.path}/webdav_library.db');
      old.execute('''
      CREATE TABLE webdav_library_state (
        config_key TEXT PRIMARY KEY,
        last_successful_sync INTEGER NOT NULL DEFAULT 0,
        index_initialized INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO webdav_library_state VALUES ('library', 12345, 1);
    ''');
      old.close();

      expect(cache.hasDirectoryIndex('library'), isFalse);
      expect(cache.lastSuccessfulSync('library'), 12345);
      cache.setLastSuccessfulSync('library', 67890);
      expect(cache.hasDirectoryIndex('library'), isTrue);
      expect(cache.lastSuccessfulSync('library'), 67890);
      cache.resetForTesting();
      expect(cache.hasDirectoryIndex('library'), isTrue);
    },
  );

  test(
    'old file snapshots remain addressable but are rebuilt with new layout',
    () {
      const id = '/library/Series/chapter2.pdf';
      cache.upsertSnapshot(
        'library',
        const WebDavLibraryCachedComic(
          id: id,
          sortIndex: 0,
          title: 'chapter2',
          author: '',
          tags: [],
          cover: '',
          snapshot: {'formatVersion': 9, 'title': 'chapter2'},
          remoteETag: 'old',
          remoteModifiedAt: 12345,
        ),
      );
      expect(cache.find('library', id)!.isReady, isFalse);
      expect(cache.find('library', id)!.id, id);
      expect(cache.count('library'), 1);
      cache.replaceRootDirectoryIndex(
        'library',
        const WebDavLibraryRootIndex(
          rootPath: '/library/',
          directories: [
            WebDavLibraryRemoteDirectory(id: '/library/Series/', sortIndex: 0),
          ],
        ),
      );
      expect(cache.find('library', id), isNotNull);
      expect(
        cache.page('library', page: 1, pageSize: 20).single.id,
        '/library/Series/',
      );
    },
  );
}
