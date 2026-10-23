import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../download/download_controller.dart';

/// Same-user Windows bridge for the browser Native Messaging executable.
/// Only a random localhost port is opened; the browser never calls this port.
class BrowserBridgeServer {
  BrowserBridgeServer._(this._server, this._metadataFile, this._token, this._downloads);

  static const maxRequestBytes = 16 * 1024;
  final HttpServer _server;
  final File _metadataFile;
  final String _token;
  final DownloadController _downloads;

  int get port => _server.port;

  static Directory defaultMetadataDirectory() {
    final appData = Platform.environment['APPDATA'];
    if (!Platform.isWindows || appData == null || appData.isEmpty) {
      throw StateError('The bridge requires Windows APPDATA.');
    }
    return Directory('$appData${Platform.pathSeparator}JahidDownloadManager');
  }

  static Future<BrowserBridgeServer> start(
    DownloadController downloads, {
    Directory? metadataDirectory,
  }) async {
    final directory = metadataDirectory ?? defaultMetadataDirectory();
    await directory.create(recursive: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rng = Random.secure();
    final token = base64UrlEncode(List<int>.generate(32, (_) => rng.nextInt(256)));
    final metadataFile = File('${directory.path}${Platform.pathSeparator}bridge.json');
    final bridge = BrowserBridgeServer._(server, metadataFile, token, downloads);
    try {
      await metadataFile.writeAsString(
        jsonEncode({'version': 1, 'port': server.port, 'token': token}),
        flush: true,
      );
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
    server.listen((request) => unawaited(bridge._handle(request)));
    return bridge;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    Future<void> reply(int code, Map<String, Object?> payload) async {
      response.statusCode = code;
      response.write(jsonEncode(payload));
      await response.close();
    }

    if (request.method != 'POST' || request.uri.path != '/download') {
      await reply(HttpStatus.notFound, {'ok': false, 'error': 'not_found'});
      return;
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $_token') {
      await reply(HttpStatus.unauthorized, {'ok': false, 'error': 'unauthorized'});
      return;
    }
    try {
      final chunks = <int>[];
      await for (final chunk in request) {
        if (chunks.length + chunk.length > maxRequestBytes) {
          await reply(HttpStatus.requestEntityTooLarge,
              {'ok': false, 'error': 'request_too_large'});
          return;
        }
        chunks.addAll(chunk);
      }
      final payload = jsonDecode(utf8.decode(chunks));
      if (payload is! Map<String, dynamic> || payload['url'] is! String ||
          (payload['fileName'] != null && payload['fileName'] is! String)) {
        await reply(HttpStatus.badRequest, {'ok': false, 'error': 'invalid_payload'});
        return;
      }
      final record = await _downloads.addUrl(
        payload['url'] as String,
        fileName: payload['fileName'] as String?,
      );
      await reply(HttpStatus.ok, {'ok': true, 'taskId': record.id});
    } on FormatException {
      await reply(HttpStatus.badRequest, {'ok': false, 'error': 'invalid_url'});
    } catch (_) {
      await reply(HttpStatus.internalServerError,
          {'ok': false, 'error': 'could_not_queue_download'});
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    // A second app instance must not have its newer bridge metadata deleted.
    try {
      if (await _metadataFile.exists()) {
        final data = jsonDecode(await _metadataFile.readAsString());
        if (data is Map && data['token'] == _token) await _metadataFile.delete();
      }
    } catch (_) {
      // Stale metadata is harmless; the native host reports app_not_running.
    }
  }
}
