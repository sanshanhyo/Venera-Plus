import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

class CloudHomeDirectorySnapshot {
  const CloudHomeDirectorySnapshot({required this.entries, required this.at});
  final List<RemoteEntry> entries;
  final DateTime at;
}

/// Independent of the recursive comic index. Each file contains exactly one
/// directory listing, so a failed/partial refresh cannot erase another folder.
class CloudHomeDirectoryCache {
  CloudHomeDirectoryCache({String? directoryPath})
    : _directoryPath = directoryPath;

  final String? _directoryPath;
  static final _writeTails = <String, Future<void>>{};
  String get _root => _directoryPath ?? '${App.dataPath}/cloud_home';

  File _file(String scope, String directory) {
    final scopeHash = sha256.convert(utf8.encode(scope)).toString();
    final pathHash = sha256.convert(utf8.encode(directory)).toString();
    return File('$_root/$scopeHash/$pathHash.json');
  }

  Future<CloudHomeDirectorySnapshot?> read(
    String scope,
    String directory,
  ) async {
    try {
      final json = jsonDecode(await _file(scope, directory).readAsString());
      if (json is! Map ||
          json['version'] != 1 ||
          json['directory'] != directory ||
          json['entries'] is! List ||
          json['at'] is! int) {
        return null;
      }
      final entries = <RemoteEntry>[];
      for (final value in json['entries'] as List) {
        if (value is! Map ||
            value['name'] is! String ||
            value['path'] is! String ||
            value['isDirectory'] is! bool) {
          return null;
        }
        entries.add(
          RemoteEntry(
            name: value['name'] as String,
            path: value['path'] as String,
            isDirectory: value['isDirectory'] as bool,
            size: (value['size'] as num?)?.toInt(),
            modifiedAt: (value['modifiedAt'] as num?)?.toInt(),
            eTag: value['eTag'] as String?,
          ),
        );
      }
      return CloudHomeDirectorySnapshot(
        entries: List.unmodifiable(entries),
        at: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String scope,
    String directory,
    CloudHomeDirectorySnapshot snapshot, {
    bool Function()? isCurrent,
  }) {
    final path = _file(scope, directory).path;
    final previous = _writeTails[path] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((Object _) {})
        .then((_) => _writeSnapshot(scope, directory, snapshot, isCurrent))
        .whenComplete(() {
          if (identical(_writeTails[path], next)) _writeTails.remove(path);
        });
    _writeTails[path] = next;
    return next;
  }

  Future<void> _writeSnapshot(
    String scope,
    String directory,
    CloudHomeDirectorySnapshot snapshot,
    bool Function()? isCurrent,
  ) async {
    if (isCurrent?.call() == false) return;
    final file = _file(scope, directory);
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'directory': directory,
          'at': snapshot.at.millisecondsSinceEpoch,
          'entries': [
            for (final entry in snapshot.entries)
              {
                'name': entry.name,
                'path': entry.path,
                'isDirectory': entry.isDirectory,
                'size': entry.size,
                'modifiedAt': entry.modifiedAt,
                'eTag': entry.eTag,
              },
          ],
        }),
        flush: true,
      );
      if (isCurrent?.call() != false) await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
