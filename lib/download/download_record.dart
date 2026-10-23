enum DownloadStatus { queued, downloading, paused, completed, failed }
enum DownloadKind { file, directVideo, hls, dash }
enum VideoQuality { highest, balanced, lowest }

enum DownloadCategory { general, videos, documents, music, archives, other }

extension DownloadCategoryDetails on DownloadCategory {
  String get folder => switch (this) {
        DownloadCategory.general => 'General',
        DownloadCategory.videos => 'Videos',
        DownloadCategory.documents => 'Documents',
        DownloadCategory.music => 'Music',
        DownloadCategory.archives => 'Archives',
        DownloadCategory.other => 'Other',
      };

  static DownloadCategory infer(String fileName, DownloadKind kind) {
    if (kind != DownloadKind.file) return DownloadCategory.videos;
    final dot = fileName.lastIndexOf('.');
    final extension = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    if (['mp4', 'mkv', 'mov', 'avi', 'webm', 'm3u8', 'ts'].contains(extension)) {
      return DownloadCategory.videos;
    }
    if (['pdf', 'doc', 'docx', 'txt', 'xls', 'xlsx', 'ppt', 'pptx'].contains(extension)) {
      return DownloadCategory.documents;
    }
    if (['mp3', 'm4a', 'flac', 'wav', 'aac'].contains(extension)) {
      return DownloadCategory.music;
    }
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(extension)) {
      return DownloadCategory.archives;
    }
    return DownloadCategory.general;
  }
}

class DownloadSegment {
  DownloadSegment({
    required this.index,
    required this.start,
    required this.end,
    this.downloadedBytes = 0,
  });

  final int index;
  final int start;
  final int end;
  int downloadedBytes;

  int get length => end - start + 1;
  bool get complete => downloadedBytes == length;

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': start,
        'end': end,
        'downloadedBytes': downloadedBytes,
      };

  factory DownloadSegment.fromJson(Map<String, dynamic> json) => DownloadSegment(
        index: (json['index'] as num).toInt(),
        start: (json['start'] as num).toInt(),
        end: (json['end'] as num).toInt(),
        downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
      );
}

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
    this.usedConnections = 1,
    this.kind = DownloadKind.file,
    this.videoQuality = VideoQuality.highest,
    this.scheduledAt,
    this.hlsCompletedSegments = 0,
    this.hlsTotalSegments = 0,
    this.hlsCommittedBytes = 0,
    this.hlsFingerprint,
    this.androidDownloadsUri,
    this.androidExportError,
    this.retryAttempts = 0,
    this.retryAt,
    this.category = DownloadCategory.general,
    List<String>? alternateUrls,
    this.activeMirrorIndex = 0,
    this.waitingForNetwork = false,
    this.reconnectChecks = 0,
    List<DownloadSegment>? segments,
  }) : alternateUrls = alternateUrls ?? [], segments = segments ?? [];

  final String id;
  final String url;
  String fileName;
  String savePath;
  final DateTime createdAt;
  DownloadStatus status;
  int downloadedBytes;
  int? totalBytes;
  String? etag;
  String? lastModified;
  String? error;
  int usedConnections;
  DownloadKind kind;
  VideoQuality videoQuality;
  DateTime? scheduledAt;
  int hlsCompletedSegments;
  int hlsTotalSegments;
  int hlsCommittedBytes;
  String? hlsFingerprint;
  String? androidDownloadsUri;
  String? androidExportError;
  int retryAttempts;
  DateTime? retryAt;
  DownloadCategory category;
  final List<String> alternateUrls;
  int activeMirrorIndex;
  bool waitingForNetwork;
  int reconnectChecks;
  final List<DownloadSegment> segments;
  double bytesPerSecond = 0;

  String get activeUrl => activeMirrorIndex > 0 &&
          activeMirrorIndex <= alternateUrls.length
      ? alternateUrls[activeMirrorIndex - 1]
      : url;

  double? get fraction {
    if (kind == DownloadKind.hls && hlsTotalSegments > 0) {
      return (hlsCompletedSegments / hlsTotalSegments).clamp(0.0, 1.0).toDouble();
    }
    return totalBytes == null || totalBytes == 0
        ? null
        : (downloadedBytes / totalBytes!).clamp(0.0, 1.0).toDouble();
  }

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
        'usedConnections': usedConnections,
        'kind': kind.name,
        'videoQuality': videoQuality.name,
        'scheduledAt': scheduledAt?.toIso8601String(),
        'hlsCompletedSegments': hlsCompletedSegments,
        'hlsTotalSegments': hlsTotalSegments,
        'hlsCommittedBytes': hlsCommittedBytes,
        'hlsFingerprint': hlsFingerprint,
        'androidDownloadsUri': androidDownloadsUri,
        'androidExportError': androidExportError,
        'retryAttempts': retryAttempts,
        'retryAt': retryAt?.toIso8601String(),
        'category': category.name,
        'alternateUrls': alternateUrls,
        'activeMirrorIndex': activeMirrorIndex,
        'waitingForNetwork': waitingForNetwork,
        'reconnectChecks': reconnectChecks,
        'segments': segments.map((s) => s.toJson()).toList(),
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
        usedConnections: (json['usedConnections'] as num?)?.toInt() ?? 1,
        kind: DownloadKind.values.firstWhere(
          (kind) => kind.name == json['kind'],
          orElse: () => DownloadKind.file,
        ),
        videoQuality: VideoQuality.values.firstWhere(
          (quality) => quality.name == json['videoQuality'],
          orElse: () => VideoQuality.highest,
        ),
        scheduledAt: json['scheduledAt'] is String
            ? DateTime.tryParse(json['scheduledAt'] as String)
            : null,
        hlsCompletedSegments:
            (json['hlsCompletedSegments'] as num?)?.toInt() ?? 0,
        hlsTotalSegments: (json['hlsTotalSegments'] as num?)?.toInt() ?? 0,
        hlsCommittedBytes: (json['hlsCommittedBytes'] as num?)?.toInt() ?? 0,
        hlsFingerprint: json['hlsFingerprint'] as String?,
        androidDownloadsUri: json['androidDownloadsUri'] as String?,
        androidExportError: json['androidExportError'] as String?,
        retryAttempts: ((json['retryAttempts'] as num?)?.toInt() ?? 0)
            .clamp(0, 100).toInt(),
        retryAt: json['retryAt'] is String
            ? DateTime.tryParse(json['retryAt'] as String)
            : null,
        category: DownloadCategory.values.firstWhere(
          (value) => value.name == json['category'],
          orElse: () => DownloadCategory.general,
        ),
        alternateUrls: (json['alternateUrls'] is List)
            ? (json['alternateUrls'] as List).whereType<String>().toList()
            : <String>[],
        activeMirrorIndex: ((json['activeMirrorIndex'] as num?)?.toInt() ?? 0)
            .clamp(0, 10).toInt(),
        waitingForNetwork: json['waitingForNetwork'] == true,
        reconnectChecks: ((json['reconnectChecks'] as num?)?.toInt() ?? 0)
            .clamp(0, 100).toInt(),
        segments: (json['segments'] as List<dynamic>? ?? [])
            .map((value) => DownloadSegment.fromJson(
                Map<String, dynamic>.from(value as Map)))
            .toList(),
      );
}
