import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_rate_limiter.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temporary;
  late HttpServer server;
  late DownloadController controller;
  late List<String> requests;
  final bytes = List<int>.generate(64 * 1024, (i) => i % 251);

  setUp(() async {
    requests = [];
    temporary = await Directory.systemTemp.createTemp('jdm-queue-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri.path);
      try {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.contentLength = bytes.length;
        if (request.uri.path == '/slow.bin') {
          for (var i = 0; i < bytes.length; i += 2048) {
            request.response.add(bytes.sublist(i, i + 2048));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      } catch (_) {
        // Pausing or probing is allowed to close connections mid-response.
      }
    });
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}/$path';

  test('held queue starts in manually selected priority order', () async {
    await controller.setQueuePaused(true);
    await controller.setMaximumActiveDownloads(1);
    final first = await controller.addUrl(url('first.bin'));
    final second = await controller.addUrl(url('second.bin'));
    expect(requests, isEmpty);
    expect(controller.queuedInPriorityOrder.map((r) => r.id),
        [first.id, second.id]);
    expect(await controller.moveEarlier(second.id), true);
    expect(controller.queuedInPriorityOrder.map((r) => r.id),
        [second.id, first.id]);
    expect(await controller.moveLater(second.id), true);
    expect(await controller.moveEarlier(second.id), true);
    await controller.setQueuePaused(false);
    await controller.waitForIdle();
    expect(first.status, DownloadStatus.completed);
    expect(second.status, DownloadStatus.completed);
    expect(requests.first, '/second.bin');
  });

  test('pause all and resume all keep downloaded data valid', () async {
    await controller.setMaximumActiveDownloads(1);
    final first = await controller.addUrl(url('slow.bin'));
    final second = await controller.addUrl(url('other.bin'));
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (first.downloadedBytes < 4096 &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(first.downloadedBytes, greaterThan(0));
    await controller.pauseAll();
    await controller.waitForIdle();
    expect(controller.queuePaused, true);
    expect(first.status, DownloadStatus.paused);
    expect(second.status, DownloadStatus.paused);
    await controller.resumeAll();
    await controller.waitForIdle();
    expect(first.status, DownloadStatus.completed);
    expect(second.status, DownloadStatus.completed);
    expect(await File(first.savePath).readAsBytes(), bytes);
    expect(await File(second.savePath).readAsBytes(), bytes);
  });

  test('queue and rate preferences are persisted across restart', () async {
    await controller.setQueuePaused(true);
    await controller.setMaximumActiveDownloads(2);
    await controller.setSpeedLimitKibPerSecond(256);
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
    );
    await controller.initialize();
    expect(controller.queuePaused, true);
    expect(controller.maxSimultaneous, 2);
    expect(controller.speedLimitKibPerSecond, 256);
  });

  test('global token bucket actually waits when rate is exceeded', () async {
    final limiter = DownloadRateLimiter(bytesPerSecond: 2048);
    final clock = Stopwatch()..start();
    await limiter.acquire(2048, isActive: () => true);
    clock.stop();
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(650));
    limiter.setBytesPerSecond(0);
    await limiter.acquire(4096, isActive: () => true);
  });

  test('controller applies the configured cap to real HTTP downloads', () async {
    await controller.setSpeedLimitKibPerSecond(64);
    final timer = Stopwatch()..start();
    final record = await controller.addUrl(url('capped.bin'));
    await controller.waitForIdle();
    timer.stop();
    expect(record.status, DownloadStatus.completed);
    expect(timer.elapsedMilliseconds, greaterThanOrEqualTo(500));
    expect(await File(record.savePath).readAsBytes(), bytes);
  });

  test('token bucket responds quickly to a cancelled download', () async {
    final limiter = DownloadRateLimiter(bytesPerSecond: 1024);
    var active = true;
    final pending = limiter.acquire(64 * 1024, isActive: () => active);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    active = false;
    await pending.timeout(const Duration(seconds: 2));
  });
}
