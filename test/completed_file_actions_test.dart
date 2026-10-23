import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_record.dart';
import 'package:jahid_download_manager/integration/completed_file_actions.dart';

void main() {
  late Directory temp;
  late DownloadRecord record;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jdm-file-action-test-');
    record = DownloadRecord(
      id: 'test',
      url: 'https://example.test/file.bin',
      fileName: 'file.bin',
      savePath: '${temp.path}${Platform.pathSeparator}file.bin',
      createdAt: DateTime(2026, 1, 1),
    );
  });

  tearDown(() async => temp.delete(recursive: true));

  test('rejects queued tasks even when a similarly named file exists', () async {
    await File(record.savePath).writeAsBytes([1, 2, 3]);
    await expectLater(
        CompletedFileActions.requireCompletedFile(record), throwsStateError);
  });

  test('rejects missing or empty completed files', () async {
    record.status = DownloadStatus.completed;
    await expectLater(
        CompletedFileActions.requireCompletedFile(record),
        throwsA(isA<FileSystemException>()));
    await File(record.savePath).writeAsBytes([]);
    await expectLater(
        CompletedFileActions.requireCompletedFile(record),
        throwsA(isA<FileSystemException>()));
  });

  test('accepts an existing nonempty completed file', () async {
    record.status = DownloadStatus.completed;
    final file = File(record.savePath);
    await file.writeAsBytes([10, 20, 30]);
    expect((await CompletedFileActions.requireCompletedFile(record)).path,
        file.path);
  });
}
