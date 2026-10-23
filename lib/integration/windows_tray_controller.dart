import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../download/download_controller.dart';
import 'browser_bridge_server.dart';
import 'download_alert_tracker.dart';

/// The running Flutter process, downloads and browser bridge stay alive when
/// the user closes the main window. Explicit Exit shuts them down cleanly.
class WindowsTrayController with TrayListener, WindowListener {
  WindowsTrayController._(this.controller, this.bridge)
      : _alerts = DownloadAlertTracker(controller.downloads);

  final DownloadController controller;
  final BrowserBridgeServer? bridge;
  final DownloadAlertTracker _alerts;
  bool _exiting = false;

  static Future<WindowsTrayController?> attach(
    DownloadController controller,
    BrowserBridgeServer? bridge,
  ) async {
    if (!Platform.isWindows) {
      return null;
    }
    final instance = WindowsTrayController._(controller, bridge);
    try {
      await windowManager.ensureInitialized();
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Jahid Download Manager');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Open JDM'),
        MenuItem.separator(),
        MenuItem(key: 'pause', label: 'Pause all downloads'),
        MenuItem(key: 'resume', label: 'Resume all paused'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit JDM'),
      ]));
      trayManager.addListener(instance);
      windowManager.addListener(instance);
      controller.addListener(instance._onDownloadsChanged);
      // Only intercept Close after the tray can restore the application.
      await windowManager.setPreventClose(true);
      return instance;
    } catch (failure) {
      debugPrint('System tray unavailable; normal window close remains: $failure');
      trayManager.removeListener(instance);
      windowManager.removeListener(instance);
      controller.removeListener(instance._onDownloadsChanged);
      try {
        await windowManager.setPreventClose(false);
        await trayManager.destroy();
      } catch (_) {}
      return null;
    }
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void _onDownloadsChanged() {
    for (final alert in _alerts.takeNewAlerts(controller.downloads)) {
      final label = alert.type == DownloadAlertType.completed
          ? 'Completed' : 'Failed';
      final file = alert.record.fileName;
      // A hover tooltip is supported without a native toast dependency.
      // Windows also displays an in-app alert while the window is visible.
      final caption = 'JDM • $label: ${file.length > 34 ? '${file.substring(0, 34)}…' : file}';
      unawaited(trayManager.setToolTip(caption).catchError((Object error) {
        debugPrint('Could not update JDM tray tooltip: $error');
      }));
    }
  }

  @override
  void onWindowClose() {
    if (!_exiting) {
      unawaited(windowManager.hide());
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(showWindow());
        break;
      case 'pause':
        unawaited(controller.pauseAll());
        break;
      case 'resume':
        unawaited(controller.resumeAll());
        break;
      case 'exit':
        unawaited(exitApplication());
        break;
    }
  }

  Future<void> exitApplication() async {
    if (_exiting) {
      return;
    }
    _exiting = true;
    try {
      await controller.pauseAll();
      await controller.waitForIdle();
      if (bridge != null) {
        await bridge!.close();
      }
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      controller.removeListener(_onDownloadsChanged);
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (failure) {
      debugPrint('Could not close JDM safely: $failure');
      _exiting = false;
      await showWindow();
    }
  }
}
