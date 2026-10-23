import 'dart:convert';
import 'dart:io';

import '../download/download_record.dart';
import '../download/download_rate_limiter.dart';

class UnsupportedHlsException implements Exception {
  const UnsupportedHlsException(this.reason);
  final String reason;

  @override
  String toString() => 'HLS not supported: $reason';
}

class HlsVodPlaylist {
  const HlsVodPlaylist(this.segments, this.fingerprint);
  final List<Uri> segments;
  final String fingerprint;
}

/// Conservative downloader for finished, unencrypted MPEG-TS HLS VOD only.
/// The result is a .ts file, NOT an MP4 remux.
class HlsVodDownloader {
  static const maximumPlaylistBytes = 1024 * 1024;
  static const maximumSegments = 10000;

  static Future<HlsVodPlaylist> loadPlaylist(
    HttpClient client,
    Uri source, {
    VideoQuality quality = VideoQuality.highest,
  }) async {
    var uri = source;
    for (var depth = 0; depth < 3; depth++) {
      final document = await _fetchText(client, uri);
      final lines = document.text.split(RegExp(r'\r?\n'))
          .map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
      if (lines.isEmpty || lines.first != '#EXTM3U') {
        throw const FormatException('This URL is not an HLS playlist.');
      }
      if (lines.any((line) => line.startsWith('#EXT-X-SESSION-KEY'))) {
        throw const UnsupportedHlsException('encrypted playlists');
      }
      final master = lines.any((line) => line.startsWith('#EXT-X-STREAM-INF:'));
      if (master) {
        if (lines.any((line) => line.startsWith('#EXT-X-MEDIA:') &&
            line.contains('TYPE=AUDIO') && line.contains('URI='))) {
          throw const UnsupportedHlsException(
            'separate audio renditions require a muxer',
          );
        }
        final variants = <(int, Uri)>[];
        for (var index = 0; index < lines.length - 1; index++) {
          if (!lines[index].startsWith('#EXT-X-STREAM-INF:')) continue;
          final bandwidth = RegExp(r'(?:^|,)BANDWIDTH=(\d+)')
              .firstMatch(lines[index].substring('#EXT-X-STREAM-INF:'.length));
          final next = lines[index + 1];
          if (next.startsWith('#')) {
            throw const FormatException('Missing HLS variant URL.');
          }
          variants.add((int.tryParse(bandwidth?.group(1) ?? '') ?? 0,
              _validatedUri(document.uri.resolve(next))));
        }
        if (variants.isEmpty) throw const FormatException('No HLS video variant.');
        variants.sort((a, b) => b.$1.compareTo(a.$1));
        final index = switch (quality) {
          VideoQuality.highest => 0,
          VideoQuality.balanced => variants.length ~/ 2,
          VideoQuality.lowest => variants.length - 1,
        };
        uri = variants[index].$2;
        continue;
      }

      if (!lines.contains('#EXT-X-ENDLIST')) {
        throw const UnsupportedHlsException(
            'live/event playlist; only finished VOD is supported');
      }
      const disallowed = <String>[
        '#EXT-X-KEY:', '#EXT-X-MAP:', '#EXT-X-BYTERANGE:',
        '#EXT-X-DISCONTINUITY', '#EXT-X-PART:', '#EXT-X-GAP',
        '#EXT-X-I-FRAMES-ONLY', '#EXT-X-SKIP:',
      ];
      for (final line in lines) {
        if (disallowed.any(line.startsWith)) {
          throw UnsupportedHlsException('unsupported feature ${line.split(':').first}');
        }
      }
      final segments = <Uri>[];
      var awaitingSegment = false;
      for (final line in lines.skip(1)) {
        if (line.startsWith('#EXTINF:')) {
          awaitingSegment = true;
        } else if (!line.startsWith('#')) {
          if (!awaitingSegment) {
            throw const FormatException('Unexpected HLS segment without EXTINF.');
          }
          final segment = _validatedUri(document.uri.resolve(line));
          if (segment.path.endsWith('.m4s') || segment.path.endsWith('.mp4')) {
            throw const UnsupportedHlsException('fragmented MP4 needs a muxer');
          }
          segments.add(segment);
          awaitingSegment = false;
        }
        if (segments.length > maximumSegments) {
          throw const UnsupportedHlsException('too many video segments');
        }
      }
      if (awaitingSegment || segments.isEmpty) {
        throw const FormatException('Incomplete or empty HLS media playlist.');
      }
      final fingerprint = _stableFingerprint(
          segments.map((segment) => segment.toString()).join('\n'));
      return HlsVodPlaylist(segments, fingerprint);
    }
    throw const UnsupportedHlsException('nested master playlists');
  }

