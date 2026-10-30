import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/network/images.dart';

import 'metadata_models.dart';
import 'metadata_providers.dart';
import 'metadata_store.dart';

void configureMetadataCoverLoading([MetadataService? service]) {
  ImageDownloader.configureThumbnailBytesOverride((url) async {
    if (!url.startsWith('$metadataCoverScheme:')) return null;
    return (service ?? MetadataService()).loadCoverKey(url);
  });
}

class MetadataCoverException implements Exception {
  const MetadataCoverException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MetadataService {
  MetadataService.withDependencies({
    required MetadataGateway gateway,
    required this.store,
    Dio? coverDio,
    MetadataGateway Function(Uri, Uri)? gatewayFactory,
  }) : _gateway = gateway,
       _coverDio = coverDio ?? createMetadataDio(),
       _gatewayFactory =
           gatewayFactory ??
           ((base, cover) =>
               MetadataProviders(jmBaseUri: base, jmCoverBaseUri: cover));

  static MetadataService? _instance;

  /// Installs a client for integration tests using the real [MetadataStore.app].
  /// The previous client can be restored after a test; production defaults stay
  /// on the regular per-application-store constructor path.
  @visibleForTesting
  static MetadataService? installForTesting(MetadataService? service) {
    final previous = _instance;
    _instance = service;
    return previous;
  }

  factory MetadataService() {
    final store = MetadataStore.app;
    if (_instance?.store != store) {
      _instance?._coverDio.close(force: true);
      final base = store.preference('jmBaseUrl');
      final cover = store.preference('jmCoverBaseUrl');
      _instance = MetadataService.withDependencies(
        gateway: MetadataProviders(
          jmBaseUri: base == null ? null : Uri.tryParse(base),
          jmCoverBaseUri: cover == null ? null : Uri.tryParse(cover),
        ),
        store: store,
      );
    }
    return _instance!;
  }

  final MetadataStore store;
  MetadataGateway _gateway;
  final Dio _coverDio;
  final MetadataGateway Function(Uri, Uri) _gatewayFactory;
  Future<void> _writes = Future<void>.value();
  int _coverSequence = 0;

  static const maximumCoverBytes = 8 * 1024 * 1024;
  static const _maximumCoverPixels = 16 * 1024 * 1024;

  MetadataBinding? find(String sourceKey, String comicId) =>
      store.find(sourceKey, comicId);

  ComicDetails applyDetails(ComicDetails details) =>
      store.applyDetails(details);

  String get jmBaseUrl =>
      store.preference('jmBaseUrl') ??
      MetadataProviders.defaultJmBaseUri.toString();

  String get jmCoverBaseUrl =>
      store.preference('jmCoverBaseUrl') ??
      MetadataProviders.defaultJmCoverBaseUri.toString();

  Future<void> configureJm({
    required String baseUrl,
    required String coverBaseUrl,
  }) => _serialize(() async {
    final base = MetadataProviders.normalizeJmOrigin(baseUrl);
    final cover = MetadataProviders.normalizeJmOrigin(coverBaseUrl);
    final gateway = _gatewayFactory(base, cover);
    store.savePreferences({
      'jmBaseUrl': base.toString(),
      'jmCoverBaseUrl': cover.toString(),
    });
    _gateway = gateway;
  });

  Future<MetadataResult> fetch(String input, {MetadataProviderId? provider}) {
    final reference = _gateway.parseReference(input, provider: provider);
    return _gateway.fetch(reference);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<MetadataSaveResult> save({
    required String sourceKey,
    required String comicId,
    required MetadataResult result,
    required bool cacheCover,
  }) => _serialize(() async {
    if (result.title.trim().isEmpty) {
      throw const FormatException('The metadata title is empty');
    }
    final old = store.find(sourceKey, comicId);
    String? path;
    String? coverError;
    if (cacheCover && result.coverUrl?.isNotEmpty == true) {
      try {
        final bytes = await loadCover(result);
        final identity = jsonEncode([
          sourceKey,
          comicId,
          DateTime.now().microsecondsSinceEpoch,
          _coverSequence++,
        ]);
        path = '${sha256.convert(utf8.encode(identity))}.cover';
        final file = store.coverFile(path);
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      } catch (error) {
        if (path != null) await _deleteCover(path);
        path = null;
        coverError = error is MetadataCoverException
            ? error.message
            : 'The cover could not be cached. Metadata was saved locally.';
      }
    }
    final binding = MetadataBinding(
      sourceKey: sourceKey,
      comicId: comicId,
      result: result,
      cacheCover: cacheCover,
      coverPath: path,
      updatedAt: DateTime.now(),
    );
    try {
      store.save(binding);
    } catch (_) {
      if (path != null) await _deleteCover(path);
      rethrow;
    }
    if (old?.coverPath != null && old!.coverPath != path) {
      await _deleteCover(old.coverPath!);
    }
    return MetadataSaveResult(binding: binding, coverError: coverError);
  });

  Future<void> remove(String sourceKey, String comicId) => _serialize(() async {
    final old = store.find(sourceKey, comicId);
    store.remove(sourceKey, comicId);
    if (old?.coverPath != null) await _deleteCover(old!.coverPath!);
  });

  Future<void> _deleteCover(String path) async {
    try {
      final file = store.coverFile(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A cleanup failure must not roll back a committed metadata change.
    }
  }

  Future<Uint8List> loadBindingCover(MetadataBinding binding) async {
    final path = binding.coverPath;
    if (path != null) {
      final file = store.coverFile(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty && bytes.length <= maximumCoverBytes) return bytes;
      }
    }
    // This fallback remains memory-only, including when an old cache was removed.
    return loadCover(binding.result);
  }

  Future<Uint8List> loadCoverKey(String key) async {
    final binding = store.bindingForCoverKey(key);
    if (binding == null) {
      throw const MetadataCoverException(
        'The metadata cover is no longer bound.',
      );
    }
    return loadBindingCover(binding);
  }

  /// Download a validated image without using the application's disk cache or
  /// source cookie jars. All redirect destinations are checked before requests.
  Future<Uint8List> loadCover(MetadataResult result) async {
    var uri = Uri.tryParse(result.coverUrl ?? '');
    if (uri == null) {
      throw const MetadataCoverException('No cover is available.');
    }
    try {
      for (var redirects = 0; redirects <= 3; redirects++) {
        if (!_gateway.isAllowedCoverUri(result.reference.provider, uri!)) {
          throw const MetadataCoverException(
            'The cover address is not allowed.',
          );
        }
        final response = await _coverDio.getUri<ResponseBody>(
          uri,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            maxRedirects: 0,
            validateStatus: (_) => true,
          ),
        );
        final status = response.statusCode ?? 0;
        final body = response.data;
        if (status >= 300 && status < 400) {
          await body?.stream.listen(null).cancel();
          final location = response.headers.value('location');
          if (redirects == 3 || location == null) {
            throw const MetadataCoverException(
              'The cover redirect could not be followed.',
            );
          }
          uri = uri.resolve(location);
          continue;
        }
        if (status != 200 || body == null) {
          await body?.stream.listen(null).cancel();
          throw const MetadataCoverException('The cover request failed.');
        }
        final mime = response.headers
            .value(Headers.contentTypeHeader)
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        if (!const {
          'image/jpeg',
          'image/png',
          'image/webp',
          'image/gif',
        }.contains(mime)) {
          await body.stream.listen(null).cancel();
          throw const MetadataCoverException(
            'The cover response is not a supported image.',
          );
        }
        if (body.contentLength > maximumCoverBytes) {
          await body.stream.listen(null).cancel();
          throw const MetadataCoverException(
            'The cover is too large to cache.',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in body.stream) {
          if (bytes.length + chunk.length > maximumCoverBytes) {
            throw const MetadataCoverException(
              'The cover is too large to cache.',
            );
          }
          bytes.add(chunk);
        }
        final buffer = bytes.takeBytes();
        final decoder = image.findDecoderForData(buffer);
        final info = decoder?.startDecode(buffer);
        if (info == null ||
            info.width <= 0 ||
            info.height <= 0 ||
            info.width * info.height > _maximumCoverPixels ||
            decoder!.decodeFrame(0) == null) {
          throw const MetadataCoverException(
            'The cover image could not be decoded.',
          );
        }
        return buffer;
      }
    } on MetadataCoverException {
      rethrow;
    } catch (_) {
      throw const MetadataCoverException('The cover could not be loaded.');
    }
    throw const MetadataCoverException('The cover could not be loaded.');
  }
}
