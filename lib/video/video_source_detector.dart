import '../download/download_record.dart';

/// Classifies links and responses without treating arbitrary page HTML as video.
class VideoSourceDetector {
  static DownloadKind detect(Uri uri, {String? mimeType}) {
    final mediaType = mimeType?.split(';').first.trim().toLowerCase();
    if (mediaType == 'application/vnd.apple.mpegurl' ||
        mediaType == 'application/x-mpegurl') {
      return DownloadKind.hls;
    }
    if (mediaType == 'application/dash+xml') {
      return DownloadKind.dash;
    }
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m3u8')) {
      return DownloadKind.hls;
    }
    if (path.endsWith('.mpd')) {
      return DownloadKind.dash;
    }
    if (mediaType != null && mediaType.startsWith('video/')) {
      return DownloadKind.directVideo;
    }
    for (final extension in ['.mp4', '.m4v', '.mov', '.mkv', '.webm', '.avi', '.ts']) {
      if (path.endsWith(extension)) {
        return DownloadKind.directVideo;
      }
    }
    return DownloadKind.file;
  }

  /// MPEG-TS output must not be presented as a playable MP4 container.
  static String transportStreamName(String requestedName) {
    final lastDot = requestedName.lastIndexOf('.');
    final stem = lastDot > 0 ? requestedName.substring(0, lastDot) : requestedName;
    return '${stem.isEmpty ? 'video' : stem}.ts';
  }
}