  static Uri _validatedUri(Uri value) {
    if (!{'http', 'https'}.contains(value.scheme) || value.host.isEmpty ||
        value.userInfo.isNotEmpty) {
      throw const FormatException('Invalid HLS resource URL.');
    }
    return value;
  }

  static String _stableFingerprint(String value) {
    // A stable non-cryptographic fingerprint: detects ordinary playlist
    // changes, but is not proof that remote segment bytes are immutable.
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static Future<({Uri uri, String text})> _fetchText(
      HttpClient client, Uri uri) async {
    final request = await client.getUrl(_validatedUri(uri));
    request.followRedirects = true;
    request.maxRedirects = 6;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HLS playlist HTTP ${response.statusCode}', uri: uri);
    }
    var effectiveUri = uri;
    for (final redirect in response.redirects) {
      effectiveUri = effectiveUri.resolveUri(redirect.location);
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maximumPlaylistBytes) {
        throw const UnsupportedHlsException('playlist is too large');
      }
      bytes.addAll(chunk);
    }
    return (uri: effectiveUri, text: utf8.decode(bytes));
  }

  static Future<void> download({
    required HttpClient client,
    required DownloadRecord record,
    required File partialFile,
    required bool Function() isDownloading,
    required Future<void> Function() persist,
    required void Function() onProgress,
    DownloadRateLimiter? rateLimiter,
  }) async {
    final playlist = await loadPlaylist(
      client,
      Uri.parse(record.url),
      quality: record.videoQuality,
    );
    if (!isDownloading()) return;

    final changed = record.hlsFingerprint != playlist.fingerprint ||
        record.hlsCompletedSegments > playlist.segments.length;
    if (changed || !await partialFile.exists()) {
      if (await partialFile.exists()) await partialFile.delete();
      record.hlsCompletedSegments = 0;
      record.hlsCommittedBytes = 0;
    } else {
      final currentSize = await partialFile.length();
      if (currentSize < record.hlsCommittedBytes) {
        await partialFile.delete();
        record.hlsCompletedSegments = 0;
        record.hlsCommittedBytes = 0;
      } else if (currentSize > record.hlsCommittedBytes) {
        final file = await partialFile.open(mode: FileMode.append);
        try {
          await file.truncate(record.hlsCommittedBytes);
        } finally {
          await file.close();
        }
      }
    }
    record.hlsFingerprint = playlist.fingerprint;
    record.hlsTotalSegments = playlist.segments.length;
    record.downloadedBytes = record.hlsCommittedBytes;
    record.totalBytes = null;
    record.usedConnections = 1;
    await persist();
    onProgress();

    final writer = await partialFile.open(mode: FileMode.append);
    try {
      for (var index = record.hlsCompletedSegments;
          index < playlist.segments.length; index++) {
        if (!isDownloading()) return;
        final uri = playlist.segments[index];
        final request = await client.getUrl(uri);
        request.followRedirects = true;
        request.maxRedirects = 6;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HLS segment HTTP ${response.statusCode}', uri: uri);
        }
        final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          throw const UnsupportedHlsException('compressed transport stream response');
        }
        var segmentBytes = 0;
        await for (final bytes in response) {
          if (!isDownloading()) return;
          if (rateLimiter != null) {
            await rateLimiter.acquire(bytes.length, isActive: isDownloading);
          }
          if (!isDownloading()) return;
          if (segmentBytes == 0 && bytes.isNotEmpty && bytes.first != 0x47) {
            throw const UnsupportedHlsException('segment is not MPEG transport stream');
          }
          await writer.writeFrom(bytes);
          segmentBytes += bytes.length;
          record.downloadedBytes += bytes.length;
          onProgress();
        }
        if (!isDownloading()) return;
        if (segmentBytes == 0 || segmentBytes % 188 != 0) {
          throw const UnsupportedHlsException('invalid MPEG-TS packet alignment');
        }
        await writer.flush();
        record.hlsCompletedSegments = index + 1;
        record.hlsCommittedBytes = record.downloadedBytes;
        await persist();
        onProgress();
      }
    } finally {
      await writer.close();
    }
  }
}
