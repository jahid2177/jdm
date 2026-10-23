import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/download/download_schedule_window.dart';
import 'package:jahid_download_manager/integration/clipboard_link_detector.dart';

void main() {
  test('weekday and overnight windows use local calendar days', () {
    const fridayNight = DownloadScheduleWindow(
      enabled: true, startMinute: 22 * 60,
      endMinute: 2 * 60, weekdays: 1 << 4);
    expect(fridayNight.allows(DateTime(2026, 10, 23, 23)), true);
    expect(fridayNight.allows(DateTime(2026, 10, 24, 1)), true);
    expect(fridayNight.allows(DateTime(2026, 10, 24, 3)), false);
    expect(fridayNight.allows(DateTime(2026, 10, 25, 1)), false);
    expect(DownloadScheduleWindow.fromJson(fridayNight.toJson())
        .allows(DateTime(2026, 10, 24, 1)), true);
    expect(const DownloadScheduleWindow(enabled: true, startMinute: 500,
        endMinute: 500).allows(DateTime(2026, 10, 23)), false);
  });

  test('clipboard suggests only valid public HTTP(S) URL', () {
    expect(ClipboardLinkDetector.firstValidLink('See https://example.com/a.zip.'),
        'https://example.com/a.zip');
    expect(ClipboardLinkDetector.firstValidLink('file:///etc/passwd'), null);
    expect(ClipboardLinkDetector.firstValidLink('https://a:b@site.com/x'), null);
    expect(ClipboardLinkDetector.firstValidLink('nothing here'), null);
    expect(ClipboardLinkDetector.firstValidLink('https://example.com/v.m3u8'),
        'https://example.com/v.m3u8');
  });

  group('recurring schedule automation', () {
    late Directory temp;
    late DownloadController controller;
    late HttpServer server;
    late DateTime clock;
    var requests = 0;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('jdm-automation-');
      clock = DateTime(2026, 10, 23, 23);
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        if (request.uri.path.contains('slow')) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        request.response.headers.contentLength = 4;
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      controller = DownloadController.forTesting(
        Directory('${temp.path}/state'),
        Directory('${temp.path}/files'),
        nowProvider: () => clock,
        scheduleCheckInterval: const Duration(milliseconds: 60),
      );
      await controller.initialize();
    });

    tearDown(() async {
      await controller.waitForIdle();
      controller.dispose();
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    String url(String path) => 'http://127.0.0.1:${server.port}/$path';

    test('closed window holds queue and opening respects global hold', () async {
      await controller.setQueuePaused(true);
      await controller.setDownloadWindow(const DownloadScheduleWindow(
        enabled: true, startMinute: 8 * 60, endMinute: 20 * 60));
      final record = await controller.addUrl(url('night.zip'));
      await controller.evaluateDownloadWindow();
      expect(record.status, DownloadStatus.paused);
      expect(record.pausedByScheduler, true);
      expect(requests, 0);

      clock = DateTime(2026, 10, 24, 12);
      await controller.evaluateDownloadWindow();
      expect(record.status, DownloadStatus.queued);
      expect(record.pausedByScheduler, false);
      expect(requests, 0); // The user is still holding the queue.
      await controller.setQueuePaused(false);
      await controller.waitForIdle();
      expect(record.status, DownloadStatus.completed);
      expect(await File(record.savePath).readAsBytes(), [1, 2, 3, 4]);
    });

    test('manual pause prevents automatic resume on next open window', () async {
      await controller.setQueuePaused(true);
      await controller.setDownloadWindow(const DownloadScheduleWindow(
        enabled: true, startMinute: 8 * 60, endMinute: 20 * 60));
      final record = await controller.addUrl(url('stay-paused.zip'));
      await controller.evaluateDownloadWindow();
      expect(record.pausedByScheduler, true);
      await controller.pause(record.id);
      expect(record.pausedByScheduler, false);
      clock = DateTime(2026, 10, 24, 12);
      await controller.evaluateDownloadWindow();
      expect(record.status, DownloadStatus.paused);
      expect(requests, 0);
    });

    test('preferences survive restart and scheduler flags are serialized', () async {
      await controller.setQueuePaused(true);
      await controller.setMaximumActivePerHost(1);
      await controller.setClipboardMonitoringEnabled(true);
      await controller.setThemePreference('dark');
      await controller.setDownloadWindow(const DownloadScheduleWindow(
        enabled: true, startMinute: 8 * 60, endMinute: 20 * 60));
      final record = await controller.addUrl(url('persistent.zip'));
      await controller.evaluateDownloadWindow();
      expect(DownloadRecord.fromJson(record.toJson()).pausedByScheduler, true);
      controller.dispose();
      controller = DownloadController.forTesting(
        Directory('${temp.path}/state'), Directory('${temp.path}/files'),
        nowProvider: () => clock,
        scheduleCheckInterval: const Duration(milliseconds: 60),
      );
      await controller.initialize();
      expect(controller.maxActivePerHost, 1);
      expect(controller.clipboardMonitoringEnabled, true);
      expect(controller.themePreference, 'dark');
      expect(controller.scheduleWindow.enabled, true);
      expect(controller.downloads.single.pausedByScheduler, true);
      expect(requests, 0);
    });

    test('invalid schedule cannot replace current policy', () async {
      await expectLater(controller.setDownloadWindow(
        const DownloadScheduleWindow(enabled: true, startMinute: 300,
            endMinute: 300)), throwsArgumentError);
      expect(controller.scheduleWindow.enabled, false);
    });

    test('host concurrency limit defers another task on the same host', () async {
      clock = DateTime(2026, 10, 23, 12);
      await controller.setMaximumActiveDownloads(3);
      await controller.setMaximumActivePerHost(1);
      final first = await controller.addUrl(url('slow-first.zip'));
      final second = await controller.addUrl(url('slow-second.zip'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(first.status, DownloadStatus.downloading);
      expect(second.status, DownloadStatus.queued);
      await controller.waitForIdle();
      expect(first.status, DownloadStatus.completed);
      expect(second.status, DownloadStatus.completed);
    });
  });
}
