import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'cloud_home_cache.dart';
import 'cloud_home_models.dart';
import 'cloud_home_source.dart';

export 'cloud_home_models.dart';
export 'cloud_home_source.dart' show homeRemoteLocationSetting;

const _overridesSetting = 'homeRemoteDirectoryOverrides';

/// Direct-directory home browser. The view owns screen pagination and asks
/// [preload] for its visible and next screen, rather than recursively indexing
/// the library. Every readable file retains its absolute-path comic ID.
class CloudHomeController extends ChangeNotifier {
  CloudHomeController({
    RemoteStorageAccounts? accounts,
    CloudHomeDirectoryCache? cache,
    RemoteFileStore Function(String accountId)? storeFactory,
    Future<String> Function(RemoteLocation location)? ensureSource,
    Future<String?> Function(String sourceKey, String path)? preloadComic,
  }) : _accounts = accounts ?? RemoteStorageAccounts.instance,
       _cache = cache ?? CloudHomeDirectoryCache(),
       _storeFactory = storeFactory,
       _ensureSource = ensureSource,
       _preloadComic = preloadComic;

  final RemoteStorageAccounts _accounts;
  final CloudHomeDirectoryCache _cache;
  final RemoteFileStore Function(String)? _storeFactory;
  final Future<String> Function(RemoteLocation)? _ensureSource;
  final Future<String?> Function(String, String)? _preloadComic;
  final _work = _CloudHomeWorkQueue(maxConcurrent: 2);
  // Reader inspection/cover rendering can be slow. It must never occupy the
  // directory-listing slots needed by foreground navigation.
  final _detailWork = _CloudHomeWorkQueue(maxConcurrent: 1);
  final _memory = <String, CloudHomeDirectorySnapshot>{};
  final _listings = <String, _CloudHomeListing>{};
  final _kinds = <String, CloudHomeItemKind>{};
  final _counts = <String, int>{};
  final _covers = <String, String>{};
  final _detailsReady = <String>{};

  RemoteLocation? _location;
  RemoteFileStore? _store;
  String _sourceKey = '';
  String _directory = '/';
  List<CloudHomeItem> _items = const [];
  bool _isLoading = false;
  bool _isRefreshing = false;
  String? _error;
  DateTime? _refreshedAt;
  bool _initialized = false;
  bool _disposed = false;
  bool _writingLocation = false;
  int _bindingGeneration = 0;
  int _navigationGeneration = 0;
  int _preloadGeneration = 0;
  String? _preloadSignature;
  String _accountSignature = '';
  Future<void>? _initialization;

