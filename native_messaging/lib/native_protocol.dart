import 'dart:convert';
import 'dart:typed_data';

const nativeHostName = 'com.jahidul.jdm';
const maximumNativeMessageBytes = 64 * 1024;

class NativeProtocolException implements Exception {
  NativeProtocolException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Validates the one-message IPC contract. This never accepts executable code.
Map<String, String> validateDownloadMessage(Object? value) {
  if (value is! Map<String, dynamic> || value['action'] != 'add_download') {
    throw NativeProtocolException('unsupported_action');
  }
  final url = value['url'];
  final fileName = value['fileName'];
  if (url is! String || url.length > 8192 || url.trim().isEmpty ||
      fileName != null && (fileName is! String || fileName.length > 255)) {
    throw NativeProtocolException('invalid_request');
  }
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw NativeProtocolException('invalid_url');
  }
  return {
    'url': uri.toString(),
    if (fileName is String && fileName.trim().isNotEmpty) 'fileName': fileName,
  };
}

/// Native Messaging frames are 32-bit, native-endian length + UTF-8 JSON.
Uint8List encodeNativeResponse(Map<String, Object?> payload) {
  final json = utf8.encode(jsonEncode(payload));
  if (json.length > maximumNativeMessageBytes) {
    throw NativeProtocolException('response_too_large');
  }
  final bytes = Uint8List(4 + json.length);
  ByteData.sublistView(bytes).setUint32(0, json.length, Endian.host);
  bytes.setRange(4, bytes.length, json);
  return bytes;
}

Map<String, dynamic> decodeNativeFrame(List<int> bytes) {
  if (bytes.length < 4) throw NativeProtocolException('short_header');
  final header = ByteData.sublistView(Uint8List.fromList(bytes), 0, 4);
  final length = header.getUint32(0, Endian.host);
  if (length > maximumNativeMessageBytes || bytes.length != length + 4) {
    throw NativeProtocolException('invalid_frame_size');
  }
  final value = jsonDecode(utf8.decode(bytes.sublist(4)));
  if (value is! Map<String, dynamic>) {
    throw NativeProtocolException('invalid_json_object');
  }
  return value;
}
