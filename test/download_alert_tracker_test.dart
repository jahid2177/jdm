import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/integration/download_alert_tracker.dart';

DownloadRecord record(String id, DownloadStatus status) => DownloadRecord(
      id: id,
      url: 'https://example.test/$id',
      fileName: '$id.bin',
      savePath: '/tmp/$id.bin',
      createdAt: DateTime(2026, 10, 23),
      status: status,
    );

void main() {
  test('historical completed/failed entries never notify on attach', () {
    final done = record('done', DownloadStatus.completed);
    final failed = record('failed', DownloadStatus.failed);
    final tracker = DownloadAlertTracker([done, failed]);
    expect(tracker.takeNewAlerts([done, failed]), isEmpty);
  });

  test('completed and failed status transitions notify exactly once', () {
    final pending = record('pending', DownloadStatus.queued);
    final tracker = DownloadAlertTracker([pending]);
    pending.status = DownloadStatus.downloading;
    expect(tracker.takeNewAlerts([pending]), isEmpty);
    pending.status = DownloadStatus.failed;
    final failures = tracker.takeNewAlerts([pending]);
    expect(failures.length, 1);
    expect(failures.single.type, DownloadAlertType.failed);
    expect(tracker.takeNewAlerts([pending]), isEmpty);
    pending.status = DownloadStatus.queued;
    expect(tracker.takeNewAlerts([pending]), isEmpty);
    pending.status = DownloadStatus.completed;
    final completions = tracker.takeNewAlerts([pending]);
    expect(completions.length, 1);
    expect(completions.single.type, DownloadAlertType.completed);
  });

  test('new entries must be observed before announcing completion', () {
    final tracker = DownloadAlertTracker([]);
    final oldComplete = record('old', DownloadStatus.completed);
    expect(tracker.takeNewAlerts([oldComplete]), isEmpty);
    final newTask = record('new', DownloadStatus.queued);
    expect(tracker.takeNewAlerts([oldComplete, newTask]), isEmpty);
    newTask.status = DownloadStatus.completed;
    expect(tracker.takeNewAlerts([oldComplete, newTask]).length, 1);
  });
}
