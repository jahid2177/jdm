import 'dart:io';
import 'dart:math';

import 'download_record.dart';

class RangeProbe {
  const RangeProbe(this.totalBytes, this.etag, this.lastModified);

  final int totalBytes;
  final String? etag;
  final String? lastModified;

  String? get validator => etag != null && !etag!.startsWith('W/')
      ? etag
      : lastModified;
}

/// HTTP byte-range mechanics; every worker writes to its own segment file.
class SegmentedDownloader {
  static final RegExp _contentRange =
      RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

  /// A one-byte probe. If the server ignores Range, do not consume the whole
  /// response: close the separate probe client and use the legacy stream path.
  static Future<RangeProbe?> probe(Uri uri) async {
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 25);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 6;
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode != HttpStatus.partialContent ||
          !_isIdentityEncoded(response)) {
        return null;
      }
      final header = response.headers.value(HttpHeaders.contentRangeHeader);
      final match = header == null ? null : _contentRange.firstMatch(header);
      if (match == null ||
          match.group(1) != '0' ||
          match.group(2) != '0') {
        return null;
      }
      final size = int.parse(match.group(3)!);
      if (size <= 0) return null;
      return RangeProbe(
        size,
        response.headers.value(HttpHeaders.etagHeader),
        response.headers.value(HttpHeaders.lastModifiedHeader),
      );
    } finally {
      client.close(force: true);
    }
  }

  static bool _isIdentityEncoded(HttpClientResponse response) {
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    return encoding == null || encoding.toLowerCase() == 'identity';
  }

  static List<DownloadSegment> plan(int totalBytes, int connections) {
    if (totalBytes <= 0) throw ArgumentError.value(totalBytes, 'totalBytes');
    final count = min(max(connections, 1), min(totalBytes, 16));
    final chunkSize = (totalBytes / count).ceil();
    final segments = <DownloadSegment>[];
    for (var start = 0; start < totalBytes; start += chunkSize) {
      segments.add(DownloadSegment(
        index: segments.length,
        start: start,
        end: min(totalBytes - 1, start + chunkSize - 1),
      ));
    }
    return segments;
  }

  static File segmentFile(
    DownloadRecord record,
    DownloadSegment segment, {
    String? basePath,
  }) => File('${basePath ?? record.savePath}.${record.id}.seg-${segment.index}.jdm-part');

  static Future<void> syncFiles(DownloadRecord record) async {
    var total = 0;
    for (final segment in record.segments) {
      final file = segmentFile(record, segment);
      final bytes = await file.exists() ? await file.length() : 0;
      if (bytes > segment.length) {
        throw StateError('Segment ${segment.index} exceeds its byte range.');
      }
      segment.downloadedBytes = bytes;
      total += bytes;
    }
    record.downloadedBytes = total;
  }

  static Future<void> fetchAll({
    required DownloadRecord record,
    required HttpClient client,
    required bool Function() isDownloading,
    required void Function() onProgress,
  }) async {
    if (record.totalBytes == null || record.segments.isEmpty) {
      throw StateError('No segment plan to execute.');
    }
    await syncFiles(record);
    await Future.wait(record.segments.map((segment) => _fetchOne(
          record: record,
          segment: segment,
          client: client,
          isDownloading: isDownloading,
          onProgress: onProgress,
        )));
  }

  static Future<void> _fetchOne({
    required DownloadRecord record,
    required DownloadSegment segment,
    required HttpClient client,
    required bool Function() isDownloading,
    required void Function() onProgress,
  }) async {
    if (!isDownloading() || segment.complete) return;
    final file = segmentFile(record, segment);
    final start = segment.start + segment.downloadedBytes;
    final request = await client.getUrl(Uri.parse(record.url));
    request.followRedirects = true;
    request.maxRedirects = 6;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${segment.end}');
    final validator = RangeProbe(
      record.totalBytes!, record.etag, record.lastModified,
    ).validator;
    if (validator != null) request.headers.set('If-Range', validator);
    final response = await request.close();
    if (response.statusCode != HttpStatus.partialContent ||
        !_isIdentityEncoded(response)) {
      throw StateError('Server did not honor the requested byte range.');
    }
    final rangeHeader = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = rangeHeader == null ? null : _contentRange.firstMatch(rangeHeader);
    if (match == null ||
        int.parse(match.group(1)!) != start ||
        int.parse(match.group(2)!) != segment.end ||
        int.parse(match.group(3)!) != record.totalBytes) {
      throw StateError('Server returned an inconsistent Content-Range.');
    }
    final newTag = response.headers.value(HttpHeaders.etagHeader);
    if (record.etag != null && newTag != null && newTag != record.etag) {
      throw StateError('Remote file ETag changed while downloading.');
    }
    final newModified = response.headers.value(HttpHeaders.lastModifiedHeader);
    if (record.lastModified != null && newModified != null &&
        newModified != record.lastModified) {
      throw StateError('Remote file modification time changed.');
    }

    final writer = await file.open(mode: FileMode.append);
    try {
      await for (final bytes in response) {
        if (!isDownloading()) break;
        if (segment.downloadedBytes + bytes.length > segment.length) {
          throw StateError('Received bytes outside segment ${segment.index}.');
        }
        await writer.writeFrom(bytes);
        segment.downloadedBytes += bytes.length;
        record.downloadedBytes += bytes.length;
        onProgress();
      }
      await writer.flush();
    } finally {
      await writer.close();
    }
    if (isDownloading() && await file.length() != segment.length) {
      throw StateError('Incomplete segment ${segment.index}.');
    }
  }

  /// Merge only fully downloaded segments, in strict byte order.
  static Future<File> assemble(DownloadRecord record, File output) async {
    await syncFiles(record);
    if (record.segments.any((segment) => !segment.complete) ||
        record.downloadedBytes != record.totalBytes) {
      throw StateError('Cannot assemble incomplete segments.');
    }
    final sink = output.openWrite(mode: FileMode.write);
    try {
      for (final segment in record.segments) {
        await sink.addStream(segmentFile(record, segment).openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await output.length() != record.totalBytes) {
      throw StateError('Assembled file has the wrong byte length.');
    }
    return output;
  }

  static Future<void> deleteSegments(
    DownloadRecord record, {
    String? basePath,
  }) async {
    for (final segment in record.segments) {
      final file = segmentFile(record, segment, basePath: basePath);
      if (await file.exists()) await file.delete();
    }
  }
}
