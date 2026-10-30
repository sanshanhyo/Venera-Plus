import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_providers.dart';

typedef MetadataConnectivityGatewayFactory =
    MetadataGateway Function(Dio dio, Uri jmBaseUri, Uri jmCoverBaseUri);

bool isMetadataConnectivityEnabled(Map<String, String> env) =>
    env['CI_METADATA_CONNECTIVITY'] == 'true' &&
    env['GITHUB_ACTIONS'] == 'true';

class MetadataConnectivityConfig {
  const MetadataConnectivityConfig({
    this.ehGalleryUrl = '',
    this.jmReference = '',
    this.jmBaseUrl = '',
    this.jmCoverBaseUrl = '',
  });

  factory MetadataConnectivityConfig.fromEnvironment(Map<String, String> env) =>
      MetadataConnectivityConfig(
        ehGalleryUrl: env['EH_GALLERY_URL'] ?? '',
        jmReference: env['JM_REFERENCE'] ?? '',
        jmBaseUrl: env['JM_BASE_URL'] ?? '',
        jmCoverBaseUrl: env['JM_COVER_BASE_URL'] ?? '',
      );

  final String ehGalleryUrl;
  final String jmReference;
  final String jmBaseUrl;
  final String jmCoverBaseUrl;
}

/// Only these explicitly selected fields may enter a CI artifact. In particular,
/// references, response bodies and exception messages are never serialized.
class MetadataConnectivityCheck {
  const MetadataConnectivityCheck({
    required this.source,
    required this.operation,
    required this.host,
    required this.method,
    required this.outcome,
    required this.reason,
    this.status,
    this.durationMs = 0,
    this.presence = const {},
    this.counts = const {},
  });

  final String source;
  final String operation;
  final String host;
  final String method;
  final String outcome;
  final String reason;
  final int? status;
  final int durationMs;
  final Map<String, bool> presence;
  final Map<String, int> counts;

  Map<String, Object?> toJson() => {
    'source': source,
    'operation': operation,
    'host': host,
    'method': method,
    'outcome': outcome,
    'reason': reason,
    'http_status': status,
    'duration_ms': durationMs,
    if (presence.isNotEmpty) 'field_presence': presence,
    if (counts.isNotEmpty) 'field_counts': counts,
  };
}

class MetadataConnectivityReport {
  MetadataConnectivityReport(this.checks);

  final List<MetadataConnectivityCheck> checks;

  int get exitCode =>
      checks.any((check) => const {'failed', 'blocked'}.contains(check.outcome))
      ? 1
      : 0;

  static String _summary(Iterable<MetadataConnectivityCheck> checks) {
    final entries = checks.toList();
    if (entries.any((check) => check.outcome == 'failed')) return 'failed';
    if (entries.any((check) => check.outcome == 'blocked')) return 'blocked';
    if (entries.every((check) => check.outcome == 'skipped')) {
      return 'skipped_no_user_target';
    }
    return entries.any((check) => check.outcome == 'passed')
        ? 'passed'
        : 'observed';
  }

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'summary': {
      'probe_only': _summary(
        checks.where((check) => check.operation != 'metadata_read'),
      ),
      'requested_metadata': _summary(
        checks.where((check) => check.operation == 'metadata_read'),
      ),
      'exit_code': exitCode,
    },
    'cover_images_downloaded': false,
    'cover_network_verified': false,
    'checks': checks.map((check) => check.toJson()).toList(),
  };
}

Future<MetadataConnectivityReport> runMetadataConnectivity({
  required MetadataConnectivityConfig config,
  required Dio dio,
  MetadataConnectivityGatewayFactory? gatewayFactory,
}) => _ConnectivityRunner(config, dio, gatewayFactory).run();

class _ConnectivityRunner {
  _ConnectivityRunner(this.config, this.dio, this.gatewayFactory);

