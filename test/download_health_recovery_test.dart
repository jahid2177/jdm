import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/download/download_storage_guard.dart';
import 'package:jahid_download_manager/download/segmented_downloader.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late DownloadController controller;
  final payload = List<int>.generate(4096, (i) => i % 251);
  var freeBytes = 10 * 1024 * 1024;
  var requestsForBody = 0;
  var rangeRequests = 0;

  setUp(() async {
    freeBytes = 10 * 1024 * 1024;
    requestsForBody = 0;
    rangeRequests = 0;
    temp = await Directory.systemTemp.createTemp('jdm_recovery_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) rangeRequests++;
        if (range == null) requestsForBody++;
        if (request.uri.path == '/segmented' ||
            request.uri.path == '/unconfirmed') {
          if (range != null) {
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
            if (match != null) {
              final from = int.parse(match.group(1)!);
              final to = match.group(2)!.isEmpty
                  ? payload.length - 1 : int.parse(match.group(2)!);
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(HttpHeaders.contentRangeHeader,
                  'bytes $from-$to/${payload.length}');
              if (request.uri.path == '/segmented') {
                request.response.headers.set(HttpHeaders.etagHeader, '"stable"');
              }
              request.response.headers.contentLength = to - from + 1;
              request.response.add(payload.sublist(from, to + 1));
              await request.response.close();
              return;
            }
          }
        }
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      } catch (_) {
        // A cancelled one-byte capability probe can close its response early.
      }
    });
    controller = DownloadController.forTesting(
      Directory('${temp.path}/state'),
      Directory('${temp.path}/downloads'),
      diskReserveBytes: 0,
      freeDiskBytesReader: (_) async => freeBytes,
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(condition(), isTrue, reason: 'Expected download state did not arrive.');
  }

  test('guard reserves assembly output and distinguishes unknown free space', () async {
    final guard = DownloadStorageGuard(
        reserveBytes: 100, reader: (_) async => 2000);
    final safe = await guard.assess('/destination',
        bytesStillToWrite: 800, assemblyBytes: 500);
    expect(safe.neededBytes, 1400);
    expect(safe.insufficient, isFalse);
    final low = await guard.assess('/destination',
        bytesStillToWrite: 1500, assemblyBytes: 500);
    expect(low.neededBytes, 2100);
    expect(low.insufficient, isTrue);

    final unavailable = DownloadStorageGuard(reader: (_) async => null);
    final unknown = await unavailable.assess('/destination',
        bytesStillToWrite: null);
    expect(unknown.canConfirmSpace, isFalse);
    expect(unknown.insufficient, isFalse);
    expect(unknown.totalSizeKnown, isFalse);
  });

  test('insufficient storage fails without publishing; retry after freeing space', () async {
    freeBytes = 100;
    final task = await controller.addUrl(url('plain'), fileName: 'disk-check.bin');
    await until(() => task.status == DownloadStatus.failed);
    expect(task.error, contains('Insufficient disk space'));
    expect(task.freeDiskBytes, 100);
    expect(await File(task.savePath).exists(), isFalse);

    freeBytes = 20 * 1024;
    await controller.resume(task.id);
    await until(() => task.status == DownloadStatus.completed);
    expect(await File(task.savePath).readAsBytes(), payload);
    expect(task.diskSpaceWarning, isNull);
  });

  test('segmented preflight includes second copy for assembly', () async {
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temp.path}/state'), Directory('${temp.path}/downloads'),
      segmentThresholdBytes: 128, connectionsPerFile: 4,
      diskReserveBytes: 0,
      freeDiskBytesReader: (_) async => freeBytes,
    );
    await controller.initialize();
    freeBytes = 6000; // 4096 bytes download + 4096 bytes assembly.
    final task = await controller.addUrl(url('segmented'),
        fileName: 'segmented-storage.bin');
    await until(() => task.status == DownloadStatus.failed);
    expect(task.estimatedDiskBytesNeeded, 8192);
    expect(task.downloadedBytes, 0);
    expect(task.segments, isNotEmpty);
    freeBytes = 20000;
    await controller.resume(task.id);
    await until(() => task.status == DownloadStatus.completed);
    expect(await File(task.savePath).readAsBytes(), payload);
    expect(task.segments, isEmpty);
  });

  test('recovery is opt-in and completes a full partial without any HTTP', () async {
    controller.dispose();
    final stateDir = Directory('${temp.path}/state');
    final targetDir = Directory('${temp.path}/downloads/JDM/General');
    await targetDir.create(recursive: true);
    final interrupted = DownloadRecord(
      id: 'interrupted-1', url: url('plain'),
      fileName: 'ready.bin', savePath: '${targetDir.path}/ready.bin',
      createdAt: DateTime.now(), status: DownloadStatus.downloading,
      totalBytes: payload.length, downloadedBytes: payload.length,
      expectedSha256: sha256.convert(payload).toString(),
    );
    final deliberatelyPaused = DownloadRecord(
      id: 'manual-1', url: url('plain'),
      fileName: 'paused.bin', savePath: '${targetDir.path}/paused.bin',
      createdAt: DateTime.now(), status: DownloadStatus.paused,
    );
    await File('${interrupted.savePath}.${interrupted.id}.jdm-part')
        .writeAsBytes(payload);
    await File('${stateDir.path}/downloads.json').writeAsString(
        jsonEncode([interrupted.toJson(), deliberatelyPaused.toJson()]));

    controller = DownloadController.forTesting(stateDir,
        Directory('${temp.path}/downloads'),
        diskReserveBytes: 0, freeDiskBytesReader: (_) async => freeBytes);
    await controller.initialize();
    final recovered = controller.downloads.first;
    expect(recovered.status, DownloadStatus.paused);
    expect(recovered.recoveryNeeded, isTrue);
    expect(controller.interruptedCount, 1);
    expect(await controller.recoverInterruptedDownloads(), 1);
    await until(() => recovered.status == DownloadStatus.completed);
    expect(await File(recovered.savePath).readAsBytes(), payload);
    expect(recovered.actualSha256, sha256.convert(payload).toString());
    expect(requestsForBody, 0);
    expect(rangeRequests, 0);
    expect(controller.interruptedCount, 0);
    expect(controller.downloads.last.status, DownloadStatus.paused);
  });

  test('no resume validator means a clean HTTP 200, never mixed bytes', () async {
    await controller.setQueuePaused(true);
    final task = await controller.addUrl(url('unconfirmed'),
        fileName: 'unconfirmed.bin');
    final part = File('${task.savePath}.${task.id}.jdm-part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes([1, 2, 3, 4, 5]);
    task.downloadedBytes = 5;
    task.totalBytes = payload.length;
    await controller.setQueuePaused(false);
    await until(() => task.status == DownloadStatus.completed);
    expect(await File(task.savePath).readAsBytes(), payload);
    // The normal one-byte range capability probe is allowed; the real
    // response must not send Range without a saved validator.
    expect(requestsForBody, 1);
  });

  test('missing validator on ranged response retains the existing partial', () async {
    await controller.setQueuePaused(true);
    final task = await controller.addUrl(url('unconfirmed'),
        fileName: 'validator-missing.bin');
    final part = File('${task.savePath}.${task.id}.jdm-part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes([9, 8, 7, 6, 5]);
    task.downloadedBytes = 5;
    task.totalBytes = payload.length;
    task.etag = '"saved-etag"';
    await controller.setQueuePaused(false);
    await until(() => task.status == DownloadStatus.failed);
    expect(task.error, contains('Cannot safely resume'));
    expect(await part.readAsBytes(), [9, 8, 7, 6, 5]);
    expect(await File(task.savePath).exists(), isFalse);
  });

  test('fully saved segments recover offline and leave no segment files', () async {
    controller.dispose();
    final stateDir = Directory('${temp.path}/state');
    final targetDir = Directory('${temp.path}/downloads/JDM/General');
    await targetDir.create(recursive: true);
    final record = DownloadRecord(
      id: 'segments-1', url: url('segmented'),
      fileName: 'offline-segments.bin',
      savePath: '${targetDir.path}/offline-segments.bin',
      createdAt: DateTime.now(), status: DownloadStatus.downloading,
      totalBytes: payload.length, downloadedBytes: payload.length,
      etag: '"stable"', expectedSha256: sha256.convert(payload).toString(),
      segments: SegmentedDownloader.plan(payload.length, 4),
    );
    for (final segment in record.segments) {
      final file = SegmentedDownloader.segmentFile(record, segment);
      await file.writeAsBytes(payload.sublist(segment.start, segment.end + 1));
      segment.downloadedBytes = segment.length;
    }
    await File('${stateDir.path}/downloads.json').writeAsString(
        jsonEncode([record.toJson()]));
    controller = DownloadController.forTesting(
      stateDir, Directory('${temp.path}/downloads'),
      diskReserveBytes: 0, freeDiskBytesReader: (_) async => freeBytes,
    );
    await controller.initialize();
    final recovered = controller.downloads.single;
    expect(recovered.recoveryNeeded, isTrue);
    expect(await controller.recoverInterruptedDownloads(), 1);
    await until(() => recovered.status == DownloadStatus.completed);
    expect(await File(recovered.savePath).readAsBytes(), payload);
    expect(recovered.segments, isEmpty);
    expect(rangeRequests, 0);
    expect(requestsForBody, 0);
    for (final segment in record.segments) {
      expect(await SegmentedDownloader.segmentFile(record, segment).exists(),
          isFalse);
    }
  });

  test('persisted interrupted flag remains recoverable through restarts', () {
    final record = DownloadRecord(
      id: 'recover', url: 'https://example.com/b', fileName: 'b',
      savePath: '/test/b', createdAt: DateTime.now(),
      status: DownloadStatus.paused, recoveryNeeded: true,
    );
    expect(DownloadRecord.fromJson(record.toJson()).recoveryNeeded, isTrue);
  });
}