  RemoteLocation? get location => _location;
  String get directory => _directory;
  List<CloudHomeItem> get items => _items;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  String? get error => _error;
  DateTime? get refreshedAt => _refreshedAt;
  String get sourceKey => _sourceKey;
  bool get canGoUp => _location != null && _directory != _location!.directory;
  CloudHomeItemKind get directoryKind =>
      !canGoUp ? CloudHomeItemKind.directory : _kind(_directory);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (_disposed) return;
    _initialized = true;
    appdata.settings.addListener(_settingsChanged);
    _accounts.addListener(_accountsChanged);
    await _applyBinding(readCloudHomeLocation());
  }

  Future<void> bind(RemoteLocation value) async {
    value = value.normalized();
    if (_accounts.account(value.accountId) == null) {
      throw ArgumentError('Cloud storage account is unavailable');
    }
    _writingLocation = true;
    try {
      appdata.settings[homeRemoteLocationSetting] = value.toJson();
      await appdata.saveData();
    } finally {
      _writingLocation = false;
    }
    await _applyBinding(value);
  }

  Future<void> unbind() async {
    _writingLocation = true;
    try {
      appdata.settings[homeRemoteLocationSetting] = null;
      await appdata.saveData();
    } finally {
      _writingLocation = false;
    }
    await _applyBinding(null);
  }

  void _settingsChanged() {
    if (_disposed || _writingLocation) return;
    final value = readCloudHomeLocation();
    if (_locationKey(value) != _locationKey(_location)) {
      unawaited(_applyBinding(value));
    } else {
      _rebuildItems();
    }
  }

  void _accountsChanged() {
    if (_disposed || _location == null) return;
    final signature = _currentAccountSignature();
    if (signature != _accountSignature) {
      unawaited(_applyBinding(_location));
    }
  }

  String _currentAccountSignature() {
    final account = _location == null
        ? null
        : _accounts.account(_location!.accountId);
    return account == null
        ? ''
        : jsonEncode([
            account.id,
            account.backend.name,
            account.driver,
            account.authorization,
          ]);
  }

  static String _locationKey(RemoteLocation? value) =>
      value == null ? '' : jsonEncode(value.normalized().toJson());

  Future<void> _applyBinding(RemoteLocation? value) async {
    if (_disposed) return;
    final generation = ++_bindingGeneration;
    _navigationGeneration++;
    _preloadGeneration++;
    _preloadSignature = null;
    _work.discardObsolete();
    _detailWork.discardObsolete();
    final oldStore = _store;
    _store = null;
    if (oldStore != null) {
      unawaited(_releaseStore(oldStore));
    }
    _location = value?.normalized();
    _directory = _location?.directory ?? '/';
    _sourceKey = _location == null
        ? ''
        : cloudHomeLibrary(_location!).sourceKey;
    _items = const [];
    _memory.clear();
    _listings.clear();
    _kinds.clear();
    _counts.clear();
    _covers.clear();
    _detailsReady.clear();
    _error = null;
    _refreshedAt = null;
    _isLoading = value != null;
    _isRefreshing = false;
    _accountSignature = _currentAccountSignature();
    _notify();
    if (_location == null) return;
    try {
      final location = _location!;
      _store = (_storeFactory ?? _accounts.storeFor)(location.accountId);
      final key =
          await (_ensureSource?.call(location) ??
              ensureCloudHomeSource(location, accounts: _accounts));
      if (!_bindingIsCurrent(generation)) return;
      _sourceKey = key;
      await _loadDirectory(location.directory);
    } catch (error) {
      if (!_bindingIsCurrent(generation)) return;
      // Even a temporarily unavailable account/source should retain its last
      // cached directory instead of replacing the home with an empty list.
      final cached = await _cache.read(_sourceKey, _directory);
      if (!_bindingIsCurrent(generation)) return;
      if (cached != null) _showSnapshot(cached);
      _error = '$error';
      _isLoading = false;
      _isRefreshing = false;
      _notify();
    }
  }

  Future<void> openDirectory(String path) async {
    if (_location == null || _disposed) return;
    path = normalizeRemoteDirectory(path);
    if (!_isWithinRoot(path)) {
      throw ArgumentError('Directory is outside the home folder');
    }
    await _loadDirectory(path);
  }

  Future<void> goUp() async {
    if (!canGoUp) return;
    final segments = _directory.split('/')..removeWhere((item) => item.isEmpty);
    segments.removeLast();
    await openDirectory('/${segments.join('/')}/');
  }

  Future<void> refresh() async {
    if (_disposed || _location == null) return;
    if (_store == null) {
      await _applyBinding(_location);
    } else {
      await _loadDirectory(_directory);
    }
  }

  bool _isWithinRoot(String path) {
    final root = _location?.directory;
    return root != null && (path == root || path.startsWith(root));
  }

  bool _bindingIsCurrent(int generation) =>
      !_disposed && generation == _bindingGeneration;

  bool _navigationIsCurrent(int generation) =>
      !_disposed && generation == _navigationGeneration;

  Future<void> _loadDirectory(String path) async {
    final generation = ++_navigationGeneration;
    _preloadGeneration++;
    _preloadSignature = null;
    _work.discardObsolete();
    _detailWork.discardObsolete();
    _detailsReady.clear();
    final sameDirectory = path == _directory;
    _directory = path;
    if (!sameDirectory) _items = const [];
    _error = null;
    _isLoading = _items.isEmpty;
    _isRefreshing = true;
    _refreshedAt = sameDirectory ? _refreshedAt : null;
    _notify();
    final cached = _memory[path] ?? await _cache.read(_sourceKey, path);
    if (!_navigationIsCurrent(generation)) return;
    if (cached != null) {
      _memory[path] = cached;
      _showSnapshot(cached);
      _isLoading = false;
      _notify();
    }
    try {
      final snapshot = await _list(path, foreground: true, refresh: true);
      if (!_navigationIsCurrent(generation)) return;
      _rememberKind(path, snapshot.entries);
      _showSnapshot(snapshot);
    } catch (error) {
      if (!_navigationIsCurrent(generation)) return;
      _error = '$error';
    } finally {
      if (_navigationIsCurrent(generation)) {
        _isLoading = false;
        _isRefreshing = false;
        _notify();
      }
    }
  }

  void _showSnapshot(CloudHomeDirectorySnapshot snapshot) {
    _rememberKind(_directory, snapshot.entries);
    _refreshedAt = snapshot.at;
    _items = _decorate(snapshot.entries);
  }

  List<CloudHomeItem> _decorate(Iterable<RemoteEntry> entries) =>
      List.unmodifiable(
        cloudHomeItems(entries).map(
          (item) => item.copyWith(
            kind: item.isDirectory ? _kind(item.path) : item.kind,
            fileCount: _counts[normalizeRemoteDirectory(item.path)],
            cover: _covers[item.path],
          ),
        ),
      );

  void _rebuildItems() {
    final snapshot = _memory[_directory];
    if (snapshot == null) return;
    final updated = _decorate(snapshot.entries);
    final changed =
        updated.length != _items.length ||
        Iterable<int>.generate(updated.length).any(
          (index) =>
              updated[index].kind != _items[index].kind ||
              updated[index].cover != _items[index].cover ||
              updated[index].fileCount != _items[index].fileCount,
        );
    if (changed) {
      _items = updated;
      _notify();
    }
  }

  CloudHomeDirectoryOverride directoryOverride(String path) {
    final raw = appdata.settings[_overridesSetting];
    if (raw is! Map) return CloudHomeDirectoryOverride.automatic;
    final scope = raw[_sourceKey];
    final value = scope is Map ? scope[normalizeRemoteDirectory(path)] : null;
    return CloudHomeDirectoryOverride.values.firstWhere(
      (item) => item.name == value,
      orElse: () => CloudHomeDirectoryOverride.automatic,
    );
  }

  Future<void> setDirectoryOverride(
    String path,
    CloudHomeDirectoryOverride override,
  ) async {
    path = normalizeRemoteDirectory(path);
    if (!_isWithinRoot(path) || path == _location!.directory) return;
    final raw = appdata.settings[_overridesSetting];
    final all = <String, dynamic>{
      if (raw is Map)
        for (final entry in raw.entries) '${entry.key}': entry.value,
    };
    final previous = all[_sourceKey];
    final scope = <String, dynamic>{
      if (previous is Map)
        for (final entry in previous.entries) '${entry.key}': entry.value,
    };
    if (override == CloudHomeDirectoryOverride.automatic) {
      scope.remove(path);
    } else {
      scope[path] = override.name;
    }
    all[_sourceKey] = scope;
    appdata.settings[_overridesSetting] = all;
    await appdata.saveData();
    _rebuildItems();
    _notify();
  }

  CloudHomeItemKind _kind(String path) {
    path = normalizeRemoteDirectory(path);
    if (path == _location?.directory) return CloudHomeItemKind.directory;
    final override = directoryOverride(path);
    if (override == CloudHomeDirectoryOverride.folder) {
      return CloudHomeItemKind.directory;
    }
    final snapshot = _memory[path];
    if (snapshot != null && override == CloudHomeDirectoryOverride.comic) {
      if (_kinds[path] == CloudHomeItemKind.imageComic) {
        return CloudHomeItemKind.imageComic;
      }
      return classifyCloudHomeDirectory(snapshot.entries, override: override);
    }
    if (override == CloudHomeDirectoryOverride.comic) {
      return CloudHomeItemKind.pdfCollection;
    }
    return _kinds[path] ?? CloudHomeItemKind.directory;
  }

  void _rememberKind(String path, List<RemoteEntry> entries) {
    path = normalizeRemoteDirectory(path);
    _kinds[path] = classifyCloudHomeDirectory(entries);
    _counts[path] = entries
        .where(isVisibleCloudHomeEntry)
        .where(
          (entry) =>
              !entry.isDirectory &&
              (isCloudHomeComicFile(entry.name) ||
                  isComicImageFileName(entry.name)),
        )
        .length;
  }

  /// Warm at most two screens (up to 64 entries), with two directory requests
  /// and one low-priority detail/cover operation. Obsolete work is dropped on
  /// navigation; in-flight work
  /// may fill its old cache but is never published into the new directory.
  Future<void> preload({required int start, required int count}) async {
    if (_disposed || _location == null || _isLoading || count <= 0) return;
    final first = start.clamp(0, _items.length);
    final end = (first + count.clamp(0, 64)).clamp(first, _items.length);
    final signature = '$_navigationGeneration:$first:$end';
    if (_preloadSignature == signature) return;
    _preloadSignature = signature;
    final preloadGeneration = ++_preloadGeneration;
    _work.discardObsolete();
    _detailWork.discardObsolete();
    final bindingGeneration = _bindingGeneration;
    final navigationGeneration = _navigationGeneration;
    bool current() =>
        _bindingIsCurrent(bindingGeneration) &&
        _navigationIsCurrent(navigationGeneration) &&
        preloadGeneration == _preloadGeneration;
    final targets = _items.sublist(first, end);
    final imageProbeBudget = _CloudHomeProbeBudget(32);
    await Future.wait([
      for (final item in targets)
        _preloadItem(item, current, imageProbeBudget).catchError((Object _) {}),
    ]);
    if (current()) _rebuildItems();
  }

  Future<void> _preloadItem(
    CloudHomeItem item,
    bool Function() current,
    _CloudHomeProbeBudget imageProbeBudget,
  ) async {
    if (!current()) return;
    var readable = item.isReadable;
    var file = item.entry;
    if (item.isDirectory) {
      final snapshot = await _list(item.path, isCurrent: current);
      if (!current()) return;
      _rememberKind(item.path, snapshot.entries);
      // Preserve the existing image-directory reader, including its familiar
      // chapter-folder layout, without creating chapters for PDF collections.
      // Every candidate child must contain images, so a mixed PDF/image tree
      // cannot hide files by being opened as the existing image-only reader.
      final children = snapshot.entries.where(isVisibleCloudHomeEntry).toList();
      final directories = children.where((entry) => entry.isDirectory).toList();
      if (_kind(item.path) == CloudHomeItemKind.directory &&
          directoryOverride(item.path) ==
              CloudHomeDirectoryOverride.automatic &&
          directories.isNotEmpty &&
          directories.length <= 16 &&
          children.every(
            (entry) => entry.isDirectory || isComicImageFileName(entry.name),
          ) &&
          directories.every(
            (entry) => WebDavLibrarySource.isChapterDirectoryName(entry.name),
          ) &&
          imageProbeBudget.take(directories.length)) {
        var allImageFolders = true;
        for (final child in directories) {
          final childSnapshot = await _list(child.path, isCurrent: current);
          if (!current()) return;
          final contents = childSnapshot.entries.where(isVisibleCloudHomeEntry);
          if (contents.isEmpty ||
              contents.any(
                (entry) =>
                    entry.isDirectory || !isComicImageFileName(entry.name),
              )) {
            allImageFolders = false;
            break;
          }
        }
        if (allImageFolders) {
          _kinds[normalizeRemoteDirectory(item.path)] =
              CloudHomeItemKind.imageComic;
        }
      }
      readable = _kind(item.path) == CloudHomeItemKind.imageComic;
      if (_kind(item.path) == CloudHomeItemKind.pdfCollection) {
        final candidates = cloudHomeItems(
          snapshot.entries,
        ).where((child) => child.kind == CloudHomeItemKind.comicFile);
        if (candidates.isNotEmpty) {
          file = candidates.first.entry;
          readable = true;
        }
      }
    }
    if (!readable || !current() || _detailsReady.contains(item.path)) return;
    final key = _sourceKey;
    final cover = await _detailWork.run(
      () =>
          RemoteReadContext(priority: RemoteReadPriority.preload).run(() async {
            if (_preloadComic != null) return _preloadComic(key, file.path);
            await WebDavLibraryEngines.find(
              key,
            )?.prepareDirectoryBrowserEntry(file);
            if (!current()) return null;
            final source = ComicSource.find(key);
            final result = await source?.loadComicInfo?.call(file.path);
            if (result == null || result.error) return null;
            final cover = result.data.cover;
            if (cover.isNotEmpty && current()) {
              try {
                await for (final _ in ImageDownloader.loadThumbnail(
                  cover,
                  key,
                  file.path,
                )) {
                  if (!current()) break;
                }
              } catch (_) {
                // A cover failure does not invalidate the parsed file/metadata.
              }
            }
            return cover;
          }),
      isCurrent: current,
    );
    if (!current()) return;
    _detailsReady.add(item.path);
    if (cover?.isNotEmpty == true) _covers[item.path] = cover!;
  }

  Future<CloudHomeDirectorySnapshot> _list(
    String path, {
    bool foreground = false,
    bool refresh = false,
    bool Function()? isCurrent,
  }) async {
    path = normalizeRemoteDirectory(path);
    final binding = _bindingGeneration;
    final store = _store;
    if (store == null) throw StateError('Cloud storage account is unavailable');
    final pending = _listings[path];
    if (pending != null) {
      if (foreground) pending.foreground = true;
      pending.isCurrent = isCurrent;
      try {
        return await pending.future;
      } on _CloudHomeObsolete {
        if (!_bindingIsCurrent(binding) || isCurrent?.call() == false) rethrow;
        if (identical(_listings[path], pending)) _listings.remove(path);
        return _list(
          path,
          foreground: foreground,
          refresh: refresh,
          isCurrent: isCurrent,
        );
      }
    }
    if (!refresh) {
      final cached = _memory[path] ?? await _cache.read(_sourceKey, path);
      if (!_bindingIsCurrent(binding)) throw const _CloudHomeObsolete();
      if (cached != null &&
          DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
        _memory[path] = cached;
        return cached;
      }
    }
    // Reading the disk cache yields. Another consumer may have started the
    // same request while it was pending; join it rather than issuing twice.
    if (_listings.containsKey(path)) {
      return _list(
        path,
        foreground: foreground,
        refresh: true,
        isCurrent: isCurrent,
      );
    }
    final scope = _sourceKey;
    final listing = _CloudHomeListing(
      foreground: foreground,
      isCurrent: isCurrent,
    );
    _listings[path] = listing;
    listing.future = _work
        .run(
          () async {
            final entries = await store.list(path);
            final snapshot = CloudHomeDirectorySnapshot(
              entries: _directEntries(path, entries),
              at: DateTime.now(),
            );
            if (_bindingIsCurrent(binding)) _memory[path] = snapshot;
            try {
              await _cache.write(scope, path, snapshot);
            } catch (_) {
              // A full/read-only cache must not turn a valid listing into failure.
            }
            return snapshot;
          },
          foreground: foreground,
          isCurrent: () =>
              _bindingIsCurrent(binding) &&
              (listing.foreground || listing.isCurrent?.call() != false),
        )
        .whenComplete(() {
          if (identical(_listings[path], listing)) _listings.remove(path);
        });
    return listing.future;
  }

  static List<RemoteEntry> _directEntries(
    String directory,
    List<RemoteEntry> entries,
  ) {
    final seen = <String>{};
    return List.unmodifiable([
      for (final entry in entries)
        if (entry.name.isNotEmpty &&
            entry.name != '.' &&
            entry.name != '..' &&
            !entry.name.contains('/') &&
            !entry.name.contains('\\') &&
            seen.add(entry.name))
          RemoteEntry(
            name: entry.name,
            path: entry.isDirectory
                ? normalizeRemoteDirectory('$directory${entry.name}')
                : '$directory${entry.name}',
            isDirectory: entry.isDirectory,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            eTag: entry.eTag,
          ),
    ]);
  }

  Future<void> _releaseStore(RemoteFileStore store) async {
    try {
      await store.cancelAll();
    } catch (_) {
      // Local navigation and disposal remain available after network failure.
    } finally {
      _accounts.release(store);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindingGeneration++;
    _navigationGeneration++;
    _preloadGeneration++;
    _work.discardObsolete();
    _detailWork.discardObsolete();
    if (_initialized) {
      appdata.settings.removeListener(_settingsChanged);
      _accounts.removeListener(_accountsChanged);
    }
    final store = _store;
    _store = null;
    if (store != null) unawaited(_releaseStore(store));
    super.dispose();
  }
}

