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
export 'cloud_home_source.dart'
    show
        homeRemoteLocationSetting,
        homeRemoteLibraryMountSetting,
        readCloudHomeMount;

const _overridesSetting = 'homeRemoteDirectoryOverrides';

/// Direct-directory home browser. The view owns screen pagination and asks
/// [preload] for its visible and next screen, rather than recursively indexing
/// the library. Reading IDs come from the imported library, preserving legacy
/// relative IDs and the library's existing history/favourite identities.
class CloudHomeController extends ChangeNotifier {
  CloudHomeController({
    RemoteStorageAccounts? accounts,
    CloudHomeDirectoryCache? cache,
    RemoteFileStore Function(String accountId)? storeFactory,
    Future<String> Function(RemoteLibrary library)? ensureSource,
    Future<String?> Function(String sourceKey, String path)? preloadComic,
  }) : _accounts = accounts ?? RemoteStorageAccounts.instance,
       _cache = cache ?? CloudHomeDirectoryCache(),
       _storeFactory = storeFactory,
       _ensureSource = ensureSource,
       _preloadComic = preloadComic;

  final RemoteStorageAccounts _accounts;
  final CloudHomeDirectoryCache _cache;
  final RemoteFileStore Function(String)? _storeFactory;
  final Future<String> Function(RemoteLibrary)? _ensureSource;
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
  final _invalidatedDirectories = <String>{};

  RemoteLocation? _location;
  CloudHomeLibraryMount? _mount;
  RemoteLibrary? _mountedLibrary;
  String? _activeLibraryRoot;
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
  int _listingEpoch = 0;
  String? _preloadSignature;
  Object _bindingToken = Object();
  String _accountSignature = '';
  Future<void>? _initialization;

  RemoteLocation? get location => _location;
  CloudHomeLibraryMount? get mount {
    final value = _mount;
    final library = _mountedLibrary;
    if (value?.directory != null &&
        library != null &&
        !isDirectoryInCloudHomeLibrary(library, value!.directory!)) {
      // Editing a library's roots can invalidate a saved starting directory.
      // Expose its effective library-home fallback to the settings dialog.
      return CloudHomeLibraryMount(libraryId: value.libraryId);
    }
    return value;
  }

  RemoteLibrary? get mountedLibrary => _mountedLibrary;
  List<RemoteLibrary> get libraries {
    try {
      return RemoteComicLibraryRegistry.read();
    } catch (_) {
      return const [];
    }
  }

