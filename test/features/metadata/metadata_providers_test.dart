import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_providers.dart';

const _ehUrl = 'https://e-hentai.org/g/123/abcdef1234/';
const _jmUrl = 'https://18comic.vip/album/456/';

Map<String, dynamic> _ehEntry({String? cover}) => {
  'gid': 123,
  'token': 'abcdef1234',
  'title': 'Field Notes &amp; Rain',
  'title_jpn': '雨の日の記録',
  'uploader': 'Not the author',
  'thumb': cover ?? 'https://ehgt.org/t/cover.jpg',
  'filecount': '24',
  'tags': [
    'artist:Sample Artist',
    'artist:Sample Artist',
    'group:Sample Circle',
    'language:japanese',
    'other:landscape',
  ],
};

String _jmHtml({String id = '456', String title = 'Travel &amp; Sketches'}) =>
    '''
<!doctype html><html><body>
<h1 id="book-name">$title</h1>
<span class="number">識別碼：JM$id</span>
<span itemprop="author" data-type="author">
  <a>Sample Artist</a><a>Sample Artist</a><a>Second Artist</a>
</span>
<span itemprop="genre" data-type="tags"><a>Landscape</a><a>Watercolour</a></span>
<span itemprop="author" data-type="works"><a>Travel Journal</a></span>
<span itemprop="author" data-type="actor"><a>Traveller</a></span>
<span class="pagecount">頁數:36</span>
<h2>敘述：Notes from a <b>quiet</b> journey.</h2>
</body></html>
''';

