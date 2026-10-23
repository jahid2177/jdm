import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../lib/download/download_controller.dart';
import '../lib/integration/browser_bridge_server.dart';
import '../native_messaging/lib/native_protocol.dart';

void main() {
  group('Native Messaging validation', () {
    test('encodes native-endian framed JSON response', () {
      final frame = encodeNativeResponse({'ok': true, 'taskId': 'x1'});
      expect(decodeNativeFrame(frame)['taskId'], 'x1');
      expect(() => decodeNativeFrame(frame.sublist(0, frame.length - 1)),
          throwsA(isA<NativeProtocolException>()));
    });

    test('allows HTTP(S) and rejects local commands and credentials', () {
      expect(validateDownloadMessage({
        'action': 'add_download', 'url': 'https://example.com/file.zip'
      })['url'], 'https://example.com/file.zip');
      for (final badUrl in [
        'file:///C:/windows/system.ini',
        'javascript:alert(1)',
        'https://username:secret@example.com/file',
        'C:\\Windows\\notepad.exe',
      ]) {
        expect(() => validateDownloadMessage({
          'action': 'add_download', 'url': badUrl,
        }), throwsA(isA<NativeProtocolException>()));
      }
      expect(() => validateDownloadMessage({
        'action': 'execute', 'url': 'https://example.com/'
      }), throwsA(isA<NativeProtocolException>()));
    });
  });

  test('loopback bridge requires bearer token and queues a real download', () async {
    final root = await Directory.systemTemp.createTemp('jdm-bridge-test-');
    final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fixture.listen((request) {
      request.response
        ..headers.contentType = ContentType('application', 'octet-stream')
        ..add(utf8.encode('example file bytes'));
      request.response.close();
    });
    final state = Directory('${root.path}/state');
    final downloads = Directory('${root.path}/downloads');
    final controller = DownloadController.forTesting(state, downloads);
    await controller.initialize();
    final bridge = await BrowserBridgeServer.start(
      controller, metadataDirectory: Directory('${root.path}/config'),
    );
    final metadata = jsonDecode(await File('${root.path}/config/bridge.json')
        .readAsString()) as Map<String, dynamic>;
    final client = HttpClient();

    Future<HttpClientResponse> send(String token, String url) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${metadata['port']}/download'),
      );
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'url': url}));
      return request.close();
    }

    try {
      final downloadUrl = 'http://127.0.0.1:${fixture.port}/hello.txt';
      final denied = await send('bad-token', downloadUrl);
      expect(denied.statusCode, HttpStatus.unauthorized);
      await denied.drain<void>();
      expect(controller.downloads, isEmpty);

      final invalid = await send(metadata['token'] as String, 'file:///oops');
      expect(invalid.statusCode, HttpStatus.badRequest);
      await invalid.drain<void>();
      expect(controller.downloads, isEmpty);

      final accepted = await send(metadata['token'] as String, downloadUrl);
      expect(accepted.statusCode, HttpStatus.ok);
      final receipt = jsonDecode(await utf8.decoder.bind(accepted).join());
      expect(receipt['ok'], true);
      await controller.waitForIdle();
      expect(controller.downloads.length, 1);
      expect(await File('${downloads.path}/hello.txt').readAsString(),
          'example file bytes');
    } finally {
      client.close(force: true);
      await bridge.close();
      await fixture.close(force: true);
      controller.dispose();
      await root.delete(recursive: true);
    }
  });
}