  List<String> get rootDirectories =>
      List.unmodifiable(_mountedLibrary?.directories ?? const []);
  bool get isVirtualLibraryRoot =>
      _mountedLibrary != null && _directory.isEmpty;
  bool get isLibraryRoot => isVirtualLibraryRoot;
  String get directory => _directory;
  List<CloudHomeItem> get items => _items;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  String? get error => _error;
  DateTime? get refreshedAt => _refreshedAt;
  String get sourceKey => _sourceKey;
  bool get canGoUp =>
      _mountedLibrary != null &&
      !isVirtualLibraryRoot &&
      _directory != _navigationRoot;
  CloudHomeItemKind get directoryKind =>
      !canGoUp ? CloudHomeItemKind.directory : _kind(_directory);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (_disposed) return;
    _initialized = true;
    appdata.settings.addListener(_settingsChanged);
    _accounts.addListener(_accountsChanged);
    var value = readCloudHomeMount();
    if (value == null) {
      final legacy = readCloudHomeLocation();
      if (legacy != null) {
        final candidates = _matchingLibraries(legacy);
        if (candidates.length == 1) {
          value = CloudHomeLibraryMount(
            libraryId: candidates.single.id,
            directory: legacy.directory,
          );
          await _writeMount(
            value,
            overrides: _legacyOverridesFor(legacy, candidates.single),
          );
        }
      }
    }
    await _applyBinding(value);
  }

  /// Compatibility for callers holding an old location. A location can only
  /// mount a uniquely matching imported library; it never creates a source.
  Future<void> bind(RemoteLocation value) async {
    value = value.normalized();
    final candidates = _matchingLibraries(value);
    if (candidates.length != 1) {
      throw ArgumentError('Select an imported comic library');
    }
    await bindLibrary(candidates.single.id, directory: value.directory);
  }

  List<RemoteLibrary> _matchingLibraries(RemoteLocation location) => [
    for (final library in libraries)
      if (library.accountId == location.accountId &&
          isDirectoryInCloudHomeLibrary(library, location.directory))
        library,
  ];

  RemoteLibrary? _findLibrary(String? id) {
    for (final library in libraries) {
      if (library.id == id) return library;
    }
    return null;
  }

  Future<void> bindLibrary(String libraryId, {String? directory}) async {
    final library = _findLibrary(libraryId);
    if (library == null) {
      throw ArgumentError('Comic library is unavailable');
    }
    final normalized = directory == null
        ? null
        : normalizeRemoteDirectory(directory);
    if (normalized != null &&
        !isDirectoryInCloudHomeLibrary(library, normalized)) {
      throw ArgumentError('Directory is outside the imported comic library');
    }
    final value = CloudHomeLibraryMount(
      libraryId: libraryId,
      directory: normalized,
    );
    await _writeMount(value);
    await _applyBinding(value);
  }

  Future<void> setCurrentDirectoryAsHome() async {
    if (_mountedLibrary == null || isVirtualLibraryRoot) return;
    await bindLibrary(_mountedLibrary!.id, directory: _directory);
  }

  Map<String, dynamic>? _legacyOverridesFor(
    RemoteLocation location,
    RemoteLibrary library,
  ) {
    final raw = appdata.settings[_overridesSetting];
    if (raw is! Map) return null;
    final previous = raw[cloudHomeLibrary(location).sourceKey];
    if (previous is! Map) return null;
    final migrated = <String, dynamic>{};
    for (final entry in previous.entries) {
      if (entry.key is! String ||
          !CloudHomeDirectoryOverride.values.any(
            (value) => value.name == entry.value,
          )) {
        continue;
      }
      try {
        final path = normalizeRemoteDirectory(entry.key as String);
        if (isDirectoryInCloudHomeLibrary(library, path)) {
          migrated[path] = entry.value;
        }
      } on FormatException {
        // Invalid legacy paths must not escape the newly mounted library.
      }
    }
    if (migrated.isEmpty) return null;
    final existing = raw[library.sourceKey];
    return {
      for (final entry in raw.entries) '${entry.key}': entry.value,
      library.sourceKey: {
        ...migrated,
        if (existing is Map)
          for (final entry in existing.entries) '${entry.key}': entry.value,
      },
    };
  }

  Future<void> _writeMount(
    CloudHomeLibraryMount? value, {
    Map<String, dynamic>? overrides,
  }) async {
    _writingLocation = true;
    try {
      appdata.settings[homeRemoteLibraryMountSetting] = value?.toJson();
      // Stop the previous account/folder binding from being re-imported.
      appdata.settings[homeRemoteLocationSetting] = null;
      if (overrides != null) appdata.settings[_overridesSetting] = overrides;
      await appdata.saveData();
    } finally {
      _writingLocation = false;
    }
  }

  Future<void> unbind() async {
    await _writeMount(null);
    await _applyBinding(null);
  }

  void _settingsChanged() {
    if (_disposed || _writingLocation) return;
    final value = readCloudHomeMount();
    if (_mountKey(value) != _mountKey(_mount) ||
        _currentConfigurationSignature(value) != _accountSignature) {
      unawaited(_applyBinding(value, preserveDirectory: true));
    } else {
      _rebuildItems();
      // An unmounted settings dialog also needs to see newly imported libraries.
      _notify();
    }
  }

  void _accountsChanged() {
    if (_disposed || _mount == null) return;
    final signature = _currentConfigurationSignature(_mount);
    if (signature != _accountSignature) {
      unawaited(_applyBinding(_mount, preserveDirectory: true));
    }
  }

  String _currentConfigurationSignature(CloudHomeLibraryMount? mount) {
    final library = _findLibrary(mount?.libraryId);
    final account = library == null
        ? null
        : _accounts.account(library.accountId);
    return jsonEncode([
      library?.toJson(),
      if (account != null)
        [
          account.id,
          account.backend.name,
          account.driver,
          account.authorization,
        ],
    ]);
  }

  static String _mountKey(CloudHomeLibraryMount? value) =>
      value == null ? '' : jsonEncode(value.normalized().toJson());

  String get _navigationRoot {
    final library = _mountedLibrary;
    if (library == null) return '';
    final selected = _mount?.directory;
    if (selected != null && isDirectoryInCloudHomeLibrary(library, selected)) {
      return selected;
    }
    return library.directories.length == 1 ? library.directories.single : '';
  }

  bool allowsDirectory(String path) {
    final library = _mountedLibrary;
    return library != null && isDirectoryInCloudHomeLibrary(library, path);
  }

  String comicIdFor(String path) =>
      WebDavLibraryEngines.find(_sourceKey)?.comicIdForPath(path) ?? path;

  Future<List<RemoteEntry>> listLibraryDirectories(
    String libraryId, {
    String? directory,
  }) async {
    final library = _findLibrary(libraryId);
    if (library == null) throw ArgumentError('Comic library is unavailable');
    if (directory == null) return _rootEntries(library);
    final normalized = normalizeRemoteDirectory(directory);
    if (!isDirectoryInCloudHomeLibrary(library, normalized)) {
      throw ArgumentError('Directory is outside the imported comic library');
    }
    final store = (_storeFactory ?? _accounts.storeFor)(library.accountId);
    try {
      final entries = _directEntries(normalized, await store.list(normalized));
      return List.unmodifiable(
        entries.where(
          (entry) => entry.isDirectory && isVisibleCloudHomeEntry(entry),
        ),
      );
    } finally {
      await _releaseStore(store);
    }
  }

  static List<RemoteEntry> _rootEntries(RemoteLibrary library) => [
    for (final root in library.directories)
      RemoteEntry(
        name: root == '/'
            ? library.name
            : root.split('/').where((part) => part.isNotEmpty).last,
        path: root,
        isDirectory: true,
      ),
  ];

  Future<void> _applyBinding(
    CloudHomeLibraryMount? value, {
    bool preserveDirectory = false,
  }) async {
    if (_disposed) return;
    final previousDirectory = _directory;
    final previousMount = _mount;
    final previousSourceKey = _sourceKey;
    final previousLibraryRoot = _activeLibraryRoot;
    final generation = ++_bindingGeneration;
    _bindingToken = Object();
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
    _mount = value?.normalized();
    _mountedLibrary = _findLibrary(_mount?.libraryId);
    _activeLibraryRoot = null;
    _directory = _navigationRoot;
    if (preserveDirectory &&
        _mountKey(previousMount) == _mountKey(_mount) &&
        previousSourceKey == _mountedLibrary?.sourceKey &&
        previousDirectory.isNotEmpty &&
        _isWithinRoot(previousDirectory)) {
      _directory = previousDirectory;
      if (_navigationRoot.isEmpty) {
        _activeLibraryRoot =
            previousLibraryRoot != null &&
                rootDirectories.contains(previousLibraryRoot) &&
                previousDirectory.startsWith(previousLibraryRoot)
            ? previousLibraryRoot
            : _libraryRootFor(previousDirectory);
      }
    }
    _location = _mountedLibrary == null
        ? null
        : RemoteLocation(
            accountId: _mountedLibrary!.accountId,
            directory: _navigationRoot.isEmpty ? '/' : _navigationRoot,
          );
    _sourceKey = _mountedLibrary?.sourceKey ?? '';
    _items = const [];
    _memory.clear();
    _listings.clear();
    _kinds.clear();
    _counts.clear();
    _covers.clear();
    _detailsReady.clear();
    _invalidatedDirectories.clear();
    _error = _mount != null && _mountedLibrary == null
        ? 'Comic library is unavailable'
        : null;
    _refreshedAt = null;
    _isLoading = _mountedLibrary != null;
    _isRefreshing = false;
    _accountSignature = _currentConfigurationSignature(_mount);
    _notify();
    if (_location == null) return;
    try {
      final library = _mountedLibrary!;
      _store = (_storeFactory ?? _accounts.storeFor)(library.accountId);
      final key =
          await (_ensureSource?.call(library) ??
              ensureImportedCloudHomeSource(library, accounts: _accounts));
      if (!_bindingIsCurrent(generation)) return;
      _sourceKey = key;
      if (isVirtualLibraryRoot) {
        _showLibraryRoot();
      } else {
        await _loadDirectory(_directory);
      }
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
    if (_navigationRoot.isEmpty &&
        (_activeLibraryRoot == null || !path.startsWith(_activeLibraryRoot!))) {
      _activeLibraryRoot = _libraryRootFor(path);
    }
    await _loadDirectory(path);
  }

  String _libraryRootFor(String path) {
    final candidates =
        rootDirectories
            .where((root) => path == root || path.startsWith(root))
            .toList()
          ..sort((left, right) => right.length.compareTo(left.length));
    return candidates.first;
  }

  Future<void> goUp() async {
    if (!canGoUp) return;
    if (_navigationRoot.isEmpty && _directory == _activeLibraryRoot) {
      _showLibraryRoot();
      return;
    }
    final segments = _directory.split('/')..removeWhere((item) => item.isEmpty);
    segments.removeLast();
    await openDirectory('/${segments.join('/')}/');
  }

  Future<void> refresh() async {
    if (_disposed || _location == null) return;
    _listingEpoch++;
    for (final item in _items.where((item) => item.isDirectory)) {
      final path = normalizeRemoteDirectory(item.path);
      _invalidatedDirectories.add(path);
      _memory.remove(path);
      _kinds.remove(path);
      _counts.remove(path);
      _covers.remove(item.path);
      _detailsReady.remove(item.path);
    }
    if (_store == null) {
      await _applyBinding(_mount, preserveDirectory: true);
    } else if (isVirtualLibraryRoot) {
      _showLibraryRoot();
    } else {
      await _loadDirectory(_directory);
    }
  }

  bool _isWithinRoot(String path) {
    final root = _navigationRoot;
    return allowsDirectory(path) &&
        (root.isEmpty || path == root || path.startsWith(root));
  }

  void _showLibraryRoot() {
    final library = _mountedLibrary;
    if (library == null || _disposed) return;
    _navigationGeneration++;
    _preloadGeneration++;
    _preloadSignature = null;
    _work.discardObsolete();
    _detailWork.discardObsolete();
    _directory = '';
    _activeLibraryRoot = null;
    _items = List.unmodifiable(
      cloudHomeItems(
        _rootEntries(library),
      ).map((item) => item.copyWith(bindingToken: _bindingToken)),
    );
    _isLoading = false;
    _isRefreshing = false;
    _error = null;
    _refreshedAt = null;
    _notify();
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
            bindingToken: _bindingToken,
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
    if (!_isWithinRoot(path) || _isNavigationRoot(path)) return;
    final binding = _bindingGeneration;
    final sourceKey = _sourceKey;
    if (override == CloudHomeDirectoryOverride.comic) {
      CloudHomeDirectorySnapshot snapshot;
      try {
        snapshot = _memory[path] ?? await _list(path);
      } catch (_) {
        if (!_bindingIsCurrent(binding)) return;
        rethrow;
      }
      if (!_bindingIsCurrent(binding)) return;
      if (classifyCloudHomeDirectory(snapshot.entries, override: override) ==
          CloudHomeItemKind.directory) {
        throw const CloudHomeUnsupportedComicFolder();
      }
    }
    final raw = appdata.settings[_overridesSetting];
    final all = <String, dynamic>{
      if (raw is Map)
        for (final entry in raw.entries) '${entry.key}': entry.value,
    };
    final previous = all[sourceKey];
    final scope = <String, dynamic>{
      if (previous is Map)
        for (final entry in previous.entries) '${entry.key}': entry.value,
    };
    if (override == CloudHomeDirectoryOverride.automatic) {
      scope.remove(path);
    } else {
      scope[path] = override.name;
    }
    all[sourceKey] = scope;
    appdata.settings[_overridesSetting] = all;
    await appdata.saveData();
    _rebuildItems();
    _notify();
  }

  CloudHomeItemKind _kind(String path) {
    path = normalizeRemoteDirectory(path);
    if (_isNavigationRoot(path)) return CloudHomeItemKind.directory;
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
      // Legacy overrides were file-browser labels. Do not make an unverified
      // mixed directory readable under the new chapter-collection semantics.
      return _kinds[path] ?? CloudHomeItemKind.directory;
    }
    return _kinds[path] ?? CloudHomeItemKind.directory;
  }

  bool _isNavigationRoot(String path) =>
      path == _navigationRoot ||
      (_navigationRoot.isEmpty &&
          (_activeLibraryRoot == null
              ? rootDirectories.contains(path)
              : path == _activeLibraryRoot));

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

  /// Resolves a tapped directory before navigation without waiting for covers
  /// or for the remainder of a background prefetch batch.
  Future<CloudHomeItem?> resolveItemForOpen(CloudHomeItem item) async {
    if (_disposed ||
        _location == null ||
        !identical(item.bindingToken, _bindingToken) ||
        !_items.any((current) => current.path == item.path)) {
      return null;
    }
    try {
      if (!_isWithinRoot(item.path)) return null;
    } on FormatException {
      return null;
    }
    if (!item.isDirectory || _isNavigationRoot(item.path)) return item;
    final binding = _bindingGeneration;
    final navigation = _navigationGeneration;
    bool current() =>
        _bindingIsCurrent(binding) && _navigationIsCurrent(navigation);
    try {
      await _resolveDirectory(
        item.path,
        current,
        _CloudHomeProbeBudget(32),
        foreground: true,
      );
    } on _CloudHomeObsolete {
      return null;
    }
    if (!current()) return null;
    _rebuildItems();
    return item.copyWith(
      kind: _kind(item.path),
      fileCount: _counts[normalizeRemoteDirectory(item.path)],
      cover: _covers[item.path],
    );
  }

  Future<void> _resolveDirectory(
    String path,
    bool Function() current,
    _CloudHomeProbeBudget imageProbeBudget, {
    bool foreground = false,
  }) async {
    final snapshot = await _list(
      path,
      foreground: foreground,
      isCurrent: current,
    );
    if (!current()) return;
    _rememberKind(path, snapshot.entries);
    if (_isNavigationRoot(path)) return;
    final children = snapshot.entries.where(isVisibleCloudHomeEntry).toList();
    final directories = children.where((entry) => entry.isDirectory).toList();
    if (_kind(path) == CloudHomeItemKind.directory &&
        directoryOverride(path) == CloudHomeDirectoryOverride.automatic &&
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
        final childSnapshot = await _list(
          child.path,
          foreground: foreground,
          isCurrent: current,
        );
        if (!current()) return;
        final contents = childSnapshot.entries.where(isVisibleCloudHomeEntry);
        if (contents.isEmpty ||
            contents.any(
              (entry) => entry.isDirectory || !isComicImageFileName(entry.name),
            )) {
          allImageFolders = false;
          break;
        }
      }
      if (allImageFolders) {
        _kinds[normalizeRemoteDirectory(path)] = CloudHomeItemKind.imageComic;
      }
    }
  }

  Future<void> _preloadItem(
    CloudHomeItem item,
    bool Function() current,
    _CloudHomeProbeBudget imageProbeBudget,
  ) async {
    if (!current()) return;
    var readable = item.isReadable;
    final file = item.entry;
    if (item.isDirectory) {
      await _resolveDirectory(item.path, current, imageProbeBudget);
      readable = const {
        CloudHomeItemKind.imageComic,
        CloudHomeItemKind.pdfCollection,
      }.contains(_kind(item.path));
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
            final id = comicIdFor(file.path);
            final result = await source?.loadComicInfo?.call(id);
            if (result == null || result.error) return null;
            final cover = result.data.cover;
            if (cover.isNotEmpty && current()) {
              try {
                await for (final _ in ImageDownloader.loadThumbnail(
                  cover,
                  key,
                  id,
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
    final epoch = _listingEpoch;
    final store = _store;
    if (store == null) throw StateError('Cloud storage account is unavailable');
    final pending = _listings[path];
    if (pending != null && pending.epoch == epoch) {
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
    if (!refresh && !_invalidatedDirectories.contains(path)) {
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
    if (_listings[path]?.epoch == epoch) {
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
      epoch: epoch,
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
            if (_bindingIsCurrent(binding) && epoch == _listingEpoch) {
              _memory[path] = snapshot;
              _invalidatedDirectories.remove(path);
              try {
                await _cache.write(
                  scope,
                  path,
                  snapshot,
                  isCurrent: () =>
                      _bindingIsCurrent(binding) && epoch == _listingEpoch,
                );
              } catch (_) {
                // A full/read-only cache must not turn a valid listing into failure.
              }
            }
            return snapshot;
          },
          foreground: foreground,
          isForeground: () => listing.foreground,
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
  _CloudHomeListing({
    required this.foreground,
    required this.epoch,
    this.isCurrent,
  });
  bool foreground;
  final int epoch;
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
    bool Function()? isForeground,
  }) {
    final work = _CloudHomeWork(
      action,
      isCurrent,
      isForeground ?? () => foreground,
    );
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
      final foreground = _queue.indexWhere((work) => work.isForeground());
      final work = _queue.removeAt(foreground < 0 ? 0 : foreground);
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
  _CloudHomeWork(this.action, this.isCurrent, this.isForeground);
  final Future<T> Function() action;
  final bool Function() isCurrent;
  final bool Function() isForeground;
  final result = Completer<T>();
}
