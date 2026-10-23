import 'dart:convert';
import 'dart:io';

/// Optional desktop-only media remuxer. No FFmpeg binary is distributed by JDM.
/// This is deliberately not a DRM or encrypted-stream downloader.
class FfmpegMuxer {
  const FfmpegMuxer(this.executable);

  final String executable;

  static List<String> arguments(Uri source, String outputPath) {
    if (!{'http', 'https'}.contains(source.scheme) ||
        source.host.isEmpty || source.userInfo.isNotEmpty) {
      throw const FormatException('FFmpeg requires an HTTP(S) media URL.');
    }
    return [
      '-nostdin',
      '-hide_banner',
      '-loglevel', 'error',
      // Exclude file/crypto/pipe protocols for nested remote resources.
      '-protocol_whitelist', 'http,https,tcp,tls',
      '-i', source.toString(),
      '-map', '0:v:0',
      '-map', '0:a:0?',
      '-c', 'copy',
      '-movflags', '+faststart',
      '-f', 'mp4',
      '-n', outputPath,
    ];
  }

  /// Refuse manifest-declared DASH content protection. This check is not a
  /// general-purpose DRM scanner; encrypted stream protocols are also blocked.
  static Future<void> checkUnprotectedDash(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('DASH manifest HTTP ${response.statusCode}', uri: uri);
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const FormatException('DASH manifest exceeds 1 MiB.');
        }
        bytes.addAll(chunk);
      }
      final manifest = utf8.decode(bytes);
      if (!RegExp(r'<(?:\w+:)?MPD\b').hasMatch(manifest)) {
        throw const FormatException('This is not a DASH MPD manifest.');
      }
      if (RegExp(r'<(?:\w+:)?ContentProtection\b', caseSensitive: false)
          .hasMatch(manifest)) {
        throw UnsupportedError('Protected DASH media is not supported.');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> remux({
    required Uri source,
    required File output,
    required void Function(Process) onStart,
    required bool Function() isActive,
  }) async {
    // FFmpeg cannot append to an interrupted MP4. A retry starts fresh.
    if (await output.exists()) {
      await output.delete();
    }
    final process = await Process.start(
      executable,
      arguments(source, output.path),
      runInShell: false,
    );
    onStart(process);
    var errors = '';
    final stderr = process.stderr.transform(utf8.decoder).listen((chunk) {
      errors = '$errors$chunk';
      if (errors.length > 1800) {
        errors = errors.substring(errors.length - 1800);
      }
    });
    try {
      await process.stdout.drain<void>();
      final exitCode = await process.exitCode;
      if (!isActive()) {
        return;
      }
      if (exitCode != 0) {
        throw StateError('FFmpeg exited with code $exitCode: ${errors.trim()}');
      }
      if (!await output.exists() || await output.length() < 12) {
        throw StateError('FFmpeg did not produce a valid output file.');
      }
      final reader = await output.open();
      try {
        await reader.setPosition(4);
        final signature = await reader.read(4);
        if (ascii.decode(signature, allowInvalid: true) != 'ftyp') {
          throw const FormatException('FFmpeg output is not an MP4 container.');
        }
      } finally {
        await reader.close();
      }
    } finally {
      await stderr.cancel();
    }
  }
}
