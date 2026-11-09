import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/network/proxy.dart';

/// A separate client deliberately has no account cookies or application network
/// interceptors. Redirects are inspected by callers before making another request.
Dio createMetadataDio() {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
      maxRedirects: 0,
    ),
  );
  dio.httpClientAdapter = _MetadataHttpAdapter();
  return dio;
}

class _MetadataHttpAdapter implements HttpClientAdapter {
  final _adapters = <String, IOHttpClientAdapter>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Metadata client is closed');
    final proxy = await getProxy();
    final directive = _proxyDirective(proxy);
    final adapter = _adapters.putIfAbsent(
      directive,
      () => IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = (_) => directive,
      ),
    );
    return adapter.fetch(
      options.copyWith(followRedirects: false, maxRedirects: 0),
      requestStream,
      cancelFuture,
    );
  }

  static String _proxyDirective(String? proxy) {
    if (proxy == null || proxy.trim().isEmpty) return 'DIRECT';
    final value = proxy.trim();
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port <= 0 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const MetadataProviderException(
        'Metadata requests require an HTTP proxy with a host and port.',
      );
    }
    return 'PROXY ${uri.host}:${uri.port}';
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final adapter in _adapters.values) {
      adapter.close(force: force);
    }
    _adapters.clear();
  }
}

class MetadataProviderException implements Exception {
  const MetadataProviderException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Explicit-reference metadata only. No filename search or gallery-page images
/// are requested. JM's HTML fields follow JMComic-Crawler-Python v2.7.10; see
/// third_party_notices/jmcomic_metadata.txt for its MIT notice.
class MetadataProviders implements MetadataGateway {
  MetadataProviders({
    Dio? dio,
    Uri? jmBaseUri,
    Uri? jmCoverBaseUri,
    this.requestInterval = const Duration(seconds: 2),
  }) : _dio = dio ?? createMetadataDio(),
       jmBaseUri = _origin(jmBaseUri ?? defaultJmBaseUri),
       jmCoverBaseUri = _origin(jmCoverBaseUri ?? defaultJmCoverBaseUri);

  static final defaultJmBaseUri = Uri.parse('https://18comic.vip');
  static final defaultJmCoverBaseUri = Uri.parse(
    'https://cdn-msp.jmapiproxy1.cc',
  );
  static final _ehEndpoint = Uri.parse('https://api.e-hentai.org/api.php');
  static const _maximumResponseBytes = 4 * 1024 * 1024;
  static final _ehPath = RegExp(r'^/g/([1-9][0-9]*)/([a-fA-F0-9]{10})/?$');
  static final _jmPath = RegExp(r'^/album/([1-9][0-9]*)/?$');
  static final _jmId = RegExp(r'^(?:[jJ][mM])?([1-9][0-9]*)$');
  static final _wrappedHtml = RegExp(
    r'''const\s+html\s*=\s*base64DecodeUtf8\("([A-Za-z0-9+/=\r\n]+)"\)''',
  );

  final Dio _dio;
  final Uri jmBaseUri;
  final Uri jmCoverBaseUri;
  final Duration requestInterval;
  Future<void> _tail = Future<void>.value();
  DateTime? _lastRequestAt;

  static Uri normalizeJmOrigin(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null) {
      throw const FormatException('Use a public HTTPS origin without a path.');
    }
    return _origin(uri);
  }

  static Uri _origin(Uri uri) {
    if (!_isHttpsUri(uri) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        _isPrivateHost(uri.host)) {
      throw const FormatException('Use a public HTTPS origin without a path.');
    }
    return Uri(scheme: 'https', host: uri.host);
  }

