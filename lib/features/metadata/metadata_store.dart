import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';

import 'metadata_models.dart';

const metadataCoverScheme = 'metadata-cover';

/// User-confirmed metadata lives independently of a comic's remote sidecars.
/// Looking up a book does not create a database; the first save creates it.
class MetadataStore extends ChangeNotifier {
  MetadataStore({required this.databasePath, required this.coverDirectory});

  final String databasePath;
  final String coverDirectory;
  Database? _db;
  bool _disposed = false;
  final _bindings = <String, MetadataBinding?>{};
  static MetadataStore? _app;
  static final _baseDetails = Expando<ComicDetails>('metadata base details');

  static MetadataStore get app {
    final path = '${App.dataPath}/metadata_overrides.db';
    if (_app?.databasePath != path) {
      _app?.dispose();
      _app = MetadataStore(
        databasePath: path,
        coverDirectory: '${App.dataPath}/metadata_covers',
      );
    }
    return _app!;
  }

  static MetadataStore? get appOrNull {
    try {
      return app;
    } catch (_) {
      // Model-only callers can run before application directories are ready.
      return null;
    }
  }

  static MetadataBinding? lookupApp(String sourceKey, String comicId) {
    try {
      return appOrNull?.find(sourceKey, comicId);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _app?.dispose();
    _app = null;
  }

  Database _open() {
    if (_disposed) throw StateError('Metadata store is closed');
    if (_db != null) return _db!;
    File(databasePath).parent.createSync(recursive: true);
    final db = openSqliteDatabase(databasePath);
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS metadata_overrides (
          source_key TEXT NOT NULL,
          comic_id TEXT NOT NULL,
          result_json TEXT NOT NULL,
          cache_cover INTEGER NOT NULL,
          cover_path TEXT,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (source_key, comic_id)
        );
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS metadata_preferences (
          key TEXT NOT NULL PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
      _db = db;
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  String _identity(String sourceKey, String comicId) =>
      jsonEncode([sourceKey, comicId]);

  bool get hasBindings {
    if (_db == null && !File(databasePath).existsSync()) return false;
    return _open()
        .select('SELECT 1 FROM metadata_overrides LIMIT 1')
        .isNotEmpty;
  }

  String? preference(String key) {
    if (_db == null && !File(databasePath).existsSync()) return null;
    final rows = _open().select(
      'SELECT value FROM metadata_preferences WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  void savePreferences(Map<String, String> preferences) {
    final db = _open();
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final entry in preferences.entries) {
        db.execute(
          'INSERT OR REPLACE INTO metadata_preferences (key, value) VALUES (?, ?)',
          [entry.key, entry.value],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  MetadataBinding? find(String sourceKey, String comicId) {
    final key = _identity(sourceKey, comicId);
    if (_bindings.containsKey(key)) return _bindings[key];
    if (_db == null && !File(databasePath).existsSync()) return null;
    final rows = _open().select(
      'SELECT * FROM metadata_overrides WHERE source_key = ? AND comic_id = ?',
      [sourceKey, comicId],
    );
    if (rows.isEmpty) return _bindings[key] = null;
    try {
      final row = rows.single;
      return _bindings[key] = MetadataBinding(
        sourceKey: sourceKey,
        comicId: comicId,
        result: MetadataResult.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['result_json'] as String)),
        ),
        cacheCover: row['cache_cover'] == 1,
        coverPath: row['cover_path'] as String?,
        updatedAt: DateTime.fromMicrosecondsSinceEpoch(
          row['updated_at'] as int,
        ),
      );
    } catch (_) {
      // A corrupt optional override must not hide the underlying comic.
      return _bindings[key] = null;
    }
  }

  void save(MetadataBinding binding) {
    if (binding.sourceKey.isEmpty || binding.comicId.isEmpty) {
      throw const FormatException('A comic identity is required');
    }
    if (binding.result.title.trim().isEmpty) {
      throw const FormatException('The metadata title is empty');
    }
    if (binding.coverPath != null) _checkCoverPath(binding.coverPath!);
    // Only publish in memory after SQLite has committed the complete row.
    _open().execute(
      '''INSERT INTO metadata_overrides
         (source_key, comic_id, result_json, cache_cover, cover_path, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(source_key, comic_id) DO UPDATE SET
         result_json=excluded.result_json, cache_cover=excluded.cache_cover,
         cover_path=excluded.cover_path, updated_at=excluded.updated_at''',
      [
        binding.sourceKey,
        binding.comicId,
        jsonEncode(binding.result.toJson()),
        binding.cacheCover ? 1 : 0,
        binding.coverPath,
        binding.updatedAt.microsecondsSinceEpoch,
      ],
    );
    _bindings[binding.identity] = binding;
    notifyListeners();
  }

  void remove(String sourceKey, String comicId) {
    final previous = find(sourceKey, comicId);
    if (_db != null || File(databasePath).existsSync()) {
      _open().execute(
        'DELETE FROM metadata_overrides WHERE source_key = ? AND comic_id = ?',
        [sourceKey, comicId],
      );
    }
    _bindings[_identity(sourceKey, comicId)] = null;
    if (previous?.coverPath != null) {
      try {
        final file = coverFile(previous!.coverPath!);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // Metadata removal is committed even if an unused image cannot be deleted.
      }
    }
    notifyListeners();
  }

  void _checkCoverPath(String value) {
    if (!RegExp(r'^[a-f0-9]{64}\.cover$').hasMatch(value)) {
      throw const FormatException('Invalid metadata cover path');
    }
  }

  File coverFile(String basename) {
    _checkCoverPath(basename);
    return File('$coverDirectory/$basename');
  }

  String? coverKey(MetadataBinding binding) {
    if (binding.result.coverUrl?.isNotEmpty != true) return null;
    final identity = base64Url.encode(utf8.encode(binding.identity));
    return '$metadataCoverScheme://binding/$identity'
        '?v=${binding.updatedAt.microsecondsSinceEpoch}';
  }

  MetadataBinding? bindingForCoverKey(String key) {
    final uri = Uri.tryParse(key);
    if (uri?.scheme != metadataCoverScheme ||
        uri?.host != 'binding' ||
        uri?.pathSegments.length != 1) {
      return null;
    }
    try {
      final parts = jsonDecode(
        utf8.decode(base64Url.decode(uri!.pathSegments.single)),
      );
      if (parts is! List ||
          parts.length != 2 ||
          parts.any((p) => p is! String)) {
        return null;
      }
      final binding = find(parts[0] as String, parts[1] as String);
      if (binding == null || coverKey(binding) != key) return null;
      return binding;
    } catch (_) {
      return null;
    }
  }

  ComicDetails applyDetails(ComicDetails value) {
    final base = originalDetails(value);
    final binding = find(base.sourceKey, base.id);
    if (binding == null) return base;
    final details = ComicDetails.withMetadata(
      base,
      title: binding.result.title,
      subtitle: binding.result.authors.isEmpty
          ? null
          : binding.result.authors.join(', '),
      description: binding.result.description.isEmpty
          ? null
          : binding.result.description,
      tags: {
        for (final entry in base.tags.entries)
          if (binding.result.authors.isEmpty || !isAuthorNamespace(entry.key))
            entry.key: entry.value,
        ...binding.result.tags,
        if (binding.result.authors.isNotEmpty) 'author': binding.result.authors,
      },
      cover: coverKey(binding),
      externalIds: {
        ...base.externalIds,
        binding.result.reference.provider.name: binding.result.reference.id,
      },
    );
    _baseDetails[details] = base;
    return details;
  }

  Comic applyComic(Comic base) {
    final binding = find(base.sourceKey, base.id);
    if (binding == null) return base;
    return Comic(
      binding.result.title,
      coverKey(binding) ?? base.cover,
      base.id,
      binding.result.authors.isEmpty
          ? base.subtitle
          : binding.result.authors.join(', '),
      {
        ...?base.tags,
        for (final entry in binding.result.tags.entries)
          ...entry.value.map((tag) => '${entry.key}:$tag'),
      }.toList(),
      binding.result.description.isEmpty
          ? base.description
          : binding.result.description,
      base.sourceKey,
      base.maxPage,
      base.language,
    );
  }

  static ComicDetails applyAppDetails(ComicDetails details) =>
      appOrNull?.applyDetails(details) ?? details;

  static ComicDetails originalDetails(ComicDetails details) =>
      _baseDetails[details] ?? details;

  static Comic applyAppComic(Comic comic) =>
      appOrNull?.applyComic(comic) ?? comic;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _db?.close();
    _db = null;
    super.dispose();
  }
}
