import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';

void main() {
  late Directory temporary;
  late HttpServer server;
  late DownloadController controller;
  final payload = List<int>.generate(256 * 1024, (i) => i % 251);
  var rangeRequests = 0;

  setUp(() async {
    rangeRequests = 0;
    temporary = await Directory.systemTemp.createTemp('jdm_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final wantsRange = request.headers.value(HttpHeaders.rangeHeader);
        final supportsRange = request.uri.path != '/without-range';
        var start = 0;
        if (supportsRange && wantsRange != null) {
          final match = RegExp(r'^bytes=(\d+)-$').firstMatch(wantsRange);
          if (match != null) {
            start = int.parse(match.group(1)!);
            rangeRequests++;
          }
        }
        if (start > 0) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.contentRangeHeader,
              'bytes $start-${payload.length - 1}/${payload.length}');
        }
        request.response.headers.set(HttpHeaders.etagHeader, '"test-v1"');
        request.response.headers.contentLength = payload.length - start;
        final bytes = payload.sublist(start);
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

  test('rejects non-web and invalid URLs', () async {
    await expectLater(
        controller.addUrl('file:///etc/passwd'), throwsFormatException);
    await expectLater(controller.addUrl('hello'), throwsFormatException);
  });

  test('sanitizes unsafe filenames', () {
    expect(DownloadController.safeName('../unsafe.exe'), '.._unsafe.exe');
    expect(DownloadController.safeName('CON.txt'), '_CON.txt');
  });
}
