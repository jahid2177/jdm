enum DownloadStatus { queued, downloading, paused, completed, failed }

class DownloadRecord {
  DownloadRecord({
    required this.id,
    required this.url,
    required this.fileName,
    required this.savePath,
    required this.createdAt,
    this.status = DownloadStatus.queued,
    this.downloadedBytes = 0,
    this.totalBytes,
    this.etag,
    this.lastModified,
    this.error,
  });

  final String id;
  final String url;
  final String fileName;
  String savePath;
  final DateTime createdAt;
  DownloadStatus status;
  int downloadedBytes;
  int? totalBytes;
  String? etag;
  String? lastModified;
  String? error;
  double bytesPerSecond = 0;

  double? get fraction => totalBytes == null || totalBytes == 0
      ? null
      : (downloadedBytes / totalBytes!).clamp(0.0, 1.0).toDouble();

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'fileName': fileName,
        'savePath': savePath,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'etag': etag,
        'lastModified': lastModified,
        'error': error,
      };

  factory DownloadRecord.fromJson(Map<String, dynamic> json) => DownloadRecord(
        id: json['id'] as String,
        url: json['url'] as String,
        fileName: json['fileName'] as String,
        savePath: json['savePath'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        status: DownloadStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => DownloadStatus.paused,
        ),
        downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt(),
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        error: json['error'] as String?,
      );
}
