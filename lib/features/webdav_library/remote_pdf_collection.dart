import 'dart:convert';

import 'package:venera_plus/features/comic_storage/comic_storage.dart';

/// Chapter identities use the original full path, so inserting another PDF
/// cannot change the chapter referenced by reading progress or bookmarks.
const remotePdfChapterPrefix = 'pdf-file:';

String remotePdfChapterId(String absolutePath) {
  if (!absolutePath.startsWith('/') ||
      absolutePath.endsWith('/') ||
      comicFileExtension(absolutePath) != 'pdf' ||
      absolutePath.split('/').any((part) => part == '.' || part == '..')) {
    throw const FormatException('Invalid PDF chapter path');
  }
  return '$remotePdfChapterPrefix${base64Url.encode(utf8.encode(absolutePath))}';
}

bool isPdfCollectionAuxiliaryFile(String name) {
  final lower = name.toLowerCase();
  return isIgnoredComicStorageEntry(name) ||
      lower == 'thumbs.db' ||
      lower == 'desktop.ini' ||
      lower == 'metadata.json' ||
      lower == 'comicinfo.xml' ||
      lower.endsWith('.nfo') ||
      (lower.endsWith('.metadata.json') &&
          const {'pdf', 'zip', 'cbz', 'epub'}.contains(
            comicFileExtension(
              name.substring(0, name.length - '.metadata.json'.length),
            ),
          )) ||
      (isComicImageFileName(name) &&
          const {
            'cover',
            'folder',
          }.contains(comicFileStem(name).toLowerCase()));
}

/// A collection is a nonempty, direct group of PDFs. Unknown files and visible
/// subdirectories keep the directory browsable instead of hiding its contents.
List<T>? pdfCollectionFiles<T>(
  Iterable<T> entries, {
  required String Function(T entry) nameOf,
  required bool Function(T entry) isDirectory,
}) {
  final files = <T>[];
  for (final entry in entries) {
    final name = nameOf(entry);
    if (isIgnoredComicStorageEntry(name)) continue;
    if (isDirectory(entry)) return null;
    if (isPdfCollectionAuxiliaryFile(name)) continue;
    if (comicFileExtension(name) != 'pdf') return null;
    files.add(entry);
  }
  if (files.isEmpty) return null;
  files.sort((a, b) => compareComicFileNames(nameOf(a), nameOf(b)));
  return List.unmodifiable(files);
}
