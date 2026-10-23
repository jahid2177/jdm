import 'dart:convert';

import 'download_record.dart';

/// History-only backups: no downloaded bytes, local paths, credentials, or
/// active writers are restored. Source URLs can still contain bearer tokens;
/// the user should treat an exported backup as private data.
class DownloadHistoryBackup {
  static const format = 'jahid-download-manager-history';
  static const version = 1;
  static const maxEntries = 10000;
  static const maxJsonCharacters = 8 * 1024 * 1024;

  static String encode(Iterable<DownloadRecord> records) {
    final entries = records.take(maxEntries + 1).toList();
    if (entries.length > maxEntries) {
      throw const FormatException('The backup has too many downloads.');
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'version': version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'notice': 'History metadata only. Downloaded file bytes are not included.',
      'downloads': [
        for (final record in entries)
          {
            'url': record.url,
            'fileName': record.fileName,
            'createdAt': record.createdAt.toUtc().toIso8601String(),
            'originalStatus': record.status.name,
            'kind': record.kind.name,
            'category': record.category.name,
            'quality': record.videoQuality.name,
            'totalBytes': record.totalBytes,
          },
      ],
    });
  }

  static List<HistoryEntry> decode(String source) {
    if (source.length > maxJsonCharacters) {
      throw const FormatException('The backup file is too large.');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['format'] != format ||
        decoded['version'] != version || decoded['downloads'] is! List) {
      throw const FormatException('Unsupported JDM history backup format.');
    }
    final raw = decoded['downloads'] as List;
    if (raw.length > maxEntries) {
      throw const FormatException('The backup has too many downloads.');
    }
    final entries = <HistoryEntry>[];
    for (final item in raw) {
      if (item is! Map || item['url'] is! String ||
          item['fileName'] is! String || item['createdAt'] is! String) {
        throw const FormatException('The backup contains a malformed entry.');
      }
      final url = item['url'] as String;
      final uri = Uri.tryParse(url);
      if (uri == null || !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const FormatException('A backup entry contains an invalid URL.');
      }
      final date = DateTime.tryParse(item['createdAt'] as String);
      if (date == null || (item['fileName'] as String).length > 1024) {
        throw const FormatException('A backup entry has invalid metadata.');
      }
      final length = item['totalBytes'];
      if (length != null && (length is! int || length < 0)) {
        throw const FormatException('A backup entry has an invalid size.');
      }
      final kind = DownloadKind.values.firstWhere(
        (value) => value.name == item['kind'],
        orElse: () => DownloadKind.file,
      );
      entries.add(HistoryEntry(
        url: uri.toString(),
        fileName: item['fileName'] as String,
        createdAt: date,
        totalBytes: length as int?,
        kind: kind,
        quality: VideoQuality.values.firstWhere(
          (value) => value.name == item['quality'],
          orElse: () => VideoQuality.highest,
        ),
        category: DownloadCategory.values.firstWhere(
          (value) => value.name == item['category'],
          orElse: () => DownloadCategoryDetails.infer(
              item['fileName'] as String, kind),
        ),
      ));
    }
    return entries;
  }
}

class HistoryEntry {
  const HistoryEntry({
    required this.url,
    required this.fileName,
    required this.createdAt,
    required this.totalBytes,
    required this.kind,
    required this.quality,
    required this.category,
  });

  final String url;
  final String fileName;
  final DateTime createdAt;
  final int? totalBytes;
  final DownloadKind kind;
  final VideoQuality quality;
  final DownloadCategory category;
}

class HistoryRestoreResult {
  const HistoryRestoreResult(this.restored, this.skipped);

  final int restored;
  final int skipped;
}
