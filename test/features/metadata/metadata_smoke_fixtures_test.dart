import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_providers.dart';
import 'package:venera_plus/features/metadata/metadata_service.dart';
import 'package:venera_plus/features/metadata/metadata_store.dart';
import 'package:venera_plus/foundation/app.dart';

import '../../fixtures/metadata_smoke_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android UI fixtures parse through the real EH and JM providers',
    () async {
      final adapter = MetadataSmokeAdapter();
      final providers = MetadataProviders(
        dio: Dio()..httpClientAdapter = adapter,
        jmBaseUri: Uri.parse(smokeJmBaseUrl),
        jmCoverBaseUri: Uri.parse(smokeJmCoverBaseUrl),
        requestInterval: Duration.zero,
      );
      final eh = await providers.fetch(
        providers.parseReference(
          smokeEhReference,
          provider: MetadataProviderId.ehentai,
        ),
      );
      expect(eh.title, smokeEhTitle);
      expect(eh.authors, ['示例作者']);
      expect(eh.tags['language'], ['chinese']);
      expect(eh.coverUrl, 'https://ehgt.org/venera-smoke/field-notes.png');

      final jm = await providers.fetch(
        providers.parseReference(
          smokeJmReference,
          provider: MetadataProviderId.jmcomic,
        ),
      );
      expect(jm.title, smokeJmTitle);
      expect(jm.authors, ['旅行画室']);
      expect(jm.pageCount, 32);
      expect(jm.coverUrl, '$smokeJmCoverBaseUrl/media/albums/777888.jpg');
      expect(adapter.requests, hasLength(2));
      for (final png in [adapter.ehCover, adapter.jmCover]) {
        final decoded = image.decodePng(png)!;
        expect(decoded.width, 320);
        expect(decoded.height, 440);
      }
    },
  );

  test(
    'UI singleton injection restores and resets the normal app client',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'metadata-smoke-seam-',
      );
      App.dataPath = temporary.path;
      App.cachePath = '${temporary.path}/cache';
      MetadataStore.resetForTesting();
      final beforeTest = MetadataService.installForTesting(null);
      try {
        final normal = MetadataService();
        final adapter = MetadataSmokeAdapter();
        final injected = MetadataService.withDependencies(
          store: MetadataStore.app,
          gateway: MetadataProviders(
            dio: Dio()..httpClientAdapter = adapter,
            requestInterval: Duration.zero,
          ),
          coverDio: Dio()..httpClientAdapter = adapter,
        );
        final previous = MetadataService.installForTesting(injected);
        expect(previous, same(normal));
        expect(MetadataService(), same(injected));
        final metadata = await MetadataService().fetch(smokeEhReference);
        expect(metadata.title, smokeEhTitle);
        expect(adapter.requests, hasLength(1));

        MetadataService.installForTesting(previous);
        expect(MetadataService(), same(normal));
        MetadataService.installForTesting(null);
        final reset = MetadataService();
        expect(reset, isNot(same(injected)));
        expect(reset, isNot(same(normal)));
        expect(reset.store, same(MetadataStore.app));
      } finally {
        MetadataService.installForTesting(beforeTest);
        MetadataStore.resetForTesting();
        temporary.deleteSync(recursive: true);
      }
    },
  );
}
