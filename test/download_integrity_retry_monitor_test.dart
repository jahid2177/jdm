import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temporary;
  late HttpServer server;
  late DownloadController controller;
  final payload = List<int>.generate(4096, (index) => index % 251);
  final replacement = List<int>.generate(4096, (index) => (index + 17) % 251);
  var useReplacement = false;
  var flakyAttempts = 0;
  var neverAttempts = 0;

  setUp(() async {
    useReplacement = false;
    flakyAttempts = 0;
    neverAttempts = 0;
    temporary = await Directory.systemTemp.createTemp('jdm_sha256_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final hasRange = request.headers.value(HttpHeaders.rangeHeader) != null;
        if (request.uri.path == '/flaky' && !hasRange && ++flakyAttempts <= 2) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/never' && !hasRange) {
          neverAttempts++;
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }
        final body = useReplacement ? replacement : payload;
        request.response.headers.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      } catch (_) {
        // Some range probes cancel their own response once headers arrive.
      }
    });
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
      segmentThresholdBytes: 1024 * 1024,
      retryBaseDelay: const Duration(milliseconds: 25),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!condition() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(condition(), isTrue,
        reason: 'Download did not reach its expected state in time.');
  }

  String url(String path) => 'http://127.0.0.1:${server.port}/$path';

  test('valid expected SHA-256 completes and persists actual hash', () async {
    final digest = sha256.convert(payload).toString();
    final record = await controller.addUrl(url('right'),
        fileName: 'verified.bin', expectedSha256: digest.toUpperCase());
    await until(() => record.status == DownloadStatus.completed);
    expect(record.expectedSha256, digest);
    expect(record.actualSha256, digest);
    expect(await File(record.savePath).readAsBytes(), payload);
    final restored = DownloadRecord.fromJson(record.toJson());
    expect(restored.actualSha256, digest);
    expect(restored.expectedSha256, digest);
  });

  test('hash mismatch never publishes final file; restart downloads clean', () async {
    final wanted = sha256.convert(replacement).toString();
    final record = await controller.addUrl(url('changed'),
        fileName: 'needs-clean-retry.bin', expectedSha256: wanted);
    await until(() => record.status == DownloadStatus.failed);
    expect(record.error, contains('SHA-256 mismatch'));
    expect(record.actualSha256, sha256.convert(payload).toString());
    expect(await File(record.savePath).exists(), isFalse);
    final partial = File('${record.savePath}.${record.id}.jdm-part');
    expect(await partial.exists(), isTrue);
    expect(await partial.readAsBytes(), payload);

    useReplacement = true;
    expect(await controller.restartFromZero(record.id), isTrue);
    await until(() => record.status == DownloadStatus.completed);
    expect(record.actualSha256, wanted);
    expect(await File(record.savePath).readAsBytes(), replacement);
    expect(await partial.exists(), isFalse);
    expect(await controller.restartFromZero(record.id), isFalse);
  });

  test('invalid SHA-256 input does not create a download', () async {
    await expectLater(controller.addUrl(url('invalid'), expectedSha256: '1234'),
        throwsFormatException);
    expect(controller.downloads, isEmpty);
  });

  test('per-download policy never disables transient HTTP retries', () async {
    final record = await controller.addUrl(url('never'),
        retryPolicy: DownloadRetryPolicy.never);
    await until(() => record.status == DownloadStatus.failed);
    expect(neverAttempts, 1);
    expect(record.retryAttempts, 0);
    expect(controller.retryLimitFor(record), 0);
  });

  test('extended policy retries when global retries are disabled', () async {
    await controller.setMaxAutomaticRetries(0);
    final record = await controller.addUrl(url('flaky'),
        retryPolicy: DownloadRetryPolicy.extended);
    await until(() => record.status == DownloadStatus.completed);
    expect(flakyAttempts, 3);
    expect(controller.retryLimitFor(record), 5);
    expect(record.retryPolicy, DownloadRetryPolicy.extended);
    expect(DownloadRecord.fromJson(record.toJson()).retryPolicy,
        DownloadRetryPolicy.extended);
  });

  test('ETA and stall states do not over-promise when speed is unknown', () {
    final record = DownloadRecord(
      id: 'eta', url: 'https://example.com/eta', fileName: 'eta.bin',
      savePath: '/tmp/eta.bin', createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
      totalBytes: 1000, downloadedBytes: 400,
    );
    expect(record.estimatedTimeRemaining, isNull);
    record.bytesPerSecond = 200;
    expect(record.estimatedTimeRemaining, const Duration(seconds: 3));
    record.lastProgressAt = DateTime.now().subtract(const Duration(seconds: 16));
    expect(record.isStalled, isTrue);
    final old = DownloadRecord.fromJson(record.toJson());
    expect(old.retryPolicy, DownloadRetryPolicy.standard);
    expect(old.lastProgressAt, isNull);
    expect(old.actualSha256, isNull);
  });
}
