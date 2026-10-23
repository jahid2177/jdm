import '../download/download_record.dart';

enum DownloadAlertType { completed, failed }

class DownloadAlert {
  const DownloadAlert(this.type, this.record);

  final DownloadAlertType type;
  final DownloadRecord record;
}

/// Detects status transitions without replaying old history on startup.
/// A record must have been observed before a completion/failure produces an
/// alert, so restoring a completed list cannot flood the notification area.
class DownloadAlertTracker {
  DownloadAlertTracker(Iterable<DownloadRecord> initial) {
    for (final record in initial) {
      _lastStatus[record.id] = record.status;
    }
  }

  final Map<String, DownloadStatus> _lastStatus = {};

  List<DownloadAlert> takeNewAlerts(Iterable<DownloadRecord> records) {
    final next = <String, DownloadStatus>{};
    final alerts = <DownloadAlert>[];
    for (final record in records) {
      final previous = _lastStatus[record.id];
      next[record.id] = record.status;
      if (previous == null || previous == record.status) continue;
      if (record.status == DownloadStatus.completed) {
        alerts.add(DownloadAlert(DownloadAlertType.completed, record));
      } else if (record.status == DownloadStatus.failed) {
        alerts.add(DownloadAlert(DownloadAlertType.failed, record));
      }
    }
    _lastStatus
      ..clear()
      ..addAll(next);
    return alerts;
  }
}
