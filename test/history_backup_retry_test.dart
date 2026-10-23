import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_history_backup.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late DownloadController controller;
  var flakyRequests = 0;
  var missingRequests = 0;

  setUp(() async {
    flakyRequests = 0;
    missingRequests = 0;
    temp = await Directory.systemTemp.createTemp('jdm_history_retry_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final isProbe = request.headers.value(HttpHeaders.rangeHeader) != null;
      if (request.uri.path == '/flaky' && !isProbe) {
        flakyRequests++;
        if (flakyRequests <= 2) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }
      } else if (request.uri.path == '/missing' && !isProbe) {
        missingRequests++;
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      } else if (request.uri.path == '/always-503' && !isProbe) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      request.response.headers.contentLength = 4;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    controller = DownloadController.forTesting(
      Directory('${temp.path}/state'),
      Directory('${temp.path}/downloads'),
      retryBaseDelay: const Duration(milliseconds: 30),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!condition() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(condition(), isTrue, reason: 'Download did not reach the expected state.');
  }

  test('history JSON restores only paused metadata and skips duplicates', () async {
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/ok', fileName: 'history.bin',
    );
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    final original = File(record.savePath);
    final originalBytes = await original.readAsBytes();

    final backup = controller.exportHistoryJson();
    expect(backup, contains(DownloadHistoryBackup.format));
    final first = await controller.restoreHistoryJson(backup);
    expect(first.restored, 0);
    expect(first.skipped, 1);

    await controller.remove(record.id);
    final imported = await controller.restoreHistoryJson(backup);
    expect(imported.restored, 1);
    final restored = controller.downloads.single;
    expect(restored.status, DownloadStatus.paused);
    expect(restored.downloadedBytes, 0);
    expect(restored.id, isNot(record.id));
    expect(await original.readAsBytes(), originalBytes);
  });

  test('invalid history formats and URLs are rejected atomically', () async {
    expect(() => DownloadHistoryBackup.decode('{}'), throwsFormatException);
    final malformed = '''{
      "format":"jahid-download-manager-history",
      "version":1,
      "downloads":[{
        "url":"file:///etc/passwd","fileName":"bad.txt",
        "createdAt":"2026-01-01T00:00:00Z"
      }]
    }''';
    await expectLater(controller.restoreHistoryJson(malformed),
        throwsFormatException);
    expect(controller.downloads, isEmpty);
  });

  test('auto retries transient HTTP 503 then completes', () async {
    var observedRetries = 0;
    controller.addListener(() {
      for (final task in controller.downloads) {
        if (task.url.endsWith('/flaky') &&
            task.retryAttempts > observedRetries) {
          observedRetries = task.retryAttempts;
        }
      }
    });
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/flaky',
    );
    await until(() => record.status == DownloadStatus.completed);
    expect(flakyRequests, 3);
    expect(observedRetries, 2);
    expect(record.retryAttempts, 0);
    expect(await File(record.savePath).readAsBytes(), [1, 2, 3, 4]);
  });

  test('HTTP 404 fails immediately instead of repeated requests', () async {
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/missing',
    );
    await until(() => record.status == DownloadStatus.failed);
    expect(missingRequests, 1);
    expect(record.retryAttempts, 0);
  });

  test('HTTP 503 stops after the configured retry limit', () async {
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/always-503',
    );
    await until(() => record.status == DownloadStatus.failed);
    expect(record.retryAttempts, 2);
    expect(record.error, contains('503'));
  });

  test('manual pause cancels waiting automatic retry', () async {
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/flaky',
    );
    await until(() => record.retryAt != null &&
        record.status == DownloadStatus.queued);
    await controller.pause(record.id);
    expect(record.status, DownloadStatus.paused);
    final attempts = flakyRequests;
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(flakyRequests, attempts);
  });

  test('disabling retries cancels an already scheduled retry', () async {
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/flaky',
    );
    await until(() => record.retryAt != null &&
        record.status == DownloadStatus.queued);
    await controller.setMaxAutomaticRetries(0);
    expect(record.status, DownloadStatus.failed);
    final attempts = flakyRequests;
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(flakyRequests, attempts);
  });

  test('retry count setting survives an application restart', () async {
    await controller.setMaxAutomaticRetries(5);
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temp.path}/state'),
      Directory('${temp.path}/downloads'),
    );
    await controller.initialize();
    expect(controller.maxAutomaticRetries, 5);
  });
}
