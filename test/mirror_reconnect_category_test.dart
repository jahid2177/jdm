import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late DownloadController controller;
  var primaryRequests = 0;
  final payload = List<int>.generate(8192, (index) => index % 251);

  setUp(() async {
    primaryRequests = 0;
    temp = await Directory.systemTemp.createTemp('jdm_mirror_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path == '/primary') {
          primaryRequests++;
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      } catch (_) {
        // Probes may intentionally close their separate HTTP connection.
      }
    });
    controller = DownloadController.forTesting(
      Directory('${temp.path}/state'),
      Directory('${temp.path}/downloads'),
      reconnectBaseDelay: const Duration(milliseconds: 45),
      retryBaseDelay: const Duration(milliseconds: 25),
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
    expect(condition(), isTrue, reason: 'The expected download state was not reached.');
  }

  test('fails over to a user-provided mirror before writing bytes', () async {
    final primary = 'http://127.0.0.1:${server.port}/primary';
    final alternate = 'http://127.0.0.1:${server.port}/mirror';
    final record = await controller.addUrl(primary,
        fileName: 'mirror.bin', alternateUrls: [alternate]);
    await until(() => record.status == DownloadStatus.completed);
    expect(primaryRequests, greaterThan(0));
    expect(record.activeMirrorIndex, 1);
    expect(record.activeUrl, alternate);
    expect(await File(record.savePath).readAsBytes(), payload);
  });

  test('rejects invalid alternate URL schemes and credentials', () async {
    await expectLater(
      controller.addUrl('https://example.org/file.bin',
          alternateUrls: ['file:///tmp/secrets']),
      throwsFormatException,
    );
    await expectLater(
      controller.addUrl('https://example.org/file.bin',
          alternateUrls: ['https://user:pass@example.org/file.bin']),
      throwsFormatException,
    );
    expect(controller.downloads, isEmpty);
  });

  test('does not switch a mirror after partial bytes exist', () async {
    await controller.setQueuePaused(true);
    await controller.setMaxAutomaticRetries(0);
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/primary',
      alternateUrls: ['http://127.0.0.1:${server.port}/mirror'],
    );
    final part = File('${record.savePath}.${record.id}.jdm-part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes([3, 1, 4, 1]);
    await controller.setQueuePaused(false);
    await until(() => record.status == DownloadStatus.failed);
    expect(record.activeMirrorIndex, 0);
    expect(await part.readAsBytes(), [3, 1, 4, 1]);
  });

  test('reconnect timer resumes a download when the source returns', () async {
    final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reservation.port;
    await reservation.close();
    final record = await controller.addUrl(
      'http://127.0.0.1:$port/back-online',
    );
    await until(() => record.waitingForNetwork &&
        record.status == DownloadStatus.queued);
    final restored = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    restored.listen((request) async {
      request.response.headers.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });
    try {
      await until(() => record.status == DownloadStatus.completed);
      expect(record.waitingForNetwork, isFalse);
      expect(await File(record.savePath).readAsBytes(), payload);
    } finally {
      await restored.close(force: true);
    }
  });

  test('turning reconnect off cancels waiting entries', () async {
    final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reservation.port;
    await reservation.close();
    final record = await controller.addUrl('http://127.0.0.1:$port/offline');
    await until(() => record.waitingForNetwork &&
        record.status == DownloadStatus.queued);
    await controller.setAutoResumeOnReconnect(false);
    expect(record.status, DownloadStatus.failed);
    expect(record.retryAt, isNull);
  });

  test('category folders and safe completed-file move preserve file bytes', () async {
    await controller.setQueuePaused(true);
    final record = await controller.addUrl(
      'http://127.0.0.1:${server.port}/document', fileName: 'guide.pdf');
    expect(record.category, DownloadCategory.documents);
    expect(record.savePath, contains('JDM${Platform.pathSeparator}Documents'));
    expect(await controller.changeCategory(record.id, DownloadCategory.music), isTrue);
    expect(record.savePath, contains('JDM${Platform.pathSeparator}Music'));
    await controller.setQueuePaused(false);
    await until(() => record.status == DownloadStatus.completed);
    final before = record.savePath;
    final archiveFolder = Directory(
        controller.categoryDirectoryPath(DownloadCategory.archives));
    await archiveFolder.create(recursive: true);
    final occupied = File('${archiveFolder.path}${Platform.pathSeparator}guide.pdf');
    await occupied.writeAsString('keep this file');
    expect(await controller.changeCategory(record.id, DownloadCategory.archives), isTrue);
    expect(record.savePath, isNot(occupied.path));
    expect(await File(record.savePath).readAsBytes(), payload);
    expect(await occupied.readAsString(), 'keep this file');
    expect(await File(before).exists(), isFalse);
  });

  test('mirror, category and reconnect preferences survive a restart', () async {
    await controller.setQueuePaused(true);
    await controller.setAutoResumeOnReconnect(false);
    await controller.addUrl('https://example.org/file.zip',
      alternateUrls: ['https://mirror.example.org/file.zip'],
      category: DownloadCategory.archives,
    );
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temp.path}/state'),
      Directory('${temp.path}/downloads'),
    );
    await controller.initialize();
    final record = controller.downloads.single;
    expect(record.category, DownloadCategory.archives);
    expect(record.alternateUrls, ['https://mirror.example.org/file.zip']);
    expect(controller.autoResumeOnReconnectEnabled, isFalse);
    expect(controller.queuePaused, isTrue);
  });
}
