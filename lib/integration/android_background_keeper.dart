import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';

import '../download/download_controller.dart';
import 'background_download_policy.dart';

/// Keeps JDM's existing download isolate alive with a visible Android
/// dataSync foreground notification while there are active transfers.
/// It does not restart downloads after a force-stop or process death.
class AndroidBackgroundKeeper extends ChangeNotifier {
  AndroidBackgroundKeeper(this.controller) {
    controller.addListener(_onControllerChanged);
    if (controller.androidBackgroundEnabled) {
      unawaited(_reconcile());
    }
  }

  final DownloadController controller;
  bool _initialized = false;
  bool _working = false;
  Future<void>? _inFlight;
  String? error;

  bool get isWorking => _working;
  bool get isRunning => Platform.isAndroid &&
      FlutterBackground.isBackgroundExecutionEnabled;

  void _onControllerChanged() {
    if (Platform.isAndroid) {
      unawaited(_reconcile());
    }
  }

  Future<bool> changeEnabled(bool enabled) async {
    if (!Platform.isAndroid) {
      return false;
    }
    error = null;
    _working = true;
    notifyListeners();
    try {
      // Request battery/foreground permissions only after the user opts in.
      if (enabled) {
        await _initializeService();
      }
      await controller.setAndroidBackgroundEnabled(enabled);
      await _reconcile();
      return error == null;
    } catch (failure) {
      error = 'Could not enable background downloads: $failure';
      await controller.setAndroidBackgroundEnabled(false);
      debugPrint(error);
      return false;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> _initializeService() async {
    if (_initialized) {
      return;
    }
    final granted = await FlutterBackground.initialize(
      androidConfig: const FlutterBackgroundAndroidConfig(
        notificationTitle: 'Jahid Download Manager',
        notificationText: 'Downloads are running in the background',
        notificationImportance: AndroidNotificationImportance.normal,
        enableWifiLock: true,
      ),
    );
    if (!granted) {
      throw StateError('Required Android background permissions were declined');
    }
    _initialized = true;
  }

  Future<void> _reconcile() {
    if (!Platform.isAndroid) {
      return Future.value();
    }
    final existing = _inFlight;
    if (existing != null) {
      return existing;
    }
    final operation = _applyDesiredState();
    _inFlight = operation;
    return operation.whenComplete(() {
      _inFlight = null;
      // State may have changed while the asynchronous platform call was in
      // flight. Run once more, not on every progress update.
      if (error == null && shouldKeepAndroidDownloadService(
            optedIn: controller.androidBackgroundEnabled,
            activeTransfers: controller.activeCount,
          ) != isRunning) {
        unawaited(_reconcile());
      }
    });
  }

  Future<void> _applyDesiredState() async {
    final shouldRun = shouldKeepAndroidDownloadService(
      optedIn: controller.androidBackgroundEnabled,
      activeTransfers: controller.activeCount,
    );
    if (shouldRun == isRunning) {
      return;
    }
    try {
      if (shouldRun) {
        await _initializeService();
        final started = await FlutterBackground.enableBackgroundExecution();
        if (!started) {
          throw StateError('Android refused the foreground service');
        }
      } else if (_initialized) {
        final stopped = await FlutterBackground.disableBackgroundExecution();
        if (!stopped && isRunning) {
          throw StateError('Android did not stop the foreground service');
        }
      }
      error = null;
      notifyListeners();
    } catch (failure) {
      error = 'Android foreground service error: $failure';
      debugPrint(error);
      if (shouldRun) {
        // Avoid repeated permission requests and background-start failures.
        await controller.setAndroidBackgroundEnabled(false);
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }
}
