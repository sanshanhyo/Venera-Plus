import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'cloud_home_models.dart';

const homeRemoteLocationSetting = 'homeRemoteLocation';
const homeRemoteSourcesSetting = 'homeRemoteSources';
const homeRemoteLibraryMountSetting = 'homeRemoteLibraryMount';

CloudHomeLibraryMount? readCloudHomeMount() {
  final value = appdata.settings[homeRemoteLibraryMountSetting];
  if (value is! Map) return null;
  try {
    final mount = CloudHomeLibraryMount.fromJson(value);
    return mount.libraryId.isEmpty ? null : mount;
  } catch (_) {
    return null;
  }
}

bool isDirectoryInCloudHomeLibrary(RemoteLibrary library, String directory) {
  final normalized = normalizeRemoteDirectory(directory);
  return library.directories.any((root) {
    root = normalizeRemoteDirectory(root);
    return normalized == root || normalized.startsWith(root);
  });
}

/// Reuses the library's normal reader/explore source. Mounting home never
/// creates a second library, replaces its explore page with a hidden source,
/// or invokes the recursive comic index.
Future<String> ensureImportedCloudHomeSource(
  RemoteLibrary library, {
  RemoteStorageAccounts? accounts,
}) async {
  final storage = accounts ?? RemoteStorageAccounts.instance;
  final account = storage.account(library.accountId);
  if (account == null) throw StateError('Cloud storage account is unavailable');
  final current = WebDavLibraryEngines.find(library.sourceKey);
  final manager = ComicSourceManager();
  final previous = manager.find(library.sourceKey);
  if (current != null &&
      current.matches(library, account) &&
      previous != null) {
    return library.sourceKey;
  }
  final engine = current != null && current.matches(library, account)
      ? current
      : WebDavLibraryEngine(
          library: library,
          store: storage.storeFor(library.accountId),
        );
  WebDavLibraryEngines.replace(engine);
  final source = engine.create();
  if (previous != null) {
    source.shareSessionWith(previous);
    manager.remove(library.sourceKey);
  }
  manager.add(source);
  return library.sourceKey;
}

RemoteLocation? readCloudHomeLocation() {
  final value = appdata.settings[homeRemoteLocationSetting];
  if (value is! Map) return null;
  try {
    final location = RemoteLocation.fromJson(value);
    return location.accountId.isEmpty ? null : location;
  } catch (_) {
    return null;
  }
}

/// Retaining these credential-free relations keeps previously favourited files
/// and reading history usable after changing the home folder or account.
List<RemoteLibrary> readCloudHomeSources() {
  final raw = appdata.settings[homeRemoteSourcesSetting];
  if (raw is! List) return const [];
  final result = <RemoteLibrary>[];
  for (final value in raw.whereType<Map>()) {
    try {
      final library = RemoteLibrary.fromJson(value);
      if (library.id.isNotEmpty &&
          library.sourceKey.startsWith('cloud_home_') &&
          library.accountId.isNotEmpty &&
          library.directories.length == 1 &&
          !result.any((item) => item.sourceKey == library.sourceKey)) {
        result.add(library.copyWith(autoRefresh: false));
      }
    } catch (_) {
      // A malformed imported relation must not block every other source.
    }
  }
  return result;
}

RemoteLibrary? findCloudHomeSource(String sourceKey) {
  for (final library in readCloudHomeSources()) {
    if (library.sourceKey == sourceKey) return library;
  }
  return null;
}

RemoteLibrary cloudHomeLibrary(RemoteLocation location) {
  location = location.normalized();
  for (final library in readCloudHomeSources()) {
    if (library.accountId == location.accountId &&
        library.directories.single == location.directory) {
      return library;
    }
  }
  final digest = sha256
      .convert(utf8.encode(jsonEncode(location.toJson())))
      .toString();
  return RemoteLibrary(
    id: 'cloud-home-$digest',
    sourceKey: 'cloud_home_$digest',
    accountId: location.accountId,
    directories: [location.directory],
    name: 'Cloud Home',
    autoRefresh: false,
  );
}

Future<String> ensureCloudHomeSource(
  RemoteLocation location, {
  RemoteStorageAccounts? accounts,
}) async {
  final storage = accounts ?? RemoteStorageAccounts.instance;
  final library = cloudHomeLibrary(location);
  final account = storage.account(library.accountId);
  if (account == null) throw StateError('Cloud storage account is unavailable');
  final relations = readCloudHomeSources();
  if (!relations.any((item) => item.sourceKey == library.sourceKey)) {
    appdata.settings[homeRemoteSourcesSetting] = [
      for (final value in relations) value.toJson(),
      library.toJson(),
    ];
    await appdata.saveData(false);
  }
  final current = WebDavLibraryEngines.find(library.sourceKey);
  final engine = current != null && current.matches(library, account)
      ? current
      : WebDavLibraryEngine(
          library: library,
          store: storage.storeFor(library.accountId),
        );
  final manager = ComicSourceManager();
  final previous = manager.find(library.sourceKey);
  if (!identical(current, engine) || previous == null) {
    WebDavLibraryEngines.replace(engine);
    final source = engine.create(directoryBrowser: true);
    if (previous != null) {
      source.shareSessionWith(previous);
      manager.remove(library.sourceKey);
    }
    manager.add(source);
  }
  return library.sourceKey;
}
