import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

enum CloudHomeItemKind {
  directory,
  pdfCollection,
  imageComic,
  comicFile,
  unsupported,
}

enum CloudHomeDirectoryOverride { automatic, folder, comic }

class CloudHomeUnsupportedComicFolder implements Exception {
  const CloudHomeUnsupportedComicFolder();

  static const message =
      'This folder contains mixed or unsupported files. Keep it as a folder.';

  @override
  String toString() => message;
}

/// The home mounts an already imported comic library. An absent directory
/// means the library's home: its only root, or a virtual list of its roots.
class CloudHomeLibraryMount {
  const CloudHomeLibraryMount({required this.libraryId, this.directory});

  final String libraryId;
  final String? directory;

  CloudHomeLibraryMount normalized() => CloudHomeLibraryMount(
    libraryId: libraryId,
    directory: directory == null ? null : normalizeRemoteDirectory(directory!),
  );

  Map<String, dynamic> toJson() => {
    'libraryId': libraryId,
    if (directory != null) 'directory': normalizeRemoteDirectory(directory!),
  };

  factory CloudHomeLibraryMount.fromJson(Map<Object?, Object?> json) {
    final directory = json['directory'];
    if (directory != null && directory is! String) {
      throw const FormatException('Invalid cloud home directory');
    }
    return CloudHomeLibraryMount(
      libraryId: json['libraryId'] as String? ?? '',
      directory: directory is String && directory.trim().isNotEmpty
          ? normalizeRemoteDirectory(directory)
          : null,
    );
  }
}

/// A direct child of the directory being browsed. PDF collections open as one
/// comic whose chapters are the directory's direct PDF files.
class CloudHomeItem {
  const CloudHomeItem({
    required this.entry,
    required this.kind,
    this.fileCount,
    this.cover,
    this.bindingToken,
  });

  final RemoteEntry entry;
  final CloudHomeItemKind kind;
  final int? fileCount;
  final String? cover;

  /// Opaque controller binding identity. It is never persisted or rendered.
  final Object? bindingToken;

  String get name => entry.name;
  String get path => entry.path;
  bool get isDirectory => entry.isDirectory;
  bool get isReadable =>
      kind == CloudHomeItemKind.comicFile ||
      kind == CloudHomeItemKind.imageComic ||
      kind == CloudHomeItemKind.pdfCollection;

  CloudHomeItem copyWith({
    CloudHomeItemKind? kind,
    int? fileCount,
    String? cover,
    Object? bindingToken,
  }) => CloudHomeItem(
    entry: entry,
    kind: kind ?? this.kind,
    fileCount: fileCount ?? this.fileCount,
    cover: cover ?? this.cover,
    bindingToken: bindingToken ?? this.bindingToken,
  );
}

bool isCloudHomeComicFile(String name) =>
    const {'pdf', 'zip', 'cbz', 'epub'}.contains(comicFileExtension(name));

bool isCloudHomeAuxiliaryFile(String name) {
  final lower = name.toLowerCase();
  return isIgnoredComicStorageEntry(name) ||
      lower == 'thumbs.db' ||
      lower == 'desktop.ini' ||
      lower == 'metadata.json' ||
      (lower.endsWith('.metadata.json') &&
          isCloudHomeComicFile(
            name.substring(0, name.length - '.metadata.json'.length),
          )) ||
      lower == 'comicinfo.xml' ||
      lower.endsWith('.nfo') ||
      (isComicImageFileName(name) &&
          const {
            'cover',
            'folder',
          }.contains(comicFileStem(name).toLowerCase()));
}

bool isVisibleCloudHomeEntry(RemoteEntry entry) => entry.isDirectory
    ? !isIgnoredComicStorageEntry(entry.name)
    : !isCloudHomeAuxiliaryFile(entry.name);

/// Format recognition deliberately does not infer chapter names or numbers.
CloudHomeItemKind classifyCloudHomeDirectory(
  Iterable<RemoteEntry> entries, {
  CloudHomeDirectoryOverride override = CloudHomeDirectoryOverride.automatic,
}) {
  if (override == CloudHomeDirectoryOverride.folder) {
    return CloudHomeItemKind.directory;
  }
  final visible = entries.where(isVisibleCloudHomeEntry).toList();
  final files = visible.where((entry) => !entry.isDirectory).toList();
  final directories = visible.where((entry) => entry.isDirectory);
  final images = files.where((entry) => isComicImageFileName(entry.name));
  final comics = files.where((entry) => isCloudHomeComicFile(entry.name));
  if (directories.isEmpty &&
      images.isNotEmpty &&
      files.every((entry) => isComicImageFileName(entry.name))) {
    return CloudHomeItemKind.imageComic;
  }
  if (override == CloudHomeDirectoryOverride.comic) {
    if (directories.isNotEmpty &&
        comics.isEmpty &&
        files.every((entry) => isComicImageFileName(entry.name))) {
      return CloudHomeItemKind.imageComic;
    }
    if (directories.isEmpty &&
        files.isNotEmpty &&
        files.every((entry) => comicFileExtension(entry.name) == 'pdf')) {
      return CloudHomeItemKind.pdfCollection;
    }
    return CloudHomeItemKind.directory;
  }
  if (directories.isEmpty &&
      files.isNotEmpty &&
      files.every((entry) => comicFileExtension(entry.name) == 'pdf')) {
    return CloudHomeItemKind.pdfCollection;
  }
  return CloudHomeItemKind.directory;
}

List<CloudHomeItem> cloudHomeItems(Iterable<RemoteEntry> entries) {
  final result = entries.where(isVisibleCloudHomeEntry).map((entry) {
    return CloudHomeItem(
      entry: entry,
      kind: entry.isDirectory
          ? CloudHomeItemKind.directory
          : isCloudHomeComicFile(entry.name)
          ? CloudHomeItemKind.comicFile
          : CloudHomeItemKind.unsupported,
    );
  }).toList();
  result.sort((left, right) {
    if (left.isDirectory != right.isDirectory) return left.isDirectory ? -1 : 1;
    return compareComicFileNames(left.name, right.name);
  });
  return List.unmodifiable(result);
}