  static const probePath = '/__venera_metadata_connectivity_not_found__';
  static const maximumProbeBytes = 64 * 1024;
  final MetadataConnectivityConfig config;
  final Dio dio;
  final MetadataConnectivityGatewayFactory? gatewayFactory;
  final checks = <MetadataConnectivityCheck>[];
  String? _transportFailure;
  int? _lastStatus;

  Future<MetadataConnectivityReport> run() async {
    final observer = InterceptorsWrapper(
      onResponse: (response, handler) {
        _lastStatus = response.statusCode;
        handler.next(response);
      },
      onError: (error, handler) {
        _transportFailure = classifyMetadataTransportFailure(error);
        handler.next(error);
      },
    );
    dio.interceptors.add(observer);
    try {
      Uri? jmBase;
      Uri? jmCoverBase;
      try {
        jmBase = MetadataProviders.normalizeJmOrigin(
          config.jmBaseUrl.trim().isEmpty
              ? MetadataProviders.defaultJmBaseUri.toString()
              : config.jmBaseUrl,
        );
        jmCoverBase = MetadataProviders.normalizeJmOrigin(
          config.jmCoverBaseUrl.trim().isEmpty
              ? MetadataProviders.defaultJmCoverBaseUri.toString()
              : config.jmCoverBaseUrl,
        );
      } catch (_) {
        checks.add(
          const MetadataConnectivityCheck(
            source: 'jmcomic',
            operation: 'configuration',
            host: '',
            method: 'NONE',
            outcome: 'failed',
            reason: 'invalid_configuration',
          ),
        );
      }

      await _probe(
        source: 'ehentai',
        uri: Uri.parse('https://api.e-hentai.org/api.php'),
        method: 'POST',
        data: const {'method': 'gdata', 'gidlist': [], 'namespace': 1},
      );
      if (jmBase != null && jmCoverBase != null) {
        await _probe(
          source: 'jmcomic',
          uri: jmBase.resolve(probePath),
          method: 'HEAD',
        );
        await _probe(
          source: 'jmcomic_cover',
          uri: jmCoverBase.resolve(probePath),
          method: 'HEAD',
        );
      }

      final gateway =
          (gatewayFactory ??
          (dio, base, cover) => MetadataProviders(
            dio: dio,
            jmBaseUri: base,
            jmCoverBaseUri: cover,
          ))(
            dio,
            jmBase ?? MetadataProviders.defaultJmBaseUri,
            jmCoverBase ?? MetadataProviders.defaultJmCoverBaseUri,
          );
      await _metadata(
        gateway,
        provider: MetadataProviderId.ehentai,
        target: config.ehGalleryUrl,
        host: 'api.e-hentai.org',
        method: 'POST',
      );
      await _metadata(
        gateway,
        provider: MetadataProviderId.jmcomic,
        target: config.jmReference,
        host: jmBase?.host ?? '',
        method: 'GET',
        configurationValid: jmBase != null && jmCoverBase != null,
      );
      return MetadataConnectivityReport(List.unmodifiable(checks));
    } finally {
      dio.interceptors.remove(observer);
    }
  }

