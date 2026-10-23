import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jahid_download_manager/native_protocol.dart';

/// Windows Native Messaging executable; stdout MUST contain framed JSON only.
Future<void> main(List<String> arguments) async {
  try {
    final header = <int>[];
    for (var i = 0; i < 4; i++) {
      final byte = stdin.readByteSync();
      if (byte < 0) {
        return;
      }
      header.add(byte);
    }
    final length = ByteData.sublistView(Uint8List.fromList(header))
        .getUint32(0, Endian.host);
    if (length > maximumNativeMessageBytes) {
      await _respond({'ok': false, 'error': 'request_too_large'});
      return;
    }
    final message = List<int>.from(header);
    for (var i = 0; i < length; i++) {
      final byte = stdin.readByteSync();
      if (byte < 0) {
        throw NativeProtocolException('truncated_message');
      }
      message.add(byte);
    }
    final payload = validateDownloadMessage(decodeNativeFrame(message));
    await _respond(await _forwardToJdm(payload));
  } on NativeProtocolException catch (error) {
    await _respond({'ok': false, 'error': error.message});
  } on FormatException {
    await _respond({'ok': false, 'error': 'invalid_json'});
  } catch (error) {
    stderr.writeln('JDM native host error: $error');
    await _respond({'ok': false, 'error': 'native_host_error'});
  }
}

Future<void> _respond(Map<String, Object?> value) async {
  stdout.add(encodeNativeResponse(value));
  await stdout.flush();
}

Future<Map<String, Object?>> _forwardToJdm(Map<String, String> payload) async {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    return {'ok': false, 'error': 'windows_appdata_unavailable'};
  }
  final configFile = File('$appData${Platform.pathSeparator}'
      'JahidDownloadManager${Platform.pathSeparator}bridge.json');
  if (!await configFile.exists()) {
    return {'ok': false, 'error': 'jdm_not_running'};
  }
  try {
    final config = jsonDecode(await configFile.readAsString());
    if (config is! Map || config['version'] != 1 ||
        config['port'] is! int || config['port'] < 1 || config['port'] > 65535 ||
        config['token'] is! String || (config['token'] as String).length < 32) {
      return {'ok': false, 'error': 'invalid_bridge_configuration'};
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${config['port']}/download'));
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer ${config['token']}');
      request.add(utf8.encode(jsonEncode(payload)));
      final response = await request.close().timeout(const Duration(seconds: 8));
      final body = await utf8.decoder.bind(response).join()
          .timeout(const Duration(seconds: 8));
      final value = jsonDecode(body);
      if (response.statusCode == HttpStatus.ok && value is Map &&
          value['ok'] == true) {
        return {'ok': true, 'taskId': '${value['taskId']}'};
      }
      return {'ok': false, 'error': value is Map
          ? '${value['error'] ?? 'bridge_rejected'}' : 'bridge_rejected'};
    } finally {
      client.close(force: true);
    }
  } on SocketException {
    return {'ok': false, 'error': 'jdm_not_running'};
  } on TimeoutException {
    return {'ok': false, 'error': 'jdm_not_responding'};
  } catch (error) {
    stderr.writeln('JDM bridge call failed: $error');
    return {'ok': false, 'error': 'bridge_connection_failed'};
  }
}
