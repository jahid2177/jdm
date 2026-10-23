import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../download/download_record.dart';

/// OS integrations for completed, accessible files only. The original JDM
/// download is never moved or deleted by an export/share operation.
class CompletedFileActions {
  static const MethodChannel _androidFiles =
      MethodChannel('com.jahidul.jdm/files');

  static Future<File> requireCompletedFile(DownloadRecord record) async {
    if (record.status != DownloadStatus.completed) {
      throw StateError('Only completed downloads can be opened or exported.');
    }
    final file = File(record.savePath);
    if (!await file.exists()) {
      throw FileSystemException('Downloaded file not found', record.savePath);
    }
    if (await file.length() == 0) {
      throw FileSystemException('Downloaded file is empty', record.savePath);
    }
    return file;
  }

  static Future<void> open(DownloadRecord record) async {
    final file = await _fileAvailableToOs(record);
    final opened = await OpenFilex.open(file.path);
    if (opened.type != ResultType.done) {
      throw StateError(opened.message);
    }
  }

  static Future<void> share(DownloadRecord record) async {
    final file = await _fileAvailableToOs(record);
    final result = await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], title: record.fileName),
    );
    if (result.status == ShareResultStatus.unavailable) {
      throw StateError('This device cannot share the selected file.');
    }
  }

  // Before v0.8 Android saved into app_flutter/, which is outside the
  // FileProvider's narrowly scoped files/cache roots. Keep old download paths
  // intact and copy only when a legacy file is explicitly opened or shared.
  // File.copy streams to disk; it does not load an entire movie into RAM.
  static Future<File> _fileAvailableToOs(DownloadRecord record) async {
    final file = await requireCompletedFile(record);
    if (!Platform.isAndroid) {
      return file;
    }

    final appSupport = await getApplicationSupportDirectory();
    final source = await file.resolveSymbolicLinks();
    final allowed = await appSupport.resolveSymbolicLinks();
    if (source.startsWith('$allowed${Platform.pathSeparator}')) {
      return file;
    }

    final cache = await getTemporaryDirectory();
    final staging = await Directory(
      '${cache.path}${Platform.pathSeparator}jdm_legacy_file_actions',
    ).create(recursive: true);
    final session = await staging.createTemp('file_');
    final safeName = record.fileName.replaceAll(RegExp(r'[/\\]'), '_');
    return file.copy('${session.path}${Platform.pathSeparator}$safeName');
  }

  static Future<String> exportToAndroidDownloads(DownloadRecord record) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Public Downloads export is Android-only.');
    }
    final file = await requireCompletedFile(record);
    final contentUri = await _androidFiles.invokeMethod<String>(
      'exportToDownloads',
      {'sourcePath': file.path, 'fileName': record.fileName},
    );
    if (contentUri == null || !contentUri.startsWith('content://')) {
      throw StateError('Android did not return a saved download URI.');
    }
    return contentUri;
  }

  static Future<void> revealInWindowsExplorer(DownloadRecord record) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Show in Explorer is Windows-only.');
    }
    final file = await requireCompletedFile(record);
    await Process.start(
      'explorer.exe',
      ['/select,', file.path],
      mode: ProcessStartMode.detached,
    );
  }
}