  Future<void> _probe({
    required String source,
    required Uri uri,
    required String method,
    Object? data,
  }) async {
    final timer = Stopwatch()..start();
    final token = CancelToken();
    _transportFailure = null;
    int? status;
    var outcome = 'failed';
    var reason = 'unexpected_probe_error';
    var presence = <String, bool>{};
    try {
      final options = Options(
        method: method,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (_) => true,
        responseType: ResponseType.stream,
        headers: {
          'User-Agent': 'Venera-Plus metadata connectivity',
          'Accept': method == 'POST' ? 'application/json' : '*/*',
          if (method == 'POST') 'Content-Type': 'application/json',
        },
      );
      ResponseBody? body;
      if (method == 'HEAD') {
        // Dio's normal response pipeline subscribes eagerly to a stream even
        // with ResponseType.stream. The raw adapter returns HEAD headers without
        // installing that body listener; cancelling then releases the request.
        body = await dio.httpClientAdapter.fetch(
          options.compose(dio.options, uri.toString(), cancelToken: token),
          null,
          token.whenCancel,
        );
        status = body.statusCode;
      } else {
        final response = await dio.request<ResponseBody>(
          uri.toString(),
          data: data,
          cancelToken: token,
          options: options,
        );
        status = response.statusCode;
        body = response.data;
      }
      final classification = classifyMetadataHttpStatus(status, method: method);
      outcome = classification.$1;
      reason = classification.$2;
      // HEAD observes the response headers only. A synthetic missing path says
      // nothing about real album availability or actual cover-image loading.
      if (method == 'POST' &&
          outcome == 'reached' &&
          status != null &&
          status < 500 &&
          !(status >= 300 && status < 400)) {
        if (body == null) {
          outcome = 'failed';
          reason = 'empty_protocol_response';
        } else {
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in body.stream) {
            if (bytes.length + chunk.length > maximumProbeBytes) {
              throw const _ProbeTooLarge();
            }
            bytes.add(chunk);
          }
          final Object? decoded;
          try {
            decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
          } on FormatException {
            throw const _InvalidProtocolResponse();
          }
          if (decoded is Map) {
            final hasApiError = decoded.containsKey('error');
            final hasGalleryList = decoded['gmetadata'] is List;
            presence = {
              'json_object': true,
              'api_error': hasApiError,
              'gallery_list': hasGalleryList,
            };
            reason = hasApiError
                ? 'structured_api_error_observed'
                : hasGalleryList
                ? 'structured_gallery_list_observed'
                : 'structured_json_observed';
          } else {
            throw const _InvalidProtocolResponse();
          }
        }
      }
    } on _ProbeTooLarge {
      reason = 'protocol_response_too_large';
      outcome = 'failed';
    } on _InvalidProtocolResponse {
      reason = 'protocol_response_not_json_object';
      outcome = 'blocked';
    } on DioException catch (error) {
      outcome = 'failed';
      reason = classifyMetadataTransportFailure(error);
    } on HandshakeException {
      outcome = 'failed';
      reason = 'tls_handshake_failed';
    } on SocketException catch (error) {
      outcome = 'failed';
      reason = _socketFailureReason(error);
    } catch (_) {
      outcome = 'failed';
      reason = _transportFailure ?? 'unexpected_probe_error';
    } finally {
      token.cancel();
      timer.stop();
    }
    checks.add(
      MetadataConnectivityCheck(
        source: source,
        operation: method == 'POST' ? 'protocol_probe' : 'head_probe',
        host: uri.host,
        method: method,
        outcome: outcome,
        reason: reason,
        status: status,
        durationMs: timer.elapsedMilliseconds,
        presence: presence,
      ),
    );
  }

  Future<void> _metadata(
    MetadataGateway gateway, {
    required MetadataProviderId provider,
    required String target,
    required String host,
    required String method,
    bool configurationValid = true,
  }) async {
    if (target.trim().isEmpty) {
      checks.add(
        MetadataConnectivityCheck(
          source: provider.name,
          operation: 'metadata_read',
          host: host,
          method: method,
          outcome: 'skipped',
          reason: 'skipped_no_user_target',
        ),
      );
      return;
    }
    final timer = Stopwatch()..start();
    _transportFailure = null;
    _lastStatus = null;
    var outcome = 'failed';
    var reason = configurationValid
        ? 'metadata_fetch_failed'
        : 'invalid_configuration';
    int? status;
    var presence = <String, bool>{};
    var counts = <String, int>{};
    if (configurationValid) {
      try {
        final reference = gateway.parseReference(target, provider: provider);
        final result = await gateway.fetch(reference);
        final identityMatches =
            result.reference.provider == reference.provider &&
            result.reference.id == reference.id &&
            result.reference.token == reference.token;
        final titlePresent = result.title.trim().isNotEmpty;
        final cover = result.coverUrl == null
            ? null
            : Uri.tryParse(result.coverUrl!);
        presence = {
          'identity_matches': identityMatches,
          'title': titlePresent,
          'authors': result.authors.isNotEmpty,
          'tags': result.tags.values.any((values) => values.isNotEmpty),
          'cover_url': cover != null,
          'cover_url_allowed':
              cover != null && gateway.isAllowedCoverUri(provider, cover),
          'page_count': result.pageCount != null,
        };
        counts = {
          'authors': result.authors.length,
          'tags': result.tags.values.fold(
            0,
            (count, values) => count + values.length,
          ),
        };
        outcome = identityMatches && titlePresent ? 'passed' : 'failed';
        reason = outcome == 'passed'
            ? 'metadata_schema_valid'
            : 'metadata_schema_invalid';
      } on FormatException {
        reason = 'invalid_reference';
      } on MetadataProviderException catch (error) {
        status = error.statusCode;
        if (status != null) {
          final classification = classifyMetadataHttpStatus(
            status,
            method: method,
          );
          outcome = classification.$1 == 'reached'
              ? 'failed'
              : classification.$1;
          reason = classification.$2;
        } else {
          reason =
              _transportFailure ?? 'metadata_response_invalid_or_unavailable';
        }
      } on DioException catch (error) {
        reason = classifyMetadataTransportFailure(error);
      } catch (_) {
        reason = _transportFailure ?? 'unexpected_metadata_error';
      }
    }
    status ??= _lastStatus;
    timer.stop();
    checks.add(
      MetadataConnectivityCheck(
        source: provider.name,
        operation: 'metadata_read',
        host: host,
        method: method,
        outcome: outcome,
        reason: reason,
        status: status,
        durationMs: timer.elapsedMilliseconds,
        presence: presence,
        counts: counts,
      ),
    );
  }
}

