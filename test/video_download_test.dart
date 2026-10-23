import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_controller.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/video/hls_vod_downloader.dart';
import 'package:jahid_download_manager/video/video_source_detector.dart';

void main() {
  test('detects direct video, HLS and DASH by URL or MIME', () {
    expect(VideoSourceDetector.detect(Uri.parse('https://host/video.mp4?t=1')),
        DownloadKind.directVideo);
    expect(VideoSourceDetector.detect(Uri.parse('https://host/hls.m3u8')),
        DownloadKind.hls);
    expect(VideoSourceDetector.detect(Uri.parse('https://host/video.mpd')),
        DownloadKind.dash);
    expect(VideoSourceDetector.detect(Uri.parse('https://host/play?id=4'),
        mimeType: 'application/vnd.apple.mpegurl'), DownloadKind.hls);
    expect(VideoSourceDetector.detect(Uri.parse('https://host/play?id=4'),
        mimeType: 'video/mp4'), DownloadKind.directVideo);
    expect(VideoSourceDetector.detect(Uri.parse('https://host/article')),
        DownloadKind.file);
    expect(VideoSourceDetector.transportStreamName('movie.mp4'), 'movie.ts');
  });

  late Directory working;
  late HttpServer server;
  late DownloadController controller;
  final first = List<int>.generate(188 * 4, (i) => i % 188 == 0 ? 0x47 : 0x11);
  final second = List<int>.generate(188 * 6, (i) => i % 188 == 0 ? 0x47 : 0x22);
  final newSecond = List<int>.generate(188 * 6, (i) => i % 188 == 0 ? 0x47 : 0x33);
  var changedPlaylist = false;

  setUp(() async {
    changedPlaylist = false;
    working = await Directory.systemTemp.createTemp('jdm-video-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final path = request.uri.path;
        if (path.endsWith('.m3u8') || path == '/stream') {
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          final text = switch (path) {
            '/master.m3u8' => '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=9000
movie.m3u8
''',
            '/encrypted.m3u8' => '''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key"
#EXTINF:4,
first.ts
#EXT-X-ENDLIST
''',
            '/low.m3u8' => '''#EXTM3U
#EXTINF:4,
first.ts
#EXT-X-ENDLIST
''',
            '/separate-audio.m3u8' => '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=9000,AUDIO="a1"
movie.m3u8
''',
            '/live.m3u8' => '''#EXTM3U
#EXTINF:4,
first.ts
''',
            '/mp4.m3u8' => '''#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4,
first.m4s
#EXT-X-ENDLIST
''',
            '/changed.m3u8' => '''#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:4,
first.ts
#EXTINF:4,
${changedPlaylist ? 'third.ts' : 'second.ts?slow'}
#EXT-X-ENDLIST
''',
            _ => '''#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:4,
first.ts
#EXTINF:4,
second.ts
#EXT-X-ENDLIST
''',
          };
          request.response.write(text);
        } else if (path.endsWith('.ts')) {
          request.response.headers.contentType = ContentType('video', 'mp2t');
          final bytes = switch (path) {
            '/first.ts' => first,
            '/third.ts' => newSecond,
            _ => second,
          };
          request.response.headers.contentLength = bytes.length;
          if (path == '/second.ts' && request.uri.query == 'slow') {
            for (var index = 0; index < bytes.length; index += 188) {
              request.response.add(bytes.sublist(index, index + 188));
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 35));
            }
          } else {
            request.response.add(bytes);
          }
        } else if (path.endsWith('.mpd')) {
          request.response.headers.contentType =
              ContentType('application', 'dash+xml');
          request.response.write('<MPD/>');
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } catch (_) {
        // Pausing an active download closes its network connection.
      }
    });
    controller = DownloadController.forTesting(
      Directory('${working.path}/state'),
      Directory('${working.path}/downloads'),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await controller.waitForIdle();
    controller.dispose();
    await server.close(force: true);
    await working.delete(recursive: true);
  });

  String link(String path) => 'http://127.0.0.1:${server.port}$path';

  test('downloads unencrypted VOD HLS to a real TS file', () async {
    final task = await controller.addUrl(link('/movie.m3u8'), fileName: 'film.mp4');
    expect(task.fileName, 'film.ts');
    await controller.waitForIdle();
    expect(task.status, DownloadStatus.completed);
    expect(task.kind, DownloadKind.hls);
    expect(task.hlsCompletedSegments, 2);
    expect(task.hlsTotalSegments, 2);
    expect(task.savePath.endsWith('.ts'), true);
    expect(await File(task.savePath).readAsBytes(), [...first, ...second]);
  });

  test('selects highest bandwidth master variant', () async {
    final task = await controller.addUrl(link('/master.m3u8'));
    await controller.waitForIdle();
    expect(task.status, DownloadStatus.completed);
    expect(await File(task.savePath).readAsBytes(), [...first, ...second]);
  });

  test('detects HLS even at an extensionless URL via response MIME', () async {
    final task = await controller.addUrl(link('/stream'), fileName: 'clip');
    await controller.waitForIdle();
    expect(task.status, DownloadStatus.completed);
    expect(task.kind, DownloadKind.hls);
    expect(task.fileName, 'clip.ts');
    expect(await File(task.savePath).readAsBytes(), [...first, ...second]);
  });

  test('encrypted, live and fragmented playlists are rejected clearly', () async {
    for (final path in [
      '/encrypted.m3u8', '/live.m3u8', '/mp4.m3u8',
      '/separate-audio.m3u8',
    ]) {
      final task = await controller.addUrl(link(path));
      await controller.waitForIdle();
      expect(task.status, DownloadStatus.failed, reason: path);
      expect(task.error, contains('HLS not supported'));
    }
  });

  test('DASH is identified and not falsely reported as a saved video', () async {
    final task = await controller.addUrl(link('/video.mpd'));
    await controller.waitForIdle();
    expect(task.kind, DownloadKind.dash);
    expect(task.status, DownloadStatus.failed);
    expect(task.error, contains('DASH/MPD'));
  });

  test('resuming from a changed playlist discards obsolete committed bytes', () async {
    final resumed = await controller.addUrl(link('/changed.m3u8'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (resumed.hlsCompletedSegments < 1 &&
        resumed.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(resumed.hlsCompletedSegments, 1);
    await controller.pause(resumed.id);
    await controller.waitForIdle();
    changedPlaylist = true;
    await controller.resume(resumed.id);
    await controller.waitForIdle();
    expect(resumed.status, DownloadStatus.completed);
    expect(await File(resumed.savePath).readAsBytes(), [...first, ...newSecond]);
  });

  test('resume of same HLS playlist does not duplicate an interrupted segment', () async {
    final task = await controller.addUrl(link('/changed.m3u8'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (task.hlsCompletedSegments < 1 &&
        task.status == DownloadStatus.downloading &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(task.hlsCompletedSegments, 1);
    await controller.pause(task.id);
    await controller.waitForIdle();
    expect(task.hlsCommittedBytes, first.length);
    await controller.resume(task.id);
    await controller.waitForIdle();
    expect(task.status, DownloadStatus.completed);
    expect(await File(task.savePath).readAsBytes(), [...first, ...second]);
  });

  test('parses the same HLS variant deterministically', () async {
    final client = HttpClient();
    try {
      final one = await HlsVodDownloader.loadPlaylist(client,
          Uri.parse(link('/master.m3u8')));
      final two = await HlsVodDownloader.loadPlaylist(client,
          Uri.parse(link('/master.m3u8')));
      expect(one.fingerprint, two.fingerprint);
      expect(one.segments.length, 2);
    } finally {
      client.close(force: true);
    }
  });
}
