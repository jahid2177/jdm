import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temporary;
  late HttpServer server;
  late DownloadController controller;
  var requests = 0;

  setUp(() async {
    requests = 0;
    temporary = await Directory.systemTemp.createTemp('jdm-schedule-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.binary;
      request.response.add([1, 2, 3, 4, 5]);
      await request.response.close();
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

  String url() => 'http://127.0.0.1:${server.port}/scheduled.bin';

  Future<void> waitUntilComplete(DownloadRecord record) async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (record.status != DownloadStatus.completed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    await controller.waitForIdle();
  }

  test('future schedule is persisted and starts when due', () async {
    final due = DateTime.now().add(const Duration(milliseconds: 900));
    final record = await controller.addUrl(url(), scheduledAt: due);
    expect(record.status, DownloadStatus.queued);
    expect(requests, 0);
    expect(DownloadRecord.fromJson(record.toJson()).scheduledAt, due);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(record.status, DownloadStatus.queued);
    expect(requests, 0);
    await waitUntilComplete(record);
    expect(record.status, DownloadStatus.completed);
    expect(requests, greaterThan(0));
    expect(await File(record.savePath).readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('scheduled queue wakes up after app state reload', () async {
    final due = DateTime.now().add(const Duration(milliseconds: 1100));
    final queued = await controller.addUrl(url(), scheduledAt: due);
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
    );
    await controller.initialize();
    final restored = controller.downloads.single;
    expect(restored.id, queued.id);
    expect(restored.scheduledAt, due);
    expect(restored.status, DownloadStatus.queued);
    expect(requests, 0);
    await waitUntilComplete(restored);
    expect(restored.status, DownloadStatus.completed);
  });

  test('manual Resume cancels a future schedule and starts immediately', () async {
    final record = await controller.addUrl(url(),
        scheduledAt: DateTime.now().add(const Duration(hours: 2)));
    await controller.resume(record.id);
    await controller.waitForIdle();
    expect(record.scheduledAt, null);
    expect(record.status, DownloadStatus.completed);
  });

  test('paused scheduled task never auto-starts', () async {
    final record = await controller.addUrl(url(),
        scheduledAt: DateTime.now().add(const Duration(milliseconds: 260)));
    await controller.pause(record.id);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(record.status, DownloadStatus.paused);
    expect(requests, 0);
  });
}