class _CloudHomeListing {
  _CloudHomeListing({required this.foreground, this.isCurrent});
  bool foreground;
  bool Function()? isCurrent;
  late Future<CloudHomeDirectorySnapshot> future;
}

class _CloudHomeProbeBudget {
  _CloudHomeProbeBudget(this.remaining);
  int remaining;

  bool take(int count) {
    if (count > remaining) return false;
    remaining -= count;
    return true;
  }
}

class _CloudHomeObsolete implements Exception {
  const _CloudHomeObsolete();
}

class _CloudHomeWorkQueue {
  _CloudHomeWorkQueue({required this.maxConcurrent});
  final int maxConcurrent;
  final _queue = <_CloudHomeWork<dynamic>>[];
  int _active = 0;

  Future<T> run<T>(
    Future<T> Function() action, {
    required bool Function() isCurrent,
    bool foreground = false,
  }) {
    final work = _CloudHomeWork(action, isCurrent);
    foreground ? _queue.insert(0, work) : _queue.add(work);
    _pump();
    return work.result.future;
  }

  void discardObsolete() {
    for (final work in _queue.toList()) {
      if (!work.isCurrent()) {
        _queue.remove(work);
        work.result.completeError(const _CloudHomeObsolete());
      }
    }
  }

  void _pump() {
    discardObsolete();
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final work = _queue.removeAt(0);
      _active++;
      unawaited(() async {
        try {
          work.result.complete(await work.action());
        } catch (error, stack) {
          work.result.completeError(error, stack);
        } finally {
          _active--;
          _pump();
        }
      }());
    }
  }
}

class _CloudHomeWork<T> {
  _CloudHomeWork(this.action, this.isCurrent);
  final Future<T> Function() action;
  final bool Function() isCurrent;
  final result = Completer<T>();
}
