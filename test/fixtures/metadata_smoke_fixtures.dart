import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as image;

/// Deliberately synthetic examples. No request ever leaves this adapter.
const smokeOriginalTitle = '导入的旅行手记（示例）';
const smokeEhTitle = '雨天手记（示例）';
const smokeJmTitle = '旅途速写（示例）';
const smokeComicId = 'metadata-ui-smoke-book';
const smokeEhReference = 'https://e-hentai.org/g/42424242/abcdef0123/';
const smokeJmReference = 'JM777888';
const smokeJmBaseUrl = 'https://jm.example.test';
const smokeJmCoverBaseUrl = 'https://covers.example.test';

const metadataSmokeRequiredScreenshots = <String>[
  '01_local_menu',
  '02_eh_preview_cache_off',
  '03_eh_preview_cache_on',
  '04_eh_saved_local_list',
  '05_jm_settings',
  '06_jm_preview_cache_off',
  '07_jm_saved_local_list',
  '08_removed_restored',
];

Map<String, Object?> get smokeEhMetadata => {
  'gmetadata': [
    {
      'gid': 42424242,
      'token': 'abcdef0123',
      'title': smokeEhTitle,
      'title_jpn': 'Field Notes — Synthetic Fixture',
      'uploader': 'Fixture uploader, not the artist',
      'thumb': 'https://ehgt.org/venera-smoke/field-notes.png',
      'filecount': '24',
      'tags': [
        'artist:示例作者',
        'group:旅行画室',
        'language:chinese',
        'other:风景',
        'other:水彩',
      ],
    },
  ],
};

const smokeJmHtml =
    '''
<!doctype html><html lang="zh"><body>
<h1 id="book-name">$smokeJmTitle</h1>
<span class="number">識別碼：JM777888</span>
<span itemprop="author" data-type="author"><a>旅行画室</a></span>
<span itemprop="genre" data-type="tags"><a>风景</a><a>彩色</a></span>
<span itemprop="author" data-type="works"><a>旅行笔记</a></span>
<span class="pagecount">頁數：32</span>
<h2>敘述：一次安静旅途中的速写与记录。这是界面验证的合成示例。</h2>
</body></html>
''';

Uint8List createSmokeCover({bool alternate = false}) {
  final canvas = image.Image(width: 320, height: 440);
  image.fill(
    canvas,
    color: alternate
        ? image.ColorRgb8(120, 73, 45)
        : image.ColorRgb8(27, 76, 86),
  );
  final cream = image.ColorRgb8(245, 231, 196);
  image.drawRect(
    canvas,
    x1: 18,
    y1: 18,
    x2: 301,
    y2: 421,
    color: cream,
    thickness: 2,
  );
  image.drawString(
    canvas,
    alternate ? 'TRAVEL' : 'FIELD',
    font: image.arial48,
    x: 35,
    y: 56,
    color: cream,
  );
  image.drawString(
    canvas,
    alternate ? 'SKETCH' : 'NOTES',
    font: image.arial48,
    x: 35,
    y: 113,
    color: cream,
  );
  image.drawLine(
    canvas,
    x1: 36,
    y1: 294,
    x2: 123,
    y2: 226,
    color: cream,
    thickness: 3,
  );
  image.drawLine(
    canvas,
    x1: 123,
    y1: 226,
    x2: 283,
    y2: 314,
    color: cream,
    thickness: 3,
  );
  image.drawString(
    canvas,
    'SYNTHETIC SAMPLE',
    font: image.arial14,
    x: 36,
    y: 374,
    color: cream,
  );
  return Uint8List.fromList(image.encodePng(canvas));
}

class MetadataSmokeAdapter implements HttpClientAdapter {
  MetadataSmokeAdapter()
    : ehCover = createSmokeCover(),
      jmCover = createSmokeCover(alternate: true);

  final Uint8List ehCover;
  final Uint8List jmCover;
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add('${options.method} $uri');
    if (options.method == 'POST' &&
        uri.toString() == 'https://api.e-hentai.org/api.php') {
      final body = options.data;
      if (body is! Map ||
          body['method'] != 'gdata' ||
          body['namespace'] != 1 ||
          jsonEncode(body['gidlist']) != '[[42424242,"abcdef0123"]]') {
        throw StateError('Unexpected synthetic EH metadata request.');
      }
      return ResponseBody.fromString(
        jsonEncode(smokeEhMetadata),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    if (options.method == 'GET' &&
        uri.host == 'jm.example.test' &&
        uri.path == '/album/777888/') {
      return ResponseBody.fromString(
        smokeJmHtml,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    if (options.method == 'GET' &&
        uri.host == 'ehgt.org' &&
        uri.path == '/venera-smoke/field-notes.png') {
      return _cover(ehCover);
    }
    if (options.method == 'GET' &&
        uri.host == 'covers.example.test' &&
        uri.path == '/media/albums/777888.jpg') {
      return _cover(jmCover);
    }
    throw StateError('Unexpected network request in synthetic UI smoke: $uri');
  }

  ResponseBody _cover(Uint8List bytes) => ResponseBody.fromBytes(
    bytes,
    200,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
      Headers.contentLengthHeader: [bytes.length.toString()],
    },
  );

  @override
  void close({bool force = false}) {}
}
