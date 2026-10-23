import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory root;
  late DownloadController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jdm-completion-settings-');
    controller = DownloadController.forTesting(
      Directory('${root.path}/state'),
      Directory('${root.path}/downloads'),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await root.delete(recursive: true);
  });

  test('auto-export and completion-notification opt-ins persist', () async {
    expect(controller.androidAutoExportEnabled, false);
    expect(controller.androidCompletionNotificationsEnabled, false);
    await controller.setAndroidAutoExportEnabled(true);
    await controller.setAndroidCompletionNotificationsEnabled(true);

    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${root.path}/state'),
      Directory('${root.path}/downloads'),
    );
    await controller.initialize();
    expect(controller.androidAutoExportEnabled, true);
    expect(controller.androidCompletionNotificationsEnabled, true);
  });

  test('export result and error persist on an individual completed task', () async {
    await controller.setQueuePaused(true);
    final record = await controller.addUrl('https://example.test/file.bin');
    await controller.recordAndroidExportResult(
      record.id,
      uri: 'content://example.test/premature',
    );
    expect(record.androidDownloadsUri, null);

    record.status = DownloadStatus.completed;
    await controller.recordAndroidExportResult(
      record.id,
      error: 'Device is full',
    );
    expect(record.androidExportError, 'Device is full');
    await controller.recordAndroidExportResult(
      record.id,
      uri: 'content://downloads/file.bin',
    );
    expect(record.androidExportError, null);

    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${root.path}/state'),
      Directory('${root.path}/downloads'),
    );
    await controller.initialize();
    final restored = controller.downloads.single;
    expect(restored.androidDownloadsUri, 'content://downloads/file.bin');
    expect(restored.androidExportError, null);
  });

  test('an older persisted task can be read without export metadata', () {
    final record = DownloadRecord(
      id: 'legacy',
      url: 'https://example.test/legacy.bin',
      fileName: 'legacy.bin',
      savePath: '/private/legacy.bin',
      createdAt: DateTime(2026, 1, 1),
    );
    final previousFormat = record.toJson()
      ..remove('androidDownloadsUri')
      ..remove('androidExportError');
    final restored = DownloadRecord.fromJson(previousFormat);
    expect(restored.androidDownloadsUri, isNull);
    expect(restored.androidExportError, isNull);
  });
}
