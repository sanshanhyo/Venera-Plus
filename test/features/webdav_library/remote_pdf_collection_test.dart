import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/webdav_library/remote_pdf_collection.dart';
import 'package:venera_plus/features/webdav_library/remote_archive_comic.dart';
import 'package:venera_plus/features/webdav_library/remote_comic_work.dart';

typedef _Entry = ({String name, bool directory});

void main() {
  List<_Entry>? recognize(List<_Entry> entries) => pdfCollectionFiles(
    entries,
    nameOf: (entry) => entry.name,
    isDirectory: (entry) => entry.directory,
  );

  test('only direct PDF files become naturally ordered file chapters', () {
    final result = recognize(const [
      (name: 'chapter10.PDF', directory: false),
      (name: 'cover.jpg', directory: false),
      (name: 'folder.png', directory: false),
      (name: 'chapter2.pdf', directory: false),
      (name: '.DS_Store', directory: false),
      (name: '__MACOSX', directory: true),
      (name: 'metadata.json', directory: false),
      (name: 'chapter2.pdf.metadata.json', directory: false),
      (name: 'ComicInfo.xml', directory: false),
    ]);
    expect(result!.map((entry) => entry.name), [
      'chapter2.pdf',
      'chapter10.PDF',
    ]);
  });

  test('empty, mixed, and nested directories remain folders', () {
    expect(recognize(const []), isNull);
    expect(recognize(const [(name: 'cover.jpg', directory: false)]), isNull);
    for (final extra in const <_Entry>[
      (name: 'another.zip', directory: false),
      (name: 'page.jpg', directory: false),
      (name: 'notes.txt', directory: false),
      (name: 'chapter2', directory: true),
    ]) {
      expect(
        recognize([(name: 'chapter1.pdf', directory: false), extra]),
        isNull,
        reason: extra.name,
      );
    }
  });

  test(
    'work serialization keeps logical chapter ids and archive transport paths',
    () {
      const path = '/书库/阿衰/第 9 话.pdf';
      final chapter = remotePdfChapterId(path);
      final work = RemoteComicWork(
        directory: '/书库/阿衰/',
        title: '阿衰',
        logicalId: '阿衰',
        volumes: [
          RemoteComicVolume(
            archive: RemoteArchiveComic(path: path, size: 100),
            title: '第 9 话',
            logicalId: chapter,
          ),
        ],
      );
      final restored = RemoteComicWork.fromJson(
        jsonDecode(jsonEncode(work.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, '阿衰');
      expect(restored.isPdfDirectory, isTrue);
      expect(restored.chapters, {chapter: '第 9 话'});
      expect(restored.volume(chapter)!.archive.path, path);
      expect(restored.volume(path)!.id, chapter);
      expect(restored.volume(remotePdfChapterId('/书库/其他/第 9 话.pdf')), isNull);
      expect(restored.volume('pdf-file:not-base64!'), isNull);
      final image = RemoteComicWork.parseImageKey(
        restored.imageKey(restored.volumes.single),
      );
      expect(image.work, '阿衰');
      expect(image.volume, chapter);
    },
  );

  test('chapter identity keeps the original filename and complete path', () {
    const path = '/书库/阿衰/第 9 话.pdf';
    final chapter = remotePdfChapterId(path);
    expect(remotePdfChapterId(path), chapter);
    expect(remotePdfChapterId('/书库/另一部/第 9 话.pdf'), isNot(chapter));
    expect(remotePdfChapterId('/书库/阿衰/第 10 话.pdf'), isNot(chapter));
    for (final invalid in [
      'book.pdf',
      '/book.pdf/',
      '/library/../book.pdf',
      '/library/./book.pdf',
      '/library/book.zip',
    ]) {
      expect(
        () => remotePdfChapterId(invalid),
        throwsFormatException,
        reason: invalid,
      );
    }
  });
}
