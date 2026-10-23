import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/integration/android_completion_coordinator.dart';

DownloadRecord makeRecord(String id, DownloadStatus status) => DownloadRecord(
      id: id,
      url: 'https://example.test/$id',
      fileName: '$id.bin',
      savePath: '/test/$id.bin',
      createdAt: DateTime(2026, 1, 1),
      status: status,
    );

void main() {
  test('old completions are ignored while new transitions appear once', () {
    final historic = makeRecord('old', DownloadStatus.completed);
    final pending = makeRecord('new', DownloadStatus.downloading);
    final tracker = CompletionTransitionTracker([historic, pending]);

    expect(tracker.takeNewCompletions([historic, pending]), isEmpty);
    pending.status = DownloadStatus.completed;
    expect(tracker.takeNewCompletions([historic, pending]), [pending]);
    expect(tracker.takeNewCompletions([historic, pending]), isEmpty);
  });

  test('completed tasks added after attachment are detected', () {
    final tracker = CompletionTransitionTracker([]);
    final complete = makeRecord('instant', DownloadStatus.completed);
    expect(tracker.takeNewCompletions([complete]), [complete]);
    expect(tracker.takeNewCompletions([complete]), isEmpty);
    expect(tracker.takeNewCompletions([]), isEmpty);
    expect(tracker.takeNewCompletions([complete]), [complete]);
  });
}
