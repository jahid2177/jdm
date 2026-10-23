import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../download/download_controller.dart';
import '../download/download_record.dart';
import 'download_alert_tracker.dart';
import 'completed_file_actions.dart';

/// Pure, testable detection of newly completed records. Previously completed
/// history is never replayed when the watcher attaches after app startup.
class CompletionTransitionTracker {
  CompletionTransitionTracker(Iterable<DownloadRecord> initial)
      : _seen = initial
            .where((record) => record.status == DownloadStatus.completed)
            .map((record) => record.id)
            .toSet();

  final Set<String> _seen;

  List<DownloadRecord> takeNewCompletions(Iterable<DownloadRecord> records) {
    final items = records.toList();
    final existingIds = items.map((record) => record.id).toSet();
    _seen.removeWhere((id) => !existingIds.contains(id));
    return [
      for (final record in items)
        if (record.status == DownloadStatus.completed && _seen.add(record.id))
          record,
    ];
  }
}

/// Watches transitions into Completed while the JDM process is alive.
/// Historic completed downloads are intentionally not exported in bulk when
/// a user enables auto-export for the first time.
class AndroidCompletionCoordinator {
  AndroidCompletionCoordinator(this.controller)
      : _tracker = CompletionTransitionTracker(controller.downloads),
        _alerts = DownloadAlertTracker(controller.downloads) {
    controller.addListener(_onControllerChanged);
  }

  static const MethodChannel _native = MethodChannel('com.jahidul.jdm/files');

  final DownloadController controller;
  final CompletionTransitionTracker _tracker;
  final DownloadAlertTracker _alerts;
  final Map<String, Future<String>> _activeExports = {};

  static Future<bool> requestNotificationPermission() async =>
      await _native.invokeMethod<bool>('requestCompletionNotifications') ??
      false;

  static Future<bool> supportsPublicDownloads() async =>
      await _native.invokeMethod<bool>('supportsPublicDownloads') ?? false;

  void _onControllerChanged() {
    for (final alert in _alerts.takeNewAlerts(controller.downloads)) {
      if (alert.type == DownloadAlertType.failed &&
          controller.androidCompletionNotificationsEnabled) {
        unawaited(_notifyFailed(alert.record));
      }
    }
    for (final record in _tracker.takeNewCompletions(controller.downloads)) {
      if (controller.androidCompletionNotificationsEnabled) {
        unawaited(_notifyCompleted(record));
      }
      if (controller.androidAutoExportEnabled &&
          record.androidDownloadsUri == null) {
        unawaited(export(record).then<void>((_) {}, onError: (Object error) {
          debugPrint('Automatic Downloads export failed: $error');
        }));
      }
    }
  }

  Future<void> _notifyCompleted(DownloadRecord record) async {
    try {
      await _native.invokeMethod<bool>('notifyDownloadCompleted', {
        'id': record.id,
        'fileName': record.fileName,
      });
    } catch (error) {
      debugPrint('Download completion notification failed: $error');
    }
  }

  Future<void> _notifyFailed(DownloadRecord record) async {
    try {
      await _native.invokeMethod<bool>('notifyDownloadFailed', {
        'id': record.id,
        'fileName': record.fileName,
      });
    } catch (error) {
      debugPrint('Download failure notification failed: $error');
    }
  }

  Future<String> export(DownloadRecord record, {bool force = false}) {
    final uri = record.androidDownloadsUri;
    if (!force && uri != null) {
      return Future.value(uri);
    }
    final pending = _activeExports[record.id];
    if (pending != null) return pending;
    final task = _exportAndPersist(record);
    _activeExports[record.id] = task;
    task.then<void>((_) {
      _activeExports.remove(record.id);
    }, onError: (Object _) {
      _activeExports.remove(record.id);
    });
    return task;
  }

  Future<String> _exportAndPersist(DownloadRecord record) async {
    try {
      final uri = await CompletedFileActions.exportToAndroidDownloads(record);
      await controller.recordAndroidExportResult(record.id, uri: uri);
      return uri;
    } catch (error) {
      await controller.recordAndroidExportResult(
        record.id,
        error: error.toString(),
      );
      rethrow;
    }
  }

  void dispose() => controller.removeListener(_onControllerChanged);
}