/// HTTP observations do not imply that a metadata record or image was read.
(String, String) classifyMetadataHttpStatus(
  int? status, {
  required String method,
}) {
  if (status == null) return ('failed', 'missing_http_status');
  if (status == 401 || status == 403) return ('blocked', 'access_restricted');
  if (status == 429) return ('blocked', 'rate_limited');
  if (status >= 500) return ('failed', 'server_error');
  if (status >= 300 && status < 400) return ('reached', 'redirect_observed');
  if (method == 'HEAD' && status == 405) {
    return ('reached', 'head_not_supported');
  }
  if (method == 'HEAD' && status == 404) {
    return ('reached', 'missing_probe_path_observed');
  }
  if (status >= 200 && status < 300) {
    return ('reached', 'http_response_observed');
  }
  // An empty gdata list may be rejected with structured JSON and a 4xx status.
  // That establishes protocol reachability only; the caller must inspect JSON.
  if (method == 'POST' && status >= 400 && status < 500) {
    return ('reached', 'protocol_http_error_observed');
  }
  return ('failed', 'http_error');
}

String classifyMetadataTransportFailure(DioException error) {
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout) {
    return 'request_timed_out';
  }
  if (error.type == DioExceptionType.badCertificate) {
    return 'tls_certificate_rejected';
  }
  final cause = error.error;
  if (cause is HandshakeException) return 'tls_handshake_failed';
  if (cause is SocketException) return _socketFailureReason(cause);
  if (error.type == DioExceptionType.cancel) return 'request_cancelled';
  return 'network_request_failed';
}

String _socketFailureReason(SocketException error) {
  final message = error.message.toLowerCase();
  if (message.contains('failed host lookup') ||
      message.contains('name or service not known') ||
      message.contains('nodename nor servname provided')) {
    return 'dns_lookup_failed';
  }
  return 'socket_connection_failed';
}

class _ProbeTooLarge implements Exception {
  const _ProbeTooLarge();
}

class _InvalidProtocolResponse implements Exception {
  const _InvalidProtocolResponse();
}
