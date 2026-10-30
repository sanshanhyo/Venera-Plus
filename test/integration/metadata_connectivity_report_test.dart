import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/metadata/metadata_providers.dart';

import '../support/metadata_connectivity_probe.dart';

// Synthetic references only. No production gallery targets belong in this file.
const _fixtureGallery = 'https://e-hentai.org/g/123/abcdef1234/';
const _fixtureJm = 'JM456';

void main() {
  test(
    'live entry requires both GitHub Actions and the explicit OS switch',
    () {
      expect(isMetadataConnectivityEnabled({}), isFalse);
      expect(
        isMetadataConnectivityEnabled({'GITHUB_ACTIONS': 'true'}),
        isFalse,
      );
      expect(
        isMetadataConnectivityEnabled({'CI_METADATA_CONNECTIVITY': 'true'}),
        isFalse,
      );
      expect(
        isMetadataConnectivityEnabled({
          'GITHUB_ACTIONS': 'true',
          'CI_METADATA_CONNECTIVITY': 'false',
        }),
        isFalse,
      );
      expect(
        isMetadataConnectivityEnabled({
          'GITHUB_ACTIONS': 'true',
          'CI_METADATA_CONNECTIVITY': 'true',
        }),
        isTrue,
      );
    },
  );

  test(
    'no targets means only empty gdata and HEAD probes, never metadata success',
    () async {
      final adapter = _ScriptedAdapter([
        _json(400, {'error': 'fixture private error'}),
        _response(404),
        _response(405),
      ]);
      final report = await _run(adapter);
      final json = report.toJson();

      expect(report.exitCode, 0);
      expect(
        (json['summary'] as Map)['requested_metadata'],
        'skipped_no_user_target',
      );
      expect(adapter.requests.map((request) => request.method), [
        'POST',
        'HEAD',
        'HEAD',
      ]);
      expect(adapter.requests.first.data, const {
        'method': 'gdata',
        'gidlist': [],
        'namespace': 1,
      });
      expect(
        adapter.requests
            .skip(1)
            .every(
              (request) =>
                  request.uri.path ==
                  '/__venera_metadata_connectivity_not_found__',
            ),
        isTrue,
      );
      expect(
        report.checks
            .where((check) => check.operation == 'metadata_read')
            .every((check) => check.outcome == 'skipped'),
        isTrue,
      );
      expect(report.checks.first.reason, 'structured_api_error_observed');
      expect(report.checks[2].reason, 'head_not_supported');
      expect(jsonEncode(json), isNot(contains('fixture private error')));
      expect(json['cover_images_downloaded'], isFalse);
      for (final request in adapter.requests) {
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
      }
    },
  );

  test('403 and 429 are blocked observations and fail the run', () async {
    final report = await _run(
      _ScriptedAdapter([
        _json(200, {'gmetadata': []}),
        _response(403),
        _response(429),
      ]),
    );
    expect(report.exitCode, 1);
    expect(report.checks[1].outcome, 'blocked');
    expect(report.checks[1].reason, 'access_restricted');
    expect(report.checks[2].reason, 'rate_limited');
    expect((report.toJson()['summary'] as Map)['probe_only'], 'blocked');
  });

  test('HTTP 200 HTML does not pass the EH JSON protocol probe', () async {
    final report = await _run(
      _ScriptedAdapter([
        _response(200, body: '<html>fixture challenge</html>'),
        _response(404),
        _response(404),
      ]),
    );
    expect(report.exitCode, 1);
    expect(report.checks.first.status, 200);
    expect(report.checks.first.outcome, 'blocked');
    expect(report.checks.first.reason, 'protocol_response_not_json_object');
    expect(
      (report.toJson()['summary'] as Map)['requested_metadata'],
      'skipped_no_user_target',
    );
  });

  test(
    'real parser paths produce only field presence and counts in the report',
    () async {
      final adapter = _ScriptedAdapter([
        _json(200, {'gmetadata': []}),
        _response(404),
        _response(404),
        _json(200, {
          'gmetadata': [
            {
              'gid': 123,
              'token': 'abcdef1234',
              'title': 'Fixture private title',
              'uploader': 'Fixture private uploader',
              'tags': [
                'artist:Fixture private artist',
                'other:Fixture private tag',
              ],
              'thumb': 'https://ehgt.org/private-cover.jpg',
              'filecount': '12',
            },
          ],
        }),
        _response(
          200,
          body: '''
<span class="number">識別碼：JM456</span>
<h1 id="book-name">Fixture private JM title</h1>
<span itemprop="author" data-type="author"><a>Fixture private author</a></span>
<span itemprop="genre" data-type="tags"><a>Fixture private JM tag</a></span>
''',
        ),
      ]);
      final report = await _run(
        adapter,
        config: const MetadataConnectivityConfig(
          ehGalleryUrl: _fixtureGallery,
          jmReference: _fixtureJm,
        ),
      );
      final reads = report.checks
          .where((check) => check.operation == 'metadata_read')
          .toList();
      expect(report.exitCode, 0);
      expect(reads.map((check) => check.outcome), ['passed', 'passed']);
      expect(reads.every((check) => check.status == 200), isTrue);
      expect(
        reads.every((check) => check.presence['identity_matches'] == true),
        isTrue,
      );
      expect(reads.first.counts, {'authors': 1, 'tags': 2});
      expect(reads.last.counts, {'authors': 1, 'tags': 1});
      expect(adapter.requests, hasLength(5));
      expect(
        adapter.requests.where((request) => request.uri.host == 'ehgt.org'),
        isEmpty,
      );
      final serialized = jsonEncode(report.toJson());
      for (final secret in [
        _fixtureGallery,
        'abcdef1234',
        'Fixture private',
        'private-cover.jpg',
        '/album/456',
      ]) {
        expect(
          serialized,
          isNot(contains(secret)),
          reason: 'Reports must not retain response fields or full references.',
        );
      }
    },
  );

  test(
    'optional missing author and cover do not fail valid metadata',
    () async {
      final report = await _run(
        _ScriptedAdapter([
          _json(200, {'gmetadata': []}),
          _response(404),
          _response(404),
          _json(200, {
            'gmetadata': [
              {'gid': '123', 'token': 'abcdef1234', 'title': 'Fixture title'},
            ],
          }),
        ]),
        config: const MetadataConnectivityConfig(ehGalleryUrl: _fixtureGallery),
      );
      final read = report.checks.firstWhere(
        (check) => check.operation == 'metadata_read',
      );
      expect(report.exitCode, 0);
      expect(read.outcome, 'passed');
      expect(read.presence['authors'], isFalse);
      expect(read.presence['cover_url'], isFalse);
    },
  );

  test(
    'provided target denied by HTTP 403 is failed without leaking response data',
    () async {
      final report = await _run(
        _ScriptedAdapter([
          _json(200, {'gmetadata': []}),
          _response(404),
          _response(404),
          _response(
            403,
            body: 'Fixture private diagnostic',
            headers: {
              'set-cookie': ['Fixture private cookie'],
              'location': ['https://example.test/Fixture-private-location'],
            },
          ),
        ]),
        config: const MetadataConnectivityConfig(ehGalleryUrl: _fixtureGallery),
      );
      final read = report.checks.firstWhere(
        (check) => check.operation == 'metadata_read',
      );
      expect(report.exitCode, 1);
      expect(read.outcome, 'blocked');
      expect(read.status, 403);
      expect(jsonEncode(report.toJson()), isNot(contains('Fixture private')));
      expect(
        jsonEncode(report.toJson()),
        isNot(contains('Fixture-private-location')),
      );
    },
  );

  test(
    'HEAD never subscribes to a response body or follows a redirect',
    () async {
      var bodyRead = false;
      ResponseBody unreadBody(int status) => ResponseBody(
        Stream<Uint8List>.multi((controller) {
          bodyRead = true;
          controller.addError(StateError('The HEAD body must never be read.'));
          controller.close();
        }),
        status,
        headers: {
          'location': ['https://example.test/private'],
        },
      );
      final adapter = _ScriptedAdapter([
        _json(200, {'gmetadata': []}),
        unreadBody(302),
        unreadBody(405),
      ]);
      final report = await _run(adapter);
      expect(report.exitCode, 0);
      expect(bodyRead, isFalse);
      expect(adapter.requests, hasLength(3));
      expect(report.checks[1].reason, 'redirect_observed');
    },
  );

  test(
    'transport reasons reflect observed failures without serializing exception messages',
    () {
      final options = RequestOptions(path: _fixtureGallery);
      final fixtures = <(Object, DioExceptionType, String)>[
        (
          const SocketException('Failed host lookup: private.example'),
          DioExceptionType.connectionError,
          'dns_lookup_failed',
        ),
        (
          const HandshakeException('Fixture private TLS detail'),
          DioExceptionType.connectionError,
          'tls_handshake_failed',
        ),
        (
          const SocketException('Connection refused'),
          DioExceptionType.connectionError,
          'socket_connection_failed',
        ),
        (
          'Fixture private timeout',
          DioExceptionType.receiveTimeout,
          'request_timed_out',
        ),
        (
          'Fixture private certificate',
          DioExceptionType.badCertificate,
          'tls_certificate_rejected',
        ),
      ];
      for (final (cause, type, expected) in fixtures) {
        expect(
          classifyMetadataTransportFailure(
            DioException(requestOptions: options, type: type, error: cause),
          ),
          expected,
        );
      }
    },
  );

  test('invalid JM origin is reported without requesting it', () async {
    final adapter = _ScriptedAdapter([
      _json(200, {'gmetadata': []}),
    ]);
    final report = await _run(
      adapter,
      config: const MetadataConnectivityConfig(
        jmReference: _fixtureJm,
        jmBaseUrl: 'https://user:private-password@localhost/private-path',
      ),
    );
    expect(report.exitCode, 1);
    expect(adapter.requests, hasLength(1));
    expect(report.checks.first.reason, 'invalid_configuration');
    expect(jsonEncode(report.toJson()), isNot(contains('private-password')));
    expect(jsonEncode(report.toJson()), isNot(contains('private-path')));
  });
}

Future<MetadataConnectivityReport> _run(
  _ScriptedAdapter adapter, {
  MetadataConnectivityConfig config = const MetadataConnectivityConfig(),
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return runMetadataConnectivity(
    config: config,
    dio: dio,
    gatewayFactory: (dio, base, cover) => MetadataProviders(
      dio: dio,
      jmBaseUri: base,
      jmCoverBaseUri: cover,
      requestInterval: Duration.zero,
    ),
  );
}

ResponseBody _json(int status, Object body) => _response(
  status,
  body: jsonEncode(body),
  headers: {
    'content-type': ['application/json'],
  },
);

ResponseBody _response(
  int status, {
  String body = '',
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(body, status, headers: headers);

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(Iterable<ResponseBody> responses)
    : responses = Queue.of(responses);

  final Queue<ResponseBody> responses;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responses.removeFirst();
  }

  @override
  void close({bool force = false}) {}
}