void main() {
  group('explicit metadata references', () {
    final api = MetadataProviders(dio: Dio(), requestInterval: Duration.zero);

    test('normalizes gallery links and requires ID plus gallery token', () {
      final reference = api.parseReference(
        ' https://e-hentai.org/g/123/ABCDEF1234/?p=1#top ',
      );
      expect(reference.provider, MetadataProviderId.ehentai);
      expect(reference.id, '123');
      expect(reference.token, 'abcdef1234');
      expect(reference.sourceUrl, _ehUrl);
      expect(
        () => api.parseReference('123', provider: MetadataProviderId.ehentai),
        throwsFormatException,
      );
    });

    test('accepts an ExHentai link without promising authenticated access', () {
      expect(
        api.parseReference('https://exhentai.org/g/123/abcdef1234/').sourceUrl,
        'https://exhentai.org/g/123/abcdef1234/',
      );
    });

    test('recognizes JM IDs and configured album links', () {
      for (final input in ['456', 'JM456', 'jm456', _jmUrl]) {
        final reference = api.parseReference(input);
        expect(reference.provider, MetadataProviderId.jmcomic);
        expect(reference.id, '456');
        expect(reference.sourceUrl, _jmUrl);
      }
      expect(
        () => api.parseReference(_ehUrl, provider: MetadataProviderId.jmcomic),
        throwsFormatException,
      );
    });

    test('rejects unrelated URLs, credentials, invalid paths and schemes', () {
      for (final input in [
        'http://e-hentai.org/g/123/abcdef1234/',
        'https://e-hentai.org.evil.example/g/123/abcdef1234/',
        'https://e-hentai.org@evil.example/g/123/abcdef1234/',
        'https://name:password@e-hentai.org/g/123/abcdef1234/',
        'https://e-hentai.org:8443/g/123/abcdef1234/',
        'https://e-hentai.org/g/0/abcdef1234/',
        'https://e-hentai.org/g/123/short/',
        'https://e-hentai.org/g/123/abcdef1234/extra',
        'https://e-hentai.org/s/abcdef1234/123-1',
        'https://18comic.vip.evil.example/album/456/',
        'https://18comic.vip/photo/456/',
        'https://18comic.vip/album/0/',
        'file:///album/456/',
        'javascript:alert(1)',
        'JM0',
        '99999999999999999999999999',
      ]) {
        expect(
          () => api.parseReference(input),
          throwsFormatException,
          reason: input,
        );
      }
    });

    test('custom JM origins never silently replace a different input host', () {
      final custom = MetadataProviders(
        dio: Dio(),
        jmBaseUri: Uri.parse('https://jm.example.test/'),
        jmCoverBaseUri: Uri.parse('https://images.example.test'),
      );
      expect(
        custom.parseReference('JM456').sourceUrl,
        'https://jm.example.test/album/456/',
      );
      expect(() => custom.parseReference(_jmUrl), throwsFormatException);
      for (final origin in [
        'http://jm.example.test',
        'https://localhost',
        'https://127.0.0.1',
        'https://[::1]',
        'https://192.168.1.1',
        'https://jm.example.test/api',
        'https://jm.example.test?key=value',
        'https://user:pass@jm.example.test',
        'https://jm.example.test:8443',
      ]) {
        expect(
          () => MetadataProviders.normalizeJmOrigin(origin),
          throwsFormatException,
          reason: origin,
        );
      }
    });

    test(
      'cover allowlists reject foreign, credentialed and non-HTTPS URLs',
      () {
        expect(
          api.isAllowedCoverUri(
            MetadataProviderId.ehentai,
            Uri.parse('https://ehgt.org/t/cover.jpg'),
          ),
          isTrue,
        );
        expect(
          api.isAllowedCoverUri(
            MetadataProviderId.ehentai,
            Uri.parse('https://s.exhentai.org/t/cover.jpg'),
          ),
          isTrue,
        );
        for (final url in [
          'http://ehgt.org/t/cover.jpg',
          'https://ehgt.org.evil.example/cover.jpg',
          'https://user:pass@ehgt.org/cover.jpg',
          'https://ehgt.org:8443/cover.jpg',
          'https://127.0.0.1/cover.jpg',
          'file:///tmp/cover.jpg',
        ]) {
          expect(
            api.isAllowedCoverUri(MetadataProviderId.ehentai, Uri.parse(url)),
            isFalse,
            reason: url,
          );
        }
        expect(
          api.isAllowedCoverUri(
            MetadataProviderId.jmcomic,
            Uri.parse('https://cdn-msp.jmapiproxy1.cc/media/albums/456.jpg'),
          ),
          isTrue,
        );
        expect(
          api.isAllowedCoverUri(
            MetadataProviderId.jmcomic,
            Uri.parse('https://18comic.vip/media/albums/456.jpg'),
          ),
          isFalse,
        );
      },
    );
  });

  group('E-Hentai metadata', () {
    test(
      'uses fixed API, validates identity and maps namespaced metadata',
      () async {
        final adapter = _QueueAdapter([
          _Reply.json({
            'gmetadata': [_ehEntry()],
          }),
        ]);
        final api = _with(adapter);
        final result = await api.fetch(api.parseReference(_ehUrl));

        expect(result.title, 'Field Notes & Rain');
        expect(result.authors, ['Sample Artist']);
        expect(result.tags['group'], ['Sample Circle']);
        expect(result.tags['language'], ['japanese']);
        expect(result.description, isEmpty);
        expect(result.coverUrl, 'https://ehgt.org/t/cover.jpg');
        expect(result.pageCount, 24);
        final request = adapter.requests.single;
        expect(request.uri.toString(), 'https://api.e-hentai.org/api.php');
        expect(request.method, 'POST');
        expect(request.data, {
          'method': 'gdata',
          'gidlist': [
            [123, 'abcdef1234'],
          ],
          'namespace': 1,
        });
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')),
        );
      },
    );

    test(
      'missing optional fields preserve an empty result rather than inventing data',
      () async {
        final entry = _ehEntry()
          ..remove('tags')
          ..remove('thumb')
          ..remove('filecount')
          ..['gid'] = '123'
          ..['uploader'] = null;
        final api = _with(
          _QueueAdapter([
            _Reply.json({
              'gmetadata': [entry],
            }),
          ]),
        );
        final result = await api.fetch(api.parseReference(_ehUrl));
        expect(result.authors, isEmpty);
        expect(result.tags, isEmpty);
        expect(result.coverUrl, isNull);
        expect(result.pageCount, isNull);
        expect(result.description, isEmpty);
      },
    );

    test('foreign cover URLs are not handed to the downloader', () async {
      final api = _with(
        _QueueAdapter([
          _Reply.json({
            'gmetadata': [_ehEntry(cover: 'http://localhost/private')],
          }),
        ]),
      );
      expect((await api.fetch(api.parseReference(_ehUrl))).coverUrl, isNull);
    });

    test(
      'rejects wrong identities, API errors and malformed API responses',
      () async {
        for (final payload in [
          {
            'gmetadata': [_ehEntry()..['gid'] = 999],
          },
          {
            'gmetadata': [_ehEntry()..['token'] = 'ffffffff00'],
          },
          {
            'gmetadata': [
              {'gid': 123, 'error': 'Key missing'},
            ],
          },
          {'gmetadata': []},
          {
            'gmetadata': [_ehEntry(), _ehEntry()],
          },
          {
            'gmetadata': [_ehEntry()..remove('title')],
          },
          {'error': 'Unavailable'},
          <Object>[],
        ]) {
          final api = _with(_QueueAdapter([_Reply.json(payload)]));
          await expectLater(
            api.fetch(api.parseReference(_ehUrl)),
            throwsA(isA<MetadataProviderException>()),
          );
        }
      },
    );

    test(
      'does not trust hand-built references or request their URLs',
      () async {
        final adapter = _QueueAdapter([]);
        final api = _with(adapter);
        await expectLater(
          api.fetch(
            const MetadataReference(
              provider: MetadataProviderId.ehentai,
              id: '999',
              token: 'abcdef1234',
              sourceUrl: _ehUrl,
            ),
          ),
          throwsFormatException,
        );
        expect(adapter.requests, isEmpty);
      },
    );
  });

  group('JMComic metadata', () {
    test(
      'parses independent detail information and builds only a cover URL',
      () async {
        final adapter = _QueueAdapter([_Reply.html(_jmHtml())]);
        final api = _with(adapter);
        final result = await api.fetch(api.parseReference('JM456'));

        expect(result.title, 'Travel & Sketches');
        expect(result.authors, ['Sample Artist', 'Second Artist']);
        expect(result.tags, {
          'tags': ['Landscape', 'Watercolour'],
          'series': ['Travel Journal'],
          'character': ['Traveller'],
        });
        expect(result.pageCount, 36);
        expect(result.description, 'Notes from a quiet journey.');
        expect(
          result.coverUrl,
          'https://cdn-msp.jmapiproxy1.cc/media/albums/456.jpg',
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.uri.toString(), _jmUrl);
        expect(adapter.requests.single.method, 'GET');
      },
    );

    test(
      'decodes the upstream static Base64 HTML wrapper without running JavaScript',
      () async {
        final payload = base64Encode(utf8.encode(_jmHtml(title: '山と旅')));
        final api = _with(
          _QueueAdapter([
            _Reply.html(
              '<script>const html = base64DecodeUtf8("$payload"); arbitraryCode();</script>',
            ),
          ]),
        );
        expect((await api.fetch(api.parseReference('456'))).title, '山と旅');
      },
    );

    test('rejects challenges, unrelated pages and a different comic', () async {
      for (final body in [
        '<html>Please enable JavaScript and complete the challenge</html>',
        '<h1 id="book-name">An unrelated page</h1>',
        _jmHtml(id: '999'),
        _jmHtml(title: ''),
      ]) {
        final api = _with(_QueueAdapter([_Reply.html(body)]));
        await expectLater(
          api.fetch(api.parseReference('456')),
          throwsA(isA<MetadataProviderException>()),
        );
      }
    });
  });

  group('metadata transport', () {
    test('does not follow redirects or expose raw server errors', () async {
      for (final status in [302, 403, 404, 429, 500]) {
        final adapter = _QueueAdapter([
          _Reply(status, 'private server diagnostic', {
            'location': ['https://other.example/private'],
          }),
        ]);
        final api = _with(adapter);
        await expectLater(
          api.fetch(api.parseReference(_ehUrl)),
          throwsA(
            isA<MetadataProviderException>()
                .having((error) => error.statusCode, 'statusCode', status)
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('private server diagnostic')),
                ),
          ),
        );
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.followRedirects, isFalse);
      }
    });

    test('limits response size before parsing', () async {
      final api = _with(
        _QueueAdapter([
          _Reply(200, '{}', {
            'content-length': ['5242880'],
          }),
        ]),
      );
      await expectLater(
        api.fetch(api.parseReference(_ehUrl)),
        throwsA(
          isA<MetadataProviderException>().having(
            (error) => error.message,
            'message',
            contains('too large'),
          ),
        ),
      );
    });

    test(
      'serializes requests and releases the queue after a failure',
      () async {
        final gate = Completer<void>();
        final adapter = _QueueAdapter([
          _Reply(403, 'denied', {}),
          _Reply.json({
            'gmetadata': [_ehEntry()],
          }),
        ], firstRequestGate: gate.future);
        final api = _with(adapter);
        final first = api.fetch(api.parseReference(_ehUrl));
        final firstAssertion = expectLater(
          first,
          throwsA(isA<MetadataProviderException>()),
        );
        final second = api.fetch(api.parseReference(_ehUrl));
        try {
          await adapter.firstRequestStarted.future.timeout(
            const Duration(seconds: 5),
          );
          await Future<void>.delayed(Duration.zero);
          expect(adapter.requests, hasLength(1));
        } finally {
          // Always release the barrier, including when the assertion fails, so
          // both request futures can settle instead of timing out the suite.
          gate.complete();
        }
        await firstAssertion;
        expect((await second).title, 'Field Notes & Rain');
        expect(adapter.requests, hasLength(2));
      },
    );

    test('factory creates a cookie-free client with redirects disabled', () {
      final dio = createMetadataDio();
      expect(
        dio.options.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(dio.options.followRedirects, isFalse);
      expect(dio.options.maxRedirects, 0);
      dio.close();
    });
  });
}

MetadataProviders _with(_QueueAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return MetadataProviders(dio: dio, requestInterval: Duration.zero);
}

class _Reply {
  _Reply(this.status, this.body, this.headers);

  _Reply.json(Object value)
    : this(200, jsonEncode(value), {
        'content-type': ['application/json'],
      });

  _Reply.html(String value)
    : this(200, value, {
        'content-type': ['text/html; charset=utf-8'],
      });

  final int status;
  final String body;
  final Map<String, List<String>> headers;
}

class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(Iterable<_Reply> replies, {this.firstRequestGate})
    : replies = Queue.of(replies);

  final Queue<_Reply> replies;
  final Future<void>? firstRequestGate;
  final requests = <RequestOptions>[];
  final firstRequestStarted = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1) {
      firstRequestStarted.complete();
      await firstRequestGate;
    }
    final reply = replies.removeFirst();
    return ResponseBody.fromString(
      reply.body,
      reply.status,
      headers: reply.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
