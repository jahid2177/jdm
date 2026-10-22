import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/download/segmented_downloader.dart';

void main() {
  late Directory temporary;
  late HttpServer server;
  late DownloadController controller;
  final payload = List<int>.generate(256 * 1024, (i) => i % 251);
  var rangeRequests = 0;
  var responseEtag = '"test-v1"';

  setUp(() async {
    rangeRequests = 0;
    responseEtag = '"test-v1"';
    temporary = await Directory.systemTemp.createTemp('jdm_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final wantsRange = request.headers.value(HttpHeaders.rangeHeader);
        final supportsRange = request.uri.path != '/without-range';
        var start = 0;
        var end = payload.length - 1;
        if (supportsRange && wantsRange != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(wantsRange);
          if (match != null) {
            start = int.parse(match.group(1)!);
            if (match.group(2)!.isNotEmpty) {
              end = int.parse(match.group(2)!);
            }
            rangeRequests++;
          }
        }
        if (supportsRange && wantsRange != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${payload.length}');
        }
        request.response.headers.set(HttpHeaders.etagHeader, responseEtag);
        request.response.headers.contentLength = end - start + 1;
        final bytes = payload.sublist(start, end + 1);
        if (request.uri.path == '/slow') {
          for (var i = 0; i < bytes.length; i += 2048) {
            request.response.add(bytes.sublist(
                i, (i + 2048).clamp(0, bytes.length).toInt()));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 3));
          }
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      } catch (_) {
        // Expected when a paused task closes its active socket.
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

  test('downloads a real HTTP file byte for byte', () async {
    final record = await controller.addUrl(
        'http://127.0.0.1:${server.port}/file.bin');
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    expect(await File(record.savePath).readAsBytes(), payload);
  });

  test('works if a server ignores Range support', () async {
    final record = await controller.addUrl(
        'http://127.0.0.1:${server.port}/without-range', fileName: 'test.bin');
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    expect(await File(record.savePath).readAsBytes(), payload);
  });

  test('pauses then resumes only the remaining bytes', () async {
    final record = await controller.addUrl(
        'http://127.0.0.1:${server.port}/slow', fileName: 'large.bin');
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (record.downloadedBytes < 16 * 1024 &&
        record.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(record.downloadedBytes, greaterThan(0));
    expect(record.status, DownloadStatus.downloading);
    await controller.pause(record.id);
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.paused);
    await controller.resume(record.id);
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    expect(rangeRequests, greaterThanOrEqualTo(1));
    expect(await File(record.savePath).readAsBytes(), payload);
  });

  Future<void> useSegmentedEngine() async {
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
      segmentThresholdBytes: 64 * 1024,
      connectionsPerFile: 4,
    );
    await controller.initialize();
  }

  test('downloads and assembles four real HTTP byte ranges', () async {
    await useSegmentedEngine();
    final record = await controller.addUrl(
        'http://127.0.0.1:${server.port}/file.bin', fileName: 'segmented.bin');
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    expect(record.segments, isEmpty);
    expect(rangeRequests, greaterThanOrEqualTo(5)); // probe + 4 parts
    expect(await File(record.savePath).readAsBytes(), payload);
    final leftovers = controller.downloadDirectory
        .listSync()
        .where((entity) => entity.path.contains('.seg-'));
    expect(leftovers, isEmpty);
  });

  test('simultaneous downloads do not overwrite the same filename', () async {
    final a = await controller.addUrl(
        'http://127.0.0.1:${server.port}/one', fileName: 'same.bin');
    final b = await controller.addUrl(
        'http://127.0.0.1:${server.port}/two', fileName: 'same.bin');
    await controller.waitForIdle();
    expect(a.status, DownloadStatus.completed);
    expect(b.status, DownloadStatus.completed);
    expect(a.savePath, isNot(b.savePath));
    expect(await File(a.savePath).readAsBytes(), payload);
    expect(await File(b.savePath).readAsBytes(), payload);
  });

  test('recovers saved segments after controller restart', () async {
    await useSegmentedEngine();
    final record = await controller.addUrl(
        'http://127.0.0.1:${server.port}/slow', fileName: 'recover.bin');
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (record.downloadedBytes < 16 * 1024 &&
        record.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(record.status, DownloadStatus.downloading);
    await controller.pause(record.id);
    await controller.waitForIdle();
    final partialBytes = record.downloadedBytes;
    expect(partialBytes, greaterThan(0));
    controller.dispose();
    controller = DownloadController.forTesting(
      Directory('${temporary.path}/state'),
      Directory('${temporary.path}/downloads'),
      segmentThresholdBytes: 64 * 1024,
    );
    await controller.initialize();
    final recovered = controller.downloads.single;
    expect(recovered.status, DownloadStatus.paused);
    expect(recovered.downloadedBytes, greaterThan(0));
    await controller.resume(recovered.id);
    await controller.waitForIdle();
    expect(recovered.status, DownloadStatus.completed);
    expect(await File(recovered.savePath).readAsBytes(), payload);
  });

  test('changed remote ETag invalidates old segment bytes', () async {
    await useSegmentedEngine();
    final record = await controller.addUrl(
        'http://127.0.0.1:${server.port}/slow', fileName: 'changed.bin');
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (record.downloadedBytes < 16 * 1024 &&
        record.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(record.status, DownloadStatus.downloading);
    await controller.pause(record.id);
    await controller.waitForIdle();
    responseEtag = '"test-v2"';
    await controller.resume(record.id);
    await controller.waitForIdle();
    expect(record.status, DownloadStatus.completed);
    expect(await File(record.savePath).readAsBytes(), payload);
  });

  test('rejects non-web and invalid URLs', () async {
    await expectLater(
        controller.addUrl('file:///etc/passwd'), throwsFormatException);
    await expectLater(controller.addUrl('hello'), throwsFormatException);
  });

  test('sanitizes unsafe filenames', () {
    expect(DownloadController.safeName('../unsafe.exe'), '.._unsafe.exe');
    expect(DownloadController.safeName('CON.txt'), '_CON.txt');
  });

  test('segment planning covers each byte exactly once', () {
    final segments = SegmentedDownloader.plan(1025, 4);
    expect(segments.first.start, 0);
    expect(segments.last.end, 1024);
    for (var i = 1; i < segments.length; i++) {
      expect(segments[i].start, segments[i - 1].end + 1);
    }
    expect(segments.fold<int>(0, (sum, segment) => sum + segment.length), 1025);
  });
}