  static bool _isHttpsUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);

  static bool _isPrivateHost(String host) {
    final value = host.toLowerCase();
    return value == 'localhost' ||
        value.endsWith('.localhost') ||
        value.endsWith('.local') ||
        !value.contains('.') ||
        InternetAddress.tryParse(value) != null;
  }

  static String _id(String id) {
    final number = int.tryParse(id);
    if (number == null || number <= 0 || id.length > 18) {
      throw const FormatException('Invalid comic ID.');
    }
    return number.toString();
  }

  @override
  MetadataReference parseReference(
    String input, {
    MetadataProviderId? provider,
  }) {
    final value = input.trim();
    if (provider != MetadataProviderId.ehentai) {
      final match = _jmId.firstMatch(value);
      if (match != null) {
        final id = _id(match[1]!);
        return MetadataReference(
          provider: MetadataProviderId.jmcomic,
          id: id,
          sourceUrl: jmBaseUri.resolve('/album/$id/').toString(),
        );
      }
    }

    final uri = Uri.tryParse(value);
    if (uri == null || !_isHttpsUri(uri) || value.contains('\\')) {
      throw const FormatException('Enter an HTTPS gallery link or a JM ID.');
    }
    final host = uri.host.toLowerCase();
    if (provider != MetadataProviderId.jmcomic &&
        const {'e-hentai.org', 'exhentai.org'}.contains(host)) {
      final match = _ehPath.firstMatch(uri.path);
      if (match == null) {
        throw const FormatException('Use a complete E-Hentai gallery link.');
      }
      final id = _id(match[1]!);
      final token = match[2]!.toLowerCase();
      return MetadataReference(
        provider: MetadataProviderId.ehentai,
        id: id,
        token: token,
        sourceUrl: 'https://$host/g/$id/$token/',
      );
    }
    if (provider != MetadataProviderId.ehentai && host == jmBaseUri.host) {
      final match = _jmPath.firstMatch(uri.path);
      if (match != null) {
        final id = _id(match[1]!);
        return MetadataReference(
          provider: MetadataProviderId.jmcomic,
          id: id,
          sourceUrl: jmBaseUri.resolve('/album/$id/').toString(),
        );
      }
    }
    throw const FormatException(
      'Use an E-Hentai gallery link, a JM ID, or the configured JM album URL.',
    );
  }

  @override
  bool isAllowedCoverUri(MetadataProviderId provider, Uri uri) {
    if (!_isHttpsUri(uri) || uri.hasFragment) return false;
    final host = uri.host.toLowerCase();
    return switch (provider) {
      MetadataProviderId.ehentai =>
        host == 'ehgt.org' ||
            host.endsWith('.ehgt.org') ||
            host == 's.exhentai.org',
      MetadataProviderId.jmcomic => host == jmCoverBaseUri.host,
    };
  }

  @override
  Future<MetadataResult> fetch(MetadataReference reference) async {
    final verified = parseReference(
      reference.sourceUrl,
      provider: reference.provider,
    );
    if (verified.id != reference.id || verified.token != reference.token) {
      throw const FormatException(
        'The comic reference does not match its URL.',
      );
    }
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    await previous;
    try {
      final last = _lastRequestAt;
      if (last != null) {
        final remaining = requestInterval - DateTime.now().difference(last);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      _lastRequestAt = DateTime.now();
      return switch (verified.provider) {
        MetadataProviderId.ehentai => await _fetchEh(verified),
        MetadataProviderId.jmcomic => await _fetchJm(verified),
      };
    } finally {
      completer.complete();
    }
  }

  Future<String> _requestText(
    Uri uri, {
    required String method,
    Object? data,
    String? referer,
  }) async {
    final token = CancelToken();
    try {
      final response = await _dio.request<ResponseBody>(
        uri.toString(),
        data: data,
        cancelToken: token,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (_) => true,
          headers: {
            'Accept': method == 'POST'
                ? 'application/json'
                : 'text/html,application/xhtml+xml',
            'User-Agent': 'Venera-Plus metadata',
            if (method == 'POST') 'Content-Type': 'application/json',
            'Referer': ?referer,
          },
        ),
      );
      final status = response.statusCode;
      if (status != 200) {
        token.cancel();
        throw MetadataProviderException(switch (status) {
          301 ||
          302 ||
          303 ||
          307 ||
          308 => 'The metadata site moved. Check the source address.',
          401 || 403 => 'The metadata source denied access.',
          404 => 'The comic was not found at this source.',
          429 => 'The metadata source is busy. Please try again later.',
          _ => 'The metadata source returned an error.',
        }, statusCode: status);
      }
      final length = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (length != null && length > _maximumResponseBytes) {
        token.cancel();
        throw const MetadataProviderException(
          'The metadata response is too large.',
        );
      }
      final body = response.data;
      if (body == null) {
        throw const MetadataProviderException(
          'The metadata response is empty.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > _maximumResponseBytes) {
          token.cancel();
          throw const MetadataProviderException(
            'The metadata response is too large.',
          );
        }
        bytes.add(chunk);
      }
      try {
        return utf8.decode(bytes.takeBytes());
      } on FormatException {
        throw const MetadataProviderException(
          'The metadata response is not valid text.',
        );
      }
    } on DioException catch (error) {
      final cause = error.error;
      if (cause is MetadataProviderException) throw cause;
      throw MetadataProviderException(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'The metadata request timed out.',
        _ => 'Unable to connect to the metadata source.',
      }, statusCode: error.response?.statusCode);
    }
  }

  Future<MetadataResult> _fetchEh(MetadataReference reference) async {
    final text = await _requestText(
      _ehEndpoint,
      method: 'POST',
      data: {
        'method': 'gdata',
        'gidlist': [
          [int.parse(reference.id), reference.token],
        ],
        'namespace': 1,
      },
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const MetadataProviderException(
        'Invalid E-Hentai metadata response.',
      );
    }
    if (decoded is! Map || decoded['gmetadata'] is! List) {
      throw const MetadataProviderException(
        'Invalid E-Hentai metadata response.',
      );
    }
    final entries = decoded['gmetadata'] as List;
    if (entries.length != 1 || entries.single is! Map) {
      throw const MetadataProviderException(
        'Invalid E-Hentai metadata response.',
      );
    }
    final entry = entries.single as Map;
    if (entry['error'] != null) {
      throw const MetadataProviderException(
        'E-Hentai could not return this gallery. Check the link and access rights.',
      );
    }
    if (_text(entry['gid']) != reference.id ||
        _text(entry['token']).toLowerCase() != reference.token) {
      throw const MetadataProviderException(
        'E-Hentai returned a different gallery.',
      );
    }
    final title = _decodeEntities(_text(entry['title']));
    if (title.isEmpty) {
      throw const MetadataProviderException(
        'E-Hentai returned no gallery title.',
      );
    }
    final tags = <String, List<String>>{};
    final rawTags = entry['tags'];
    if (rawTags is List) {
      for (final tag in rawTags.whereType<String>()) {
        final separator = tag.indexOf(':');
        final namespace = separator < 0 ? 'other' : tag.substring(0, separator);
        final value = separator < 0 ? tag : tag.substring(separator + 1);
        _addTag(tags, namespace, _decodeEntities(value));
      }
    }
    return MetadataResult(
      reference: reference,
      title: title,
      authors: tags['artist'] ?? const [],
      tags: tags,
      coverUrl: _validatedCover(reference.provider, _text(entry['thumb'])),
      pageCount: _positiveInt(entry['filecount']),
    );
  }

  Future<MetadataResult> _fetchJm(MetadataReference reference) async {
    var text = await _requestText(
      Uri.parse(reference.sourceUrl),
      method: 'GET',
      referer: jmBaseUri.toString(),
    );
    final wrapped = _wrappedHtml.firstMatch(text);
    if (wrapped != null) {
      try {
        text = utf8.decode(
          base64.decode(wrapped[1]!.replaceAll(RegExp(r'\s'), '')),
        );
      } on FormatException {
        throw const MetadataProviderException(
          'Invalid JMComic metadata response.',
        );
      }
    }
    final document = html.parse(text);
    final id = document
        .querySelectorAll('span.number')
        .map((element) {
          return RegExp(
            r'(?:：|:)\s*JM([1-9][0-9]*)\b',
            caseSensitive: false,
          ).firstMatch(element.text)?[1];
        })
        .whereType<String>()
        .firstOrNull;
    final title = _normalizedText(
      document.querySelector('#book-name')?.text ?? '',
    );
    if (id != reference.id || title.isEmpty) {
      throw const MetadataProviderException(
        'JMComic returned an unavailable page or an unexpected comic.',
      );
    }
    final tags = <String, List<String>>{};
    final authors = _links(
      document,
      'span[itemprop="author"][data-type="author"] a',
    );
    for (final (selector, namespace) in const [
      ('span[itemprop="genre"][data-type="tags"] a', 'tags'),
      ('span[itemprop="author"][data-type="works"] a', 'series'),
      ('span[itemprop="author"][data-type="actor"] a', 'character'),
    ]) {
      for (final value in _links(document, selector)) {
        _addTag(tags, namespace, value);
      }
    }
    final description = document
        .querySelectorAll('h2')
        .map((element) {
          final match = RegExp(
            r'[叙敘]述\s*[：:]\s*([\s\S]*)',
          ).firstMatch(element.text);
          return match == null ? null : _normalizedText(match[1]!);
        })
        .whereType<String>()
        .firstOrNull;
    final count = document
        .querySelectorAll('span.pagecount')
        .map((element) {
          return RegExp(r'[:：]\s*([0-9]+)').firstMatch(element.text)?[1];
        })
        .whereType<String>()
        .firstOrNull;
    return MetadataResult(
      reference: reference,
      title: title,
      authors: authors,
      tags: tags,
      description: description ?? '',
      pageCount: _positiveInt(count),
      coverUrl: jmCoverBaseUri
          .resolve('/media/albums/${reference.id}.jpg')
          .toString(),
    );
  }

  String? _validatedCover(MetadataProviderId provider, String value) {
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    return uri != null && isAllowedCoverUri(provider, uri)
        ? uri.toString()
        : null;
  }

  static String _text(Object? value) =>
      value is String || value is num ? '$value'.trim() : '';

  static String _normalizedText(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _decodeEntities(String value) =>
      _normalizedText(html.parseFragment(value).text ?? '');

  static int? _positiveInt(Object? value) {
    final number = int.tryParse(_text(value));
    return number != null && number > 0 ? number : null;
  }

  static List<String> _links(Document document, String selector) => document
      .querySelectorAll(selector)
      .map((element) => _normalizedText(element.text))
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList();

  static void _addTag(
    Map<String, List<String>> tags,
    String namespace,
    String value,
  ) {
    final key = namespace.trim();
    final normalized = value.trim();
    if (key.isEmpty || normalized.isEmpty) return;
    final values = tags.putIfAbsent(key, () => []);
    if (!values.contains(normalized)) values.add(normalized);
  }
}
