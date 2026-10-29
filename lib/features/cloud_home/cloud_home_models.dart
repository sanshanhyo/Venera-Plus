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

/// A direct child of the directory being browsed. Collections remain file
/// browsers: their files keep their own comic IDs and reading progress.
class CloudHomeItem {
  const CloudHomeItem({
    required this.entry,
    required this.kind,
    this.fileCount,
    this.cover,
  });

  final RemoteEntry entry;
  final CloudHomeItemKind kind;
  final int? fileCount;
  final String? cover;

  String get name => entry.name;
  String get path => entry.path;
  bool get isDirectory => entry.isDirectory;
  bool get isReadable =>
      kind == CloudHomeItemKind.comicFile ||
      kind == CloudHomeItemKind.imageComic;

  CloudHomeItem copyWith({
    CloudHomeItemKind? kind,
    int? fileCount,
    String? cover,
  }) => CloudHomeItem(
    entry: entry,
    kind: kind ?? this.kind,
    fileCount: fileCount ?? this.fileCount,
    cover: cover ?? this.cover,
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
    return CloudHomeItemKind.pdfCollection;
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
