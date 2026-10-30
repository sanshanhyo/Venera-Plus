import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/metadata_connectivity_probe.dart';

/// Explicit path and opt-in are both required. This file intentionally does not
/// end in `_test.dart`, so ordinary unit-test discovery cannot contact sites.
void main() {
  final env = Platform.environment;
  final enabled = isMetadataConnectivityEnabled(env);
  test(
    'manual metadata source connectivity',
    () async {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          followRedirects: false,
          maxRedirects: 0,
        ),
      );
      final destination = File(
        env['METADATA_CONNECTIVITY_REPORT'] ??
            'build/metadata-connectivity/report.json',
      );
      MetadataConnectivityReport report;
      try {
        report = await runMetadataConnectivity(
          config: MetadataConnectivityConfig.fromEnvironment(env),
          dio: dio,
        );
      } catch (_) {
        report = MetadataConnectivityReport([
          const MetadataConnectivityCheck(
            source: 'runner',
            operation: 'configuration',
            host: '',
            method: 'NONE',
            outcome: 'failed',
            reason: 'unexpected_runner_error',
          ),
        ]);
      } finally {
        dio.close(force: true);
      }
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
      expect(
        report.exitCode,
        0,
        reason:
            'Connectivity checks contain failed or blocked observations. '
            'See the sanitized metadata-connectivity report.',
      );
    },
    skip: enabled
        ? false
        : 'Requires GitHub Actions and explicit CI_METADATA_CONNECTIVITY=true.',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
