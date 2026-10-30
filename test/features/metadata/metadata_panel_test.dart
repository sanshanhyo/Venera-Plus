import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/metadata/metadata_models.dart';
import 'package:venera_plus/features/metadata/metadata_panel.dart';
import 'package:venera_plus/features/metadata/metadata_service.dart';

final _result = MetadataResult(
  reference: const MetadataReference(
    provider: MetadataProviderId.jmcomic,
    id: '12345',
    sourceUrl: 'https://18comic.vip/album/12345/',
  ),
  title: 'Test comic',
  authors: const ['Test artist'],
  tags: const {
    'tags': ['adventure', 'color'],
  },
  pageCount: 12,
);

MetadataBinding _binding({bool cached = false}) => MetadataBinding(
  sourceKey: 'local',
  comicId: 'local-book',
  result: _result,
  cacheCover: cached,
  coverPath: cached ? '/test/cover.png' : null,
  updatedAt: DateTime.utc(2026, 10, 30),
);

void main() {
  test('entry supports local comics and excludes unrelated online sources', () {
    expect(supportsMetadataCompletion('local'), isTrue);
    expect(supportsMetadataCompletion('unrelated-online-source'), isFalse);
  });

  testWidgets('empty reference does not request or save information', (
    tester,
  ) async {
    final service = _Service();
    await _pumpPanel(tester, service);
    await _tap(tester, 'metadata-fetch');

    expect(find.text('Enter a source link or ID'), findsOneWidget);
    expect(service.requests, isEmpty);
    expect(service.savedPolicies, isEmpty);
  });

  testWidgets(
    'local storage failure disables the panel with a readable error',
    (tester) async {
      final service = _Service()
        ..findError = StateError('Database unavailable');
      await _pumpPanel(tester, service);

      expect(find.text('Local information is unavailable'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('metadata-fetch')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      expect(service.requests, isEmpty);
    },
  );

  testWidgets('fetch previews information and saves only on confirmation', (
    tester,
  ) async {
    final service = _Service();
    var changes = 0;
    await _pumpPanel(tester, service, onChanged: () => changes++);
    await tester.enterText(
      find.byKey(const Key('metadata-reference')),
      'https://e-hentai.org/g/12345/0123456789/',
    );
    await _tap(tester, 'metadata-fetch');

    expect(service.requests, ['https://e-hentai.org/g/12345/0123456789/']);
    expect(service.providers, [MetadataProviderId.ehentai]);
    expect(find.text('Test comic'), findsOneWidget);
    expect(find.text('Test artist'), findsOneWidget);
    expect(find.text('adventure, color'), findsOneWidget);
    expect(service.savedPolicies, isEmpty);
    expect(changes, 0);

    await _tap(tester, 'metadata-save');

    expect(service.savedPolicies, [false]);
    expect(service.savedIdentities, ['local/local-book']);
    expect(find.text('Information saved locally'), findsOneWidget);
    expect(changes, 1);
  });

  testWidgets('cover cache selection reaches save independently of metadata', (
    tester,
  ) async {
    final service = _Service();
    await _pumpPanel(tester, service);
    await tester.enterText(
      find.byKey(const Key('metadata-reference')),
      'https://e-hentai.org/g/12345/0123456789/',
    );
    await _tap(tester, 'metadata-fetch');
    await _tap(tester, 'metadata-cache-cover');
    await _tap(tester, 'metadata-save');

    expect(service.savedPolicies, [true]);
  });

  testWidgets('editing the reference invalidates the old preview', (
    tester,
  ) async {
    final service = _Service();
    await _pumpPanel(tester, service);
    await tester.enterText(find.byKey(const Key('metadata-reference')), '123');
    await _tap(tester, 'metadata-fetch');
    expect(find.byKey(const Key('metadata-save')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('metadata-reference')), '456');
    await tester.pump();

    expect(find.byKey(const Key('metadata-save')), findsNothing);
    expect(find.text('Test comic'), findsNothing);
    expect(service.savedPolicies, isEmpty);
  });

  testWidgets('JM addresses can be changed before fetching information', (
    tester,
  ) async {
    final service = _Service()..binding = _binding();
    await _pumpPanel(tester, service);
    await _tap(tester, 'metadata-jm-settings');
    await tester.enterText(
      find.byKey(const Key('metadata-jm-base-url')),
      'https://jm.example',
    );
    await tester.enterText(
      find.byKey(const Key('metadata-jm-cover-base-url')),
      'https://images.example',
    );
    await _tap(tester, 'metadata-fetch');

    expect(service.configurations, [
      ['https://jm.example', 'https://images.example'],
    ]);
    expect(service.providers, [MetadataProviderId.jmcomic]);
  });

  testWidgets('fetch error stays visible without a savable result', (
    tester,
  ) async {
    final service = _Service()..fetchError = Exception('Source unavailable');
    await _pumpPanel(tester, service);
    await tester.enterText(find.byKey(const Key('metadata-reference')), '123');
    await _tap(tester, 'metadata-fetch');

    expect(find.text('Source unavailable'), findsOneWidget);
    expect(find.byKey(const Key('metadata-save')), findsNothing);
    expect(service.savedPolicies, isEmpty);
  });

  testWidgets(
    'pending fetch cannot duplicate and safely finishes after close',
    (tester) async {
      final pending = Completer<MetadataResult>();
      final service = _Service()..pending = pending;
      await _pumpPanel(tester, service);
      await tester.enterText(
        find.byKey(const Key('metadata-reference')),
        '123',
      );
      await tester.tap(find.byKey(const Key('metadata-fetch')));
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('metadata-fetch')),
      );
      expect(button.onPressed, isNull);
      final input = tester.widget<TextField>(
        find.byKey(const Key('metadata-reference')),
      );
      expect(input.enabled, isFalse);
      expect(service.requests, hasLength(1));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      pending.complete(_result);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(service.savedPolicies, isEmpty);
    },
  );

  testWidgets('cover failure reports saved information and missing cache', (
    tester,
  ) async {
    final service = _Service()..coverError = 'Cover unavailable';
    var changes = 0;
    await _pumpPanel(tester, service, onChanged: () => changes++);
    await tester.enterText(find.byKey(const Key('metadata-reference')), '123');
    await _tap(tester, 'metadata-fetch');
    await _tap(tester, 'metadata-cache-cover');
    await _tap(tester, 'metadata-save');

    expect(
      find.text('Information saved, but the cover could not be cached'),
      findsOneWidget,
    );
    expect(find.text('Cover is not cached locally'), findsOneWidget);
    expect(changes, 1);
  });

  testWidgets(
    'save failure keeps existing binding and does not report success',
    (tester) async {
      final service = _Service()
        ..binding = _binding()
        ..saveError = Exception('Local storage unavailable');
      var changes = 0;
      await _pumpPanel(tester, service, onChanged: () => changes++);
      await _tap(tester, 'metadata-save');

      expect(
        find.text('Information could not be saved locally'),
        findsOneWidget,
      );
      expect(find.text('Information saved locally'), findsNothing);
      expect(find.byKey(const Key('metadata-remove')), findsOneWidget);
      expect(changes, 0);
    },
  );

  testWidgets('existing binding loads locally and removal needs confirmation', (
    tester,
  ) async {
    final service = _Service()..binding = _binding(cached: true);
    var changes = 0;
    await _pumpPanel(tester, service, onChanged: () => changes++);
    final input = tester.widget<TextField>(
      find.byKey(const Key('metadata-reference')),
    );
    expect(input.controller!.text, _result.reference.sourceUrl);
    expect(service.requests, isEmpty);
    expect(find.text('Saved source: JMComic'), findsOneWidget);
    expect(find.text('Cover cached locally'), findsOneWidget);

    await _tap(tester, 'metadata-remove');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.removals, isEmpty);
    expect(changes, 0);

    await _tap(tester, 'metadata-remove');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(service.removals, ['local/local-book']);
    expect(find.text('Saved information removed'), findsOneWidget);
    expect(find.byKey(const Key('metadata-remove')), findsNothing);
    expect(changes, 1);
  });

  testWidgets('compact sidebar avoids keyboard and remains scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final service = _Service();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMetadataPanel(
                context,
                sourceKey: 'local',
                comicId: 'local-book',
                comicTitle: 'Original title',
                service: service,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byKey(const Key('metadata-reference')), '123');
    await _tap(tester, 'metadata-fetch');
    await _tap(tester, 'metadata-save');
    expect(service.savedPolicies, [false]);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPanel(
  WidgetTester tester,
  _Service service, {
  VoidCallback? onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MetadataPanel(
        sourceKey: 'local',
        comicId: 'local-book',
        comicTitle: 'Original title',
        service: service,
        onChanged: onChanged,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Service implements MetadataService {
  MetadataBinding? binding;
  Object? fetchError;
  Object? findError;
  Object? saveError;
  String? coverError;
  Completer<MetadataResult>? pending;
  final requests = <String>[];
  final providers = <MetadataProviderId?>[];
  final savedPolicies = <bool>[];
  final savedIdentities = <String>[];
  final removals = <String>[];
  final configurations = <List<String>>[];

  @override
  String jmBaseUrl = 'https://18comic.vip';

  @override
  String jmCoverBaseUrl = 'https://cdn-msp.jmapiproxy3.cc';

  @override
  Future<void> configureJm({
    required String baseUrl,
    required String coverBaseUrl,
  }) async {
    configurations.add([baseUrl, coverBaseUrl]);
    jmBaseUrl = baseUrl;
    jmCoverBaseUrl = coverBaseUrl;
  }

  @override
  MetadataBinding? find(String sourceKey, String comicId) {
    if (findError != null) throw findError!;
    return binding;
  }

  @override
  Future<MetadataResult> fetch(
    String input, {
    MetadataProviderId? provider,
  }) async {
    requests.add(input);
    providers.add(provider);
    if (fetchError != null) throw fetchError!;
    return pending == null ? _result : pending!.future;
  }

  @override
  Future<MetadataSaveResult> save({
    required String sourceKey,
    required String comicId,
    required MetadataResult result,
    required bool cacheCover,
  }) async {
    if (saveError != null) throw saveError!;
    savedIdentities.add('$sourceKey/$comicId');
    savedPolicies.add(cacheCover);
    binding = MetadataBinding(
      sourceKey: sourceKey,
      comicId: comicId,
      result: result,
      cacheCover: cacheCover,
      coverPath: cacheCover && coverError == null ? '/test/cover.png' : null,
      updatedAt: DateTime.utc(2026, 10, 30),
    );
    return MetadataSaveResult(binding: binding!, coverError: coverError);
  }

  @override
  Future<void> remove(String sourceKey, String comicId) async {
    removals.add('$sourceKey/$comicId');
    binding = null;
  }

  @override
  Future<Uint8List> loadCover(MetadataResult result) async => Uint8List(0);

  @override
  Future<Uint8List> loadBindingCover(MetadataBinding binding) async =>
      Uint8List(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
