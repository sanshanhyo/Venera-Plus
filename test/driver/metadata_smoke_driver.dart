import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:integration_test/integration_test_driver.dart';

const _requiredNames = <String>[
  '01_local_menu',
  '02_eh_preview_cache_off',
  '03_eh_preview_cache_on',
  '04_eh_saved_local_list',
  '05_jm_settings',
  '06_jm_preview_cache_off',
  '07_jm_saved_local_list',
  '08_removed_restored',
];
const _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 12),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final directory = Directory('build/metadata-smoke-artifacts')
      ..createSync(recursive: true);
    final manifest = <String, dynamic>{
      'passed': false,
      'fixture': 'synthetic-metadata-and-generated-non-adult-covers',
      'liveNetwork': false,
      'requiredScreenshots': _requiredNames,
      'screenshots': <Map<String, dynamic>>[],
    };
    final file = File('${directory.path}/manifest.json');
    try {
      final report = data?['metadataSmoke'];
      if (report is! Map || report['screenshots'] is! Map) {
        throw StateError('Missing metadata smoke report.');
      }
      manifest['scenarios'] = report;
      if (report['liveNetwork'] != false ||
          report['fixture'] !=
              'synthetic-metadata-and-generated-non-adult-covers') {
        throw StateError('The fixture evidence marker is invalid.');
      }
      final screenshots = report['screenshots'] as Map;
      for (final entry in screenshots.entries) {
        final name = entry.key;
        final encoded = entry.value;
        if (name is! String ||
            !RegExp(r'^[0-9]{2}_[a-z_]+$').hasMatch(name) ||
            encoded is! String) {
          throw StateError('Invalid screenshot name or payload.');
        }
        final bytes = base64Decode(encoded);
        if (bytes.length < 24) {
          throw StateError('Screenshot $name is empty or truncated.');
        }
        for (var i = 0; i < _pngSignature.length; i++) {
          if (bytes[i] != _pngSignature[i]) {
            throw StateError('Screenshot $name has an invalid PNG signature.');
          }
        }
        final header = ByteData.sublistView(bytes);
        final width = header.getUint32(16);
        final height = header.getUint32(20);
        if (width < 320 || height < 600 || width >= height) {
          throw StateError(
            'Screenshot $name is not a readable portrait frame.',
          );
        }
        File('${directory.path}/$name.png').writeAsBytesSync(bytes);
        (manifest['screenshots'] as List).add({
          'name': '$name.png',
          'width': width,
          'height': height,
          'bytes': bytes.length,
          'pngValidated': true,
          'scenePassed':
              (report['completedScenes'] as List?)?.contains(name) ?? false,
        });
      }
      // Keep report metadata small: the PNGs are separate host artifacts.
      manifest['scenarios'] = {
        for (final entry in report.entries)
          if (entry.key != 'screenshots') entry.key: entry.value,
      };
      final complete =
          _requiredNames.every(screenshots.containsKey) &&
          _requiredNames.every(
            (name) =>
                (report['completedScenes'] as List?)?.contains(name) ?? false,
          );
      manifest['passed'] = report['passed'] == true && complete;
      if (manifest['passed'] != true) {
        throw StateError(
          'Metadata smoke did not complete every required scene.',
        );
      }
      stdout.writeln(
        'Validated all ${_requiredNames.length} metadata UI frames.',
      );
    } catch (error) {
      manifest['driverError'] = error.toString();
      rethrow;
    } finally {
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(manifest),
      );
    }
  },
);
