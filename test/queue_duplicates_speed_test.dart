import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temporary;
  late HttpServer server;
  late DownloadController controller;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('jdm_queue_v12_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path == '/missing') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/slow') {
          request.response.headers.contentLength = 24 * 1024;
          for (var i = 0; i < 24; i++) {
            request.response.add(List<int>.filled(1024, i));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 14));
          }
        } else {
          request.response.headers.contentLength = 3;
          request.response.add([1, 2, 3]);
        }
        await request.response.close();
      } catch (_) {
        // A Range probe deliberately abandons an unsupported response.
      }
    });
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
      speedSampleInterval: const Duration(milliseconds: 50),
      retryBaseDelay: const Duration(milliseconds: 30),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });

  String link(String path) => 'http://127.0.0.1:${server.port}/$path';

  Future<void> until(bool Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!predicate() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(predicate(), true);
  }

  test('detect duplicate URLs and permit an explicitly approved copy', () async {
    await controller.setQueuePaused(true);
    final first = await controller.addUrl(link('same.bin'));
    await expectLater(controller.addUrl('${link('same.bin')}#different-anchor'),
        throwsA(isA<DuplicateDownloadException>()));
    expect(controller.downloads.single.id, first.id);
    final second = await controller.addUrl(link('same.bin'),
        allowDuplicate: true);
    expect(second.id, isNot(first.id));
    expect(controller.downloads.length, 2);
  });

  test('move to top/bottom changes saved priority without losing jobs', () async {
    await controller.setQueuePaused(true);
    final a = await controller.addUrl(link('a.bin'));
    final b = await controller.addUrl(link('b.bin'));
    final c = await controller.addUrl(link('c.bin'));
    expect(controller.queuedInPriorityOrder.map((r) => r.id),
        [a.id, b.id, c.id]);
    expect(await controller.moveToFront(c.id), true);
    expect(controller.queuedInPriorityOrder.map((r) => r.id),
        [c.id, a.id, b.id]);
    expect(await controller.moveToBack(a.id), true);
    expect(controller.queuedInPriorityOrder.map((r) => r.id),
        [c.id, b.id, a.id]);
  });

  test('retry all failed queues each job once while queue is held', () async {
    final record = await controller.addUrl(link('missing'));
    await until(() => record.status == DownloadStatus.failed);
    await controller.setQueuePaused(true);
    expect(await controller.retryAllFailed(), 1);
    expect(record.status, DownloadStatus.queued);
    expect(record.retryAttempts, 0);
    expect(await controller.retryAllFailed(), 0);
  });

  test('live transfer speed graph records positive throughput', () async {
    final record = await controller.addUrl(link('slow'));
    await until(() => controller.speedHistory
        .any((sample) => sample.bytesPerSecond > 0));
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    expect(controller.speedHistory.length, greaterThan(1));
    expect(controller.speedHistory.length, lessThanOrEqualTo(60));
    expect(await File(record.savePath).length(), 24 * 1024);
  });
}
