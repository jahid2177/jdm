import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'download/download_controller.dart';
import 'download/download_history_backup.dart';
import 'download/download_record.dart';
import 'download/download_schedule_window.dart';
import 'integration/android_background_keeper.dart';
import 'integration/android_completion_coordinator.dart';
import 'integration/browser_bridge_server.dart';
import 'integration/completed_file_actions.dart';
import 'integration/clipboard_link_detector.dart';
import 'integration/download_alert_tracker.dart';
import 'integration/windows_browser_setup_dialog.dart';
import 'integration/windows_tray_controller.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await DownloadController.create();
  BrowserBridgeServer? bridge;
  if (Platform.isWindows) {
    try {
      bridge = await BrowserBridgeServer.start(controller);
    } catch (error) {
      // A failed browser bridge must never prevent normal downloads.
      debugPrint('Could not start browser bridge: $error');
    }
  }
  final tray = await WindowsTrayController.attach(controller, bridge);
  final background = Platform.isAndroid
      ? AndroidBackgroundKeeper(controller)
      : null;
  final completion = Platform.isAndroid
      ? AndroidCompletionCoordinator(controller)
      : null;
  runApp(JdmApp(
    controller: controller,
    bridge: bridge,
    tray: tray,
    background: background,
    completion: completion,
    openBrowserSetupOnLaunch:
        Platform.isWindows && args.contains('--browser-setup'),
  ));
}

class JdmApp extends StatefulWidget {
  const JdmApp({
    super.key,
    required this.controller,
    this.bridge,
    this.tray,
    this.background,
    this.completion,
    this.openBrowserSetupOnLaunch = false,
  });
  final DownloadController controller;
  final BrowserBridgeServer? bridge;
  final WindowsTrayController? tray;
  final AndroidBackgroundKeeper? background;
  final AndroidCompletionCoordinator? completion;
  final bool openBrowserSetupOnLaunch;

  @override
  State<JdmApp> createState() => _JdmAppState();
}

class _JdmAppState extends State<JdmApp> {
  ThemeMode get mode => switch (widget.controller.themePreference) {
    'dark' => ThemeMode.dark,
    'light' => ThemeMode.light,
    _ => ThemeMode.system,
  };

  Future<void> _cycleTheme() async {
    final next = switch (widget.controller.themePreference) {
      'system' => 'light',
      'light' => 'dark',
      _ => 'system',
    };
    await widget.controller.setThemePreference(next);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    // Closing the Windows window does not dispose this widget; it only hides
    // the window. The tray's explicit Exit closes the browser bridge.
    if (widget.tray == null && widget.bridge != null) {
      unawaited(widget.bridge!.close());
    }
    widget.background?.dispose();
    widget.completion?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Jahid Download Manager',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1364D6)),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF64A7FF),
            brightness: Brightness.dark,
          ),
        ),
        home: DownloadHome(
          controller: widget.controller,
          background: widget.background,
          completion: widget.completion,
          onToggleTheme: () => unawaited(_cycleTheme()),
          openBrowserSetupOnLaunch: widget.openBrowserSetupOnLaunch,
        ),
      );
}

enum DownloadFilter { all, downloading, queued, paused, completed, failed }

extension on DownloadFilter {
  String get title => switch (this) {
        DownloadFilter.all => 'All Downloads',
        DownloadFilter.downloading => 'Downloading',
        DownloadFilter.queued => 'Queued',
        DownloadFilter.paused => 'Paused',
        DownloadFilter.completed => 'Completed',
        DownloadFilter.failed => 'Failed',
      };

  IconData get icon => switch (this) {
        DownloadFilter.all => Icons.download_for_offline_outlined,
        DownloadFilter.downloading => Icons.downloading_outlined,
        DownloadFilter.queued => Icons.schedule,
        DownloadFilter.paused => Icons.pause_circle_outline,
        DownloadFilter.completed => Icons.check_circle_outline,
        DownloadFilter.failed => Icons.error_outline,
      };

  bool matches(DownloadRecord record) =>
      this == DownloadFilter.all || record.status.name == name;
}

class DownloadHome extends StatefulWidget {
  const DownloadHome({
    super.key,
    required this.controller,
    required this.onToggleTheme,
    this.background,
    this.completion,
    this.openBrowserSetupOnLaunch = false,
  });
  final DownloadController controller;
  final VoidCallback onToggleTheme;
  final AndroidBackgroundKeeper? background;
  final AndroidCompletionCoordinator? completion;
  final bool openBrowserSetupOnLaunch;

  @override
  State<DownloadHome> createState() => _DownloadHomeState();
}

class _DownloadHomeState extends State<DownloadHome>
    with WidgetsBindingObserver {
  DownloadFilter filter = DownloadFilter.all;
  DownloadCategory? categoryFilter;
  String search = '';
  final Set<String> _busyFileActions = {};
  late final DownloadAlertTracker _alertTracker;
  Timer? _clipboardTimer;
  bool _appVisible = true;
  bool _clipboardDialogOpen = false;
  String? _lastClipboardText;
  String? _pendingClipboardUrl;

  @override
  void initState() {
    super.initState();
    _alertTracker = DownloadAlertTracker(widget.controller.downloads);
    widget.controller.addListener(_onAlerts);
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      _clipboardTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (widget.controller.clipboardMonitoringEnabled) {
          unawaited(_inspectClipboard());
        }
      });
      if (widget.openBrowserSetupOnLaunch) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_browserSetup());
          }
        });
      }
    }
  }

  Future<void> _browserSetup() async {
    if (!Platform.isWindows || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => const WindowsBrowserSetupDialog(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible = state == AppLifecycleState.resumed;
    if (_appVisible && _pendingClipboardUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_showClipboardSuggestion());
        }
      });
    }
  }

  Future<void> _inspectClipboard({bool manual = false}) async {
    try {
      final text = (await Clipboard.getData('text/plain'))?.text;
      if (!mounted || text == null) {
        return;
      }
      if (!manual && text == _lastClipboardText) {
        return;
      }
      _lastClipboardText = text;
      final candidate = ClipboardLinkDetector.firstValidLink(text);
      if (candidate == null) {
        if (manual) {
          _message('No public HTTP(S) URL found on clipboard.');
        }
        return;
      }
      _pendingClipboardUrl = candidate;
      if (manual || _appVisible) {
        await _showClipboardSuggestion();
      }
    } catch (error) {
      if (manual && mounted) {
        _message('Clipboard is unavailable: $error');
      }
    }
  }

  Future<void> _showClipboardSuggestion() async {
    if (!mounted || _clipboardDialogOpen || !_appVisible ||
        _pendingClipboardUrl == null) {
      return;
    }
    final candidate = _pendingClipboardUrl!;
    _pendingClipboardUrl = null;
    _clipboardDialogOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Download link found'),
          content: SelectableText('Add this clipboard URL to your JDM queue?\n\n$candidate'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Ignore')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Add to queue')),
          ],
        ),
      );
      if (accepted == true) {
        try {
          await widget.controller.addUrl(candidate);
          if (mounted) {
            _message('Clipboard link added to queue.');
          }
        } on DuplicateDownloadException {
          if (mounted) {
            _message('This link is already in your download list.');
          }
        } catch (error) {
          if (mounted) {
            _message('Cannot add clipboard URL: $error');
          }
        }
      }
    } finally {
      _clipboardDialogOpen = false;
    }
  }

  void _onAlerts() {
    for (final alert in _alertTracker.takeNewAlerts(widget.controller.downloads)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final message = alert.type == DownloadAlertType.completed
            ? 'Download complete: ${alert.record.fileName}'
            : 'Download failed: ${alert.record.fileName}. Open Diagnostics for details.';
        _message(message);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardTimer?.cancel();
    widget.controller.removeListener(_onAlerts);
    super.dispose();
  }

  Future<void> _addDownload() async {
    final input = await showDialog<_DownloadInput>(
      context: context,
      builder: (_) => const _AddDownloadDialog(),
    );
    if (input == null) {
      return;
    }
    try {
      await widget.controller.addUrl(
        input.url,
        fileName: input.name,
        quality: input.quality,
        scheduledAt: input.scheduledAt,
        category: input.category,
        alternateUrls: input.alternateUrls,
        retryPolicy: input.retryPolicy,
        expectedSha256: input.expectedSha256,
      );
    } on DuplicateDownloadException catch (duplicate) {
      if (!mounted) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Duplicate download detected'),
          content: Text('This URL is already in JDM as '
              '"${duplicate.existing.fileName}" (${duplicate.existing.status.name}). '
              'Download another copy anyway?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Add another copy')),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      try {
        await widget.controller.addUrl(input.url, fileName: input.name,
            quality: input.quality, scheduledAt: input.scheduledAt,
            category: input.category, alternateUrls: input.alternateUrls,
            retryPolicy: input.retryPolicy,
            expectedSha256: input.expectedSha256,
            allowDuplicate: true);
      } catch (error) {
        if (mounted) {
          _message('Duplicate download could not start: $error');
        }
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download could not start: $error')),
      );
    }
  }

  Future<void> _remove(DownloadRecord record) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove download?'),
        content: Text('Remove "${record.fileName}" from the list? '
            'A partial file will be deleted. Completed files stay on disk.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await widget.controller.remove(record.id);
    }
  }

  Future<void> _handle(DownloadRecord record, String action) async {
    if (action == 'diagnostics') {
      await _diagnostics(record);
      return;
    }
    if (action == 'restart') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restart download from zero?'),
          content: Text('Delete only JDM temporary bytes for "${record.fileName}" '
              'and download it again? This is recommended after a SHA-256 '
              'mismatch. Existing completed files are not touched.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Restart from zero')),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      try {
        final restarted = await widget.controller.restartFromZero(record.id);
        if (mounted) {
          _message(restarted
            ? 'Clean download queued.'
            : 'Pause or wait for this download to stop first.');
        }
      } catch (error) {
        if (mounted) {
          _message('Could not restart from zero: $error');
        }
      }
      return;
    }
    if (action.startsWith('category:')) {
      final category = DownloadCategory.values.firstWhere(
        (value) => value.name == action.substring('category:'.length),
      );
      try {
        final moved = await widget.controller.changeCategory(record.id, category);
        if (mounted) {
          _message(moved
            ? 'Moved to ${category.folder} category.'
            : 'Pause or finish the current download before moving its folder.');
        }
      } catch (error) {
        if (mounted) {
          _message('Category move failed: $error');
        }
      }
      return;
    }
    if (action == 'open' || action == 'share' ||
        action == 'reveal' || action == 'export') {
      await _runFileAction(record, action);
      return;
    }
    if (action == 'copyUrl') {
      await Clipboard.setData(ClipboardData(text: record.url));
      if (mounted) {
        _message('Download URL copied to clipboard.');
      }
      return;
    }
    if (action == 'pause') {
      await widget.controller.pause(record.id);
    }
    if (action == 'resume') {
      await widget.controller.resume(record.id);
    }
    if (action == 'earlier') {
      await widget.controller.moveEarlier(record.id);
    }
    if (action == 'later') {
      await widget.controller.moveLater(record.id);
    }
    if (action == 'top') {
      await widget.controller.moveToFront(record.id);
    }
    if (action == 'bottom') {
      await widget.controller.moveToBack(record.id);
    }
    if (action == 'remove') {
      await _remove(record);
    }
    if (action == 'path' && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Download destination'),
          content: SelectableText(record.savePath),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _diagnostics(DownloadRecord record) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Diagnostics: ${record.fileName}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: SelectableText(
                'Status: ${record.status.name}\n'
                'Category: ${record.category.folder}\n'
                'Downloaded: ${_bytes(record.downloadedBytes)}\n'
                'Expected: ${_bytes(record.totalBytes)}\n'
                'Connections: ${record.usedConnections}\n'
                'Automatic retries: ${record.retryAttempts}\n'
                'Retry policy: ${record.retryPolicy.name} '
                '(limit ${widget.controller.retryLimitFor(record)})\n'
                'Offline checks: ${record.reconnectChecks}\n'
                'Speed: ${_bytes(record.bytesPerSecond.toInt())}/s\n'
                'ETA: ${_durationLabel(record.estimatedTimeRemaining)}\n'
                'Last progress: ${record.lastProgressAt == null ? 'Not sampled' : _whenString(record.lastProgressAt!)}\n'
                'Stalled (15 s): ${record.isStalled}\n'
                'Verifying SHA-256: ${record.isVerifying}\n'
                'SHA-256 expected: ${record.expectedSha256 ?? 'Not provided'}\n'
                'SHA-256 calculated: ${record.actualSha256 ?? 'Not calculated'}\n'
                'Interrupted recovery available: ${record.recoveryNeeded}\n'
                'Disk free (last check): ${_bytes(record.freeDiskBytes)}\n'
                'Disk needed incl. reserve: ${_bytes(record.estimatedDiskBytesNeeded)}\n'
                'Disk checked: ${record.lastDiskCheckAt == null ? 'Never' : _whenString(record.lastDiskCheckAt!)}\n'
                'Disk advisory: ${record.diskSpaceWarning ?? 'None'}\n'
                'Waiting for network: ${record.waitingForNetwork}\n'
                'Original URL: ${record.url}\n'
                'Active URL: ${record.activeUrl}\n'
                'Mirror: ${record.activeMirrorIndex}/${record.alternateUrls.length}\n'
                'Save path: ${record.savePath}\n'
                'Next attempt: ${record.retryAt == null ? 'None' : _whenString(record.retryAt!)}\n'
                'Last error: ${record.error ?? 'None'}',
              ),
            ),
          ),
          actions: [TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          )],
        ),
      );

  Future<void> _statistics() => showDialog<void>(
        context: context,
        builder: (context) {
          final all = widget.controller.downloads;
          final completed = all.where((r) => r.status == DownloadStatus.completed);
          final completedBytes = completed.fold<int>(
              0, (sum, r) => sum + (r.totalBytes ?? r.downloadedBytes));
          final waiting = all.where((r) => r.waitingForNetwork &&
              r.status == DownloadStatus.queued).length;
          return AlertDialog(
            title: const Text('Download statistics'),
            content: SizedBox(
              width: 390,
              child: SingleChildScrollView(child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total: ${all.length}  •  Completed: ${completed.length}'),
                  Text('Stored completed data: ${_bytes(completedBytes)}'),
                  Text('Active: ${widget.controller.activeCount}  •  Waiting for network: $waiting'),
                  Text('Failed: ${all.where((r) => r.status == DownloadStatus.failed).length}'),
                  Text('Interrupted and recoverable: ${widget.controller.interruptedCount}'),
                  Text('Last check flagged low disk: ${all.where((r) => r.status != DownloadStatus.completed && r.freeDiskBytes != null && r.estimatedDiskBytesNeeded != null && r.freeDiskBytes! < r.estimatedDiskBytesNeeded!).length}'),
                  Text('SHA-256 calculated: ${all.where((r) => r.actualSha256 != null).length}'),
                  Text('Expected hash verified: ${all.where((r) => r.status == DownloadStatus.completed && r.expectedSha256 != null && r.actualSha256 == r.expectedSha256).length}'),
                  const Divider(height: 28),
                  const Text('Downloads by category',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  for (final category in DownloadCategory.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text('${category.folder}: ${all.where((r) => r.category == category).length}'),
                    ),
                ],
              )),
            ),
            actions: [TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            )],
          );
        },
      );

  Future<void> _runFileAction(DownloadRecord record, String action) async {
    if (!_busyFileActions.add(record.id)) {
      return;
    }
    setState(() {});
    try {
      switch (action) {
        case 'open':
          await CompletedFileActions.open(record);
          break;
        case 'share':
          await CompletedFileActions.share(record);
          break;
        case 'reveal':
          await CompletedFileActions.revealInWindowsExplorer(record);
          break;
        case 'export':
          if (mounted) {
            _message('Exporting to Downloads/JDM…');
          }
          if (widget.completion case final AndroidCompletionCoordinator coordinator) {
            await coordinator.export(record, force: true);
          } else {
            await CompletedFileActions.exportToAndroidDownloads(record);
          }
          if (mounted) {
            _message('Saved to Downloads/JDM: ${record.fileName}');
          }
          break;
      }
    } catch (failure) {
      if (mounted) {
        _message('File action failed: $failure');
      }
    } finally {
      _busyFileActions.remove(record.id);
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _queueAction(String action) async {
    if (action == 'pauseQueue') {
      await widget.controller.setQueuePaused(true);
    } else if (action == 'resumeQueue') {
      await widget.controller.setQueuePaused(false);
    } else if (action == 'pauseAll') {
      await widget.controller.pauseAll();
    } else if (action == 'resumeAll') {
      await widget.controller.resumeAll();
    } else if (action == 'retryFailed') {
      final count = await widget.controller.retryAllFailed();
      if (mounted) {
        _message('Queued $count failed downloads for retry.');
      }
    }
  }

  Future<void> _settings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QueueSettingsDialog(
        controller: widget.controller,
        background: widget.background,
        completion: widget.completion,
      ),
    );
  }

  Future<void> _recoverInterrupted() async {
    final count = widget.controller.interruptedCount;
    if (count == 0) {
      if (mounted) {
        _message('No interrupted downloads need recovery.');
      }
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Recover interrupted downloads?'),
        content: Text('Resume $count downloads that were active when JDM '
            'last stopped unexpectedly? Deliberately paused tasks and '
            'completed files are untouched. Saved byte ranges are only '
            'reused when their server identity can be verified. '
            'If the queue is held, recovered tasks will wait.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Recover')),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final recovered = await widget.controller.recoverInterruptedDownloads();
    if (mounted) {
      _message('Queued $recovered interrupted downloads for recovery.');
    }
  }

  Future<void> _refreshDiskHealth() async {
    for (final record in widget.controller.downloads) {
      if (record.status == DownloadStatus.completed) {
        continue;
      }
      try {
        await widget.controller.inspectDiskSpace(record,
            assemblyBytes: record.segments.isNotEmpty
                ? record.totalBytes ?? 0 : 0);
      } catch (error) {
        debugPrint('Disk health check could not inspect ${record.id}: $error');
      }
    }
  }

  Future<void> _monitoring() => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Download Health Dashboard'),
          content: SizedBox(
            width: MediaQuery.sizeOf(dialogContext).width < 700
                ? MediaQuery.sizeOf(dialogContext).width - 80 : 620,
            height: MediaQuery.sizeOf(dialogContext).height < 610
                ? MediaQuery.sizeOf(dialogContext).height - 190 : 440,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final monitored = widget.controller.downloads.where((record) =>
                    record.status != DownloadStatus.completed).toList();
                final activeCount = monitored.where((r) =>
                    r.status == DownloadStatus.downloading).length;
                final stalledCount = monitored.where((r) => r.isStalled).length;
                final lowDiskCount = monitored.where((r) =>
                    r.freeDiskBytes != null && r.estimatedDiskBytesNeeded != null &&
                    r.freeDiskBytes! < r.estimatedDiskBytesNeeded!).length;
                final samples = widget.controller.speedHistory;
                final average = samples.isEmpty ? 0.0 :
                    samples.fold<double>(0, (sum, s) => sum + s.bytesPerSecond) /
                        samples.length;
                return Column(children: [
                  Align(alignment: Alignment.centerLeft,
                    child: Text('Current: ${_bytes(widget.controller.latestSpeedBytesPerSecond.toInt())}/s'
                        ' • Last minute: ${_bytes(average.toInt())}/s')),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 2, children: [
                    Chip(avatar: const Icon(Icons.downloading, size: 17),
                        label: Text('$activeCount active')),
                    Chip(avatar: const Icon(Icons.pause_circle_outline, size: 17),
                        label: Text('$stalledCount potentially stalled')),
                    Chip(avatar: const Icon(Icons.sd_storage_outlined, size: 17),
                        label: Text('$lowDiskCount low disk')),
                    Chip(avatar: const Icon(Icons.restore, size: 17),
                        label: Text('${widget.controller.interruptedCount} recoverable')),
                  ]),
                  const SizedBox(height: 12),
                  Expanded(child: monitored.isEmpty
                      ? const Center(child: Text('All downloads are completed or the list is empty.'))
                      : ListView.builder(
                          itemCount: monitored.length,
                          itemBuilder: (context, index) {
                            final record = monitored[index];
                            final health = record.recoveryNeeded
                                ? 'Interrupted — manual recovery available'
                                : record.diskSpaceWarning?.startsWith('Low disk') == true
                                    ? 'Disk space too low'
                                : record.waitingForNetwork
                                ? 'Waiting for network'
                                : record.isVerifying
                                    ? 'Verifying SHA-256 before publishing'
                                : record.isStalled
                                    ? 'No bytes received for 15+ seconds'
                                    : record.retryAt != null
                                        ? 'Waiting for retry'
                                    : record.status.name;
                            return ListTile(
                              dense: true,
                              title: Text(record.fileName,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text('$health • ${_bytes(record.downloadedBytes)}'
                                  ' / ${_bytes(record.totalBytes)}\n'
                                  '${_bytes(record.bytesPerSecond.toInt())}/s • '
                                  'ETA ${_durationLabel(record.estimatedTimeRemaining)}'
                                  ' • ${record.retryPolicy.name} retry\n'
                                  'Disk free: ${_bytes(record.freeDiskBytes)}'
                                  ' • Need: ${_bytes(record.estimatedDiskBytesNeeded)}'),
                              isThreeLine: true,
                            );
                          },
                        )),
                ]);
              },
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: _refreshDiskHealth,
              icon: const Icon(Icons.refresh),
              label: const Text('Check disk')),
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await _recoverInterrupted();
              },
              icon: const Icon(Icons.restore),
              label: const Text('Recover interrupted')),
            TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
          ],
        ),
      );

  Future<void> _historyAction(String action) async {
    if (action == 'stats') {
      await _statistics();
      return;
    }
    if (action == 'export') {
      try {
        final backup = widget.controller.exportHistoryJson();
        final bytes = Uint8List.fromList(utf8.encode(backup));
        final date = DateTime.now();
        final name = 'JDM-History-${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}.json';
        final selected = await FilePicker.platform.saveFile(
          dialogTitle: 'Export JDM history JSON',
          fileName: name,
          type: FileType.custom,
          allowedExtensions: ['json'],
          bytes: bytes,
        );
        if (selected == null) {
          return;
        }
        // The Android Storage Access Framework writes the supplied bytes.
        // On Windows, also persist to the user-selected filesystem path.
        if (Platform.isWindows) {
          await File(selected).writeAsBytes(bytes, flush: true);
        }
        if (mounted) {
          _message('History JSON exported. Keep it private: URLs may contain tokens.');
        }
      } catch (error) {
        if (mounted) {
          _message('History export failed: $error');
        }
      }
      return;
    }
    if (action != 'restore') {
      return;
    }
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Select a JDM history backup',
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        return;
      }
      final selected = picked.files.single;
      if (selected.size > DownloadHistoryBackup.maxJsonCharacters) {
        throw const FormatException('The history backup is too large.');
      }
      final bytes = selected.bytes ?? (selected.path == null
          ? null : await File(selected.path!).readAsBytes());
      if (bytes == null) {
        throw const FileSystemException('Could not read the selected JSON file.');
      }
      if (bytes.length > DownloadHistoryBackup.maxJsonCharacters) {
        throw const FormatException('The history backup is too large.');
      }
      final json = utf8.decode(bytes);
      final entries = DownloadHistoryBackup.decode(json);
      if (!mounted) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore download history?'),
          content: Text('Import ${entries.length} history entries? Existing '
              'downloads and files are preserved. Imported entries start '
              'PAUSED; this JSON contains no downloaded file bytes. '
              'You must manually resume any download you want again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Restore history')),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
      final restored = await widget.controller.restoreHistoryJson(json);
      if (mounted) {
        _message('Restored ${restored.restored} paused entries; '
            '${restored.skipped} duplicates skipped.');
      }
    } catch (error) {
      if (mounted) {
        _message('History restore failed: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded),
              SizedBox(width: 10),
              Flexible(child: Text('Jahid Download Manager')),
            ],
          ),
          actions: [
            if (Platform.isWindows)
              IconButton(
                tooltip: 'Set up Chrome and Edge browser integration',
                icon: const Icon(Icons.extension_outlined),
                onPressed: _browserSetup,
              ),
            if (Platform.isWindows)
              IconButton(
                tooltip: 'Review clipboard link (does not auto-download)',
                icon: const Icon(Icons.content_paste_search_outlined),
                onPressed: () => _inspectClipboard(manual: true),
              ),
            IconButton(
              tooltip: 'Download Health Dashboard and Recovery',
              icon: const Icon(Icons.monitor_heart_outlined),
              onPressed: _monitoring,
            ),
            PopupMenuButton<String>(
              tooltip: 'Download history backup and restore',
              icon: const Icon(Icons.history_edu_outlined),
              onSelected: _historyAction,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'export',
                    child: Text('Export history JSON')),
                PopupMenuItem(value: 'restore',
                    child: Text('Restore history JSON')),
                PopupMenuItem(value: 'stats',
                    child: Text('Download statistics')),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: 'Queue actions',
              icon: const Icon(Icons.playlist_play),
              onSelected: _queueAction,
              itemBuilder: (_) => [
                if (!widget.controller.queuePaused)
                  const PopupMenuItem(value: 'pauseQueue',
                      child: Text('Hold queued downloads'))
                else
                  const PopupMenuItem(value: 'resumeQueue',
                      child: Text('Start queued downloads')),
                const PopupMenuItem(value: 'pauseAll',
                    child: Text('Pause all downloads')),
                const PopupMenuItem(value: 'resumeAll',
                    child: Text('Resume all paused')),
                const PopupMenuItem(value: 'retryFailed',
                    child: Text('Retry all failed downloads')),
              ],
            ),
            IconButton(
              tooltip: 'Speed and queue settings',
              icon: const Icon(Icons.tune),
              onPressed: _settings,
            ),
            IconButton(
              tooltip: 'Cycle system, light and dark theme (saved)',
              icon: const Icon(Icons.brightness_6_outlined),
              onPressed: widget.onToggleTheme,
            ),
            const SizedBox(width: 8),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addDownload,
          icon: const Icon(Icons.add_link),
          label: const Text('Add URL'),
        ),
        body: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final all = widget.controller.downloads;
            final visible = all.where((record) {
              return filter.matches(record) &&
                  (categoryFilter == null || record.category == categoryFilter) &&
                  (record.fileName.toLowerCase().contains(search.toLowerCase()) ||
                      record.url.toLowerCase().contains(search.toLowerCase()));
            }).toList();
            return LayoutBuilder(
              builder: (context, constraints) {
                final isDesktop = constraints.maxWidth >= 850;
                return Row(
                  children: [
                    if (isDesktop) _sidebar(all),
                    Expanded(
                      child: Column(
                        children: [
                          _summary(all),
                          _speedGraph(),
                          if (!isDesktop) _mobileFilters(),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Row(children: [Expanded(child: TextField(
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search),
                                hintText: 'Search downloads',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                isDense: true,
                              ),
                              onChanged: (value) => setState(() => search = value),
                            )),
                            const SizedBox(width: 8),
                            SizedBox(width: isDesktop ? 170 : 120,
                              child: DropdownButtonFormField<DownloadCategory?>(
                                initialValue: categoryFilter,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem<DownloadCategory?>(
                                    value: null, child: Text('All')),
                                  ...DownloadCategory.values.map((category) =>
                                      DropdownMenuItem<DownloadCategory?>(
                                        value: category,
                                        child: Text(category.folder,
                                            overflow: TextOverflow.ellipsis),
                                      )),
                                ],
                                onChanged: (value) =>
                                    setState(() => categoryFilter = value),
                              ),
                            )]),
                          ),
                          Expanded(
                            child: visible.isEmpty
                                ? _emptyState()
                                : isDesktop
                                    ? _desktopTable(visible)
                                    : _mobileList(visible),
                          ),
                          _statusBar(all),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      );

  Widget _sidebar(List<DownloadRecord> all) => Container(
        width: 224,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 22, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('LIBRARY', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            for (final candidate in DownloadFilter.values)
              ListTile(
                leading: Icon(candidate.icon, size: 21),
                title: Text(candidate.title),
                trailing: Text('${all.where(candidate.matches).length}'),
                selected: filter == candidate,
                onTap: () => setState(() => filter = candidate),
              ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text('JDM 2.0.0 • Md Jahidul Islam',
                  style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      );

  Widget _summary(List<DownloadRecord> all) {
    final active = all.where((e) => e.status == DownloadStatus.downloading).length;
    final completed = all.where((e) => e.status == DownloadStatus.completed).length;
    final queued = all.where((e) => e.status == DownloadStatus.queued).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Expanded(child: _stat('Active', '$active', Icons.downloading, Colors.blue)),
          const SizedBox(width: 9),
          Expanded(child: _stat('Done', '$completed', Icons.check_circle, Colors.green)),
          const SizedBox(width: 9),
          Expanded(child: _stat('Queued', '$queued', Icons.schedule, Colors.orange)),
        ],
      ),
    );
  }

  Widget _speedGraph() {
    final samples = widget.controller.speedHistory;
    final maxSpeed = samples.fold<double>(0,
        (largest, sample) => sample.bytesPerSecond > largest
            ? sample.bytesPerSecond : largest);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 5),
      child: SizedBox(height: 88, child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            SizedBox(width: 114, child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Live speed', style: TextStyle(fontSize: 12)),
                Text('${_bytes(widget.controller.latestSpeedBytesPerSecond.toInt())}/s',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('Peak ${_bytes(maxSpeed.toInt())}/s',
                    style: const TextStyle(fontSize: 10)),
              ],
            )),
            const SizedBox(width: 8),
            Expanded(child: CustomPaint(
              painter: _SpeedGraphPainter(samples,
                  Theme.of(context).colorScheme.primary),
              child: const SizedBox.expand(),
            )),
          ]),
        ),
      )),
    );
  }

  Widget _stat(String label, String value, IconData icon, Color color) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                    Text(label, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _mobileFilters() => SizedBox(
        height: 52,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          scrollDirection: Axis.horizontal,
          children: [
            for (final candidate in DownloadFilter.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: ChoiceChip(
                  label: Text(candidate.title),
                  selected: filter == candidate,
                  onSelected: (_) => setState(() => filter = candidate),
                ),
              ),
          ],
        ),
      );

  Widget _emptyState() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_download_outlined, size: 64,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 14),
            const Text('No downloads here yet', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 6),
            const Text('Use Add URL to download a real HTTP or HTTPS file.'),
          ],
        ),
      );

  Widget _desktopTable(List<DownloadRecord> visible) =>
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 20,
            columns: const [
              DataColumn(label: Text('FILE')),
              DataColumn(label: Text('TYPE')),
              DataColumn(label: Text('SIZE')),
              DataColumn(label: Text('PROGRESS')),
              DataColumn(label: Text('SPEED')),
              DataColumn(label: Text('CONNECTIONS')),
              DataColumn(label: Text('STATUS')),
              DataColumn(label: Text('ACTIONS')),
            ],
            rows: [
              for (final record in visible)
                DataRow(cells: [
                  DataCell(SizedBox(
                    width: 220,
                    child: Tooltip(
                      message: record.url,
                      child: Text(record.fileName,
                          overflow: TextOverflow.ellipsis),
                    ),
                  )),
                  DataCell(Text(_kindLabel(record.kind))),
                  DataCell(Text(_bytes(record.totalBytes))),
                  DataCell(_progress(record, width: 160)),
                  DataCell(Text(record.status == DownloadStatus.downloading
                      ? '${_bytes(record.bytesPerSecond.toInt())}/s'
                      : '—')),
                  DataCell(Text('${record.usedConnections}')),
                  DataCell(_status(record)),
                  DataCell(_actions(record)),
                ]),
            ],
          ),
        ),
      );

  Widget _mobileList(List<DownloadRecord> visible) => ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final record = visible[index];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.insert_drive_file_outlined),
                    const SizedBox(width: 8),
                    Expanded(child: Text(record.fileName,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                    _actions(record),
                  ]),
                  const SizedBox(height: 5),
                  Text(_kindLabel(record.kind),
                      style: const TextStyle(fontSize: 11)),
                  const SizedBox(height: 10),
                  _progress(record, width: double.infinity),
                  const SizedBox(height: 8),
                  Row(children: [
                    _status(record),
                    const Spacer(),
                    Text('${_bytes(record.downloadedBytes)} / ${_bytes(record.totalBytes)}',
                        style: const TextStyle(fontSize: 12)),
                  ]),
                  const SizedBox(height: 5),
                  Text('${record.usedConnections} connection(s)',
                      style: const TextStyle(fontSize: 11)),
                  if (record.kind == DownloadKind.hls &&
                      record.hlsTotalSegments > 0)
                    Text('${record.hlsCompletedSegments}/${record.hlsTotalSegments} video segments',
                        style: const TextStyle(fontSize: 11)),
                  if (record.scheduledAt != null &&
                      record.status == DownloadStatus.queued)
                    Text('Scheduled: ${_whenString(record.scheduledAt!)}',
                        style: const TextStyle(fontSize: 11)),
                  if (record.retryAt != null &&
                      record.status == DownloadStatus.queued)
                    Text(record.waitingForNetwork
                        ? 'Offline: checking again ${_whenString(record.retryAt!)}'
                        : 'Auto retry ${record.retryAttempts}/${widget.controller.retryLimitFor(record)}: ${_whenString(record.retryAt!)}',
                        style: const TextStyle(fontSize: 11)),
                  if (record.status == DownloadStatus.downloading)
                    Text('${record.isVerifying ? 'Verifying SHA-256' : 'ETA: ${_durationLabel(record.estimatedTimeRemaining)}'}'
                        '${record.isStalled ? ' • No bytes received for 15+ s' : ''}',
                        style: const TextStyle(fontSize: 11)),
                  if (record.recoveryNeeded)
                    const Text('Interrupted earlier • Open Health Dashboard to recover',
                        style: TextStyle(color: Colors.orange, fontSize: 11)),
                  if (record.diskSpaceWarning != null &&
                      record.diskSpaceWarning!.startsWith('Low disk'))
                    Text(record.diskSpaceWarning!,
                        style: const TextStyle(color: Colors.red, fontSize: 11)),
                  if (record.error != null) ...[
                    const SizedBox(height: 6),
                    Text(record.error!, style: const TextStyle(color: Colors.red,
                        fontSize: 12)),
                  ],
                  if (record.androidExportError != null &&
                      record.status == DownloadStatus.completed) ...[
                    const SizedBox(height: 6),
                    Text('Downloads export: ${record.androidExportError}',
                        style: const TextStyle(color: Colors.orange,
                            fontSize: 12)),
                  ],
                  if (Platform.isAndroid &&
                      record.androidDownloadsUri != null &&
                      record.androidExportError == null) ...[
                    const SizedBox(height: 6),
                    const Text('Saved to public Downloads/JDM',
                        style: TextStyle(color: Colors.green, fontSize: 12)),
                  ],
                ],
              ),
            ),
          );
        },
      );

  Widget _progress(DownloadRecord record, {required double width}) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: record.fraction ??
                  (record.status == DownloadStatus.downloading ? null : 0),
              minHeight: 6,
              borderRadius: BorderRadius.circular(10),
            ),
            const SizedBox(height: 5),
            Text(record.kind == DownloadKind.hls && record.hlsTotalSegments > 0
                ? '${record.hlsCompletedSegments}/${record.hlsTotalSegments} segments • ${_bytes(record.downloadedBytes)}'
                : record.fraction == null
                    ? _bytes(record.downloadedBytes)
                    : '${(record.fraction! * 100).toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 11)),
          ],
        ),
      );

  Widget _status(DownloadRecord record) {
    final (label, color) = switch (record.status) {
      DownloadStatus.queued => (
        record.waitingForNetwork
            ? 'Waiting for network'
            : record.retryAt?.isAfter(DateTime.now()) == true
            ? 'Retry ${record.retryAttempts}/${widget.controller.retryLimitFor(record)}'
            : record.scheduledAt?.isAfter(DateTime.now()) == true
                ? 'Scheduled' : 'Queued',
        Colors.orange,
      ),
      DownloadStatus.downloading => (
        record.isVerifying ? 'Verifying SHA-256' : 'Downloading', Colors.blue),
      DownloadStatus.paused => (record.pausedByScheduler
          ? 'Paused by schedule' : 'Paused', Colors.grey),
      DownloadStatus.completed => ('Completed', Colors.green),
      DownloadStatus.failed => ('Failed', Colors.red),
    };
    final priority = widget.controller.queuedInPriorityOrder
        .indexWhere((queued) => queued.id == record.id);
    final displayedLabel = priority >= 0 ? '$label #${priority + 1}' : label;
    return Tooltip(
      message: record.error ?? label,
      child: Text(displayedLabel, style: TextStyle(color: color, fontWeight: FontWeight.w600,
          fontSize: 12)),
    );
  }

  Widget _actions(DownloadRecord record) => PopupMenuButton<String>(
        tooltip: _busyFileActions.contains(record.id)
            ? 'File operation in progress' : 'Download actions',
        enabled: !_busyFileActions.contains(record.id),
        onSelected: (action) => _handle(record, action),
        itemBuilder: (context) => [
          if (record.status == DownloadStatus.completed) ...[
            const PopupMenuItem(value: 'open', child: Text('Open file')),
            if (Platform.isWindows)
              const PopupMenuItem(value: 'reveal',
                  child: Text('Show in Windows Explorer')),
            if (Platform.isAndroid)
              const PopupMenuItem(value: 'export',
                  child: Text('Export to Downloads/JDM')),
            const PopupMenuItem(value: 'share', child: Text('Share file')),
            const PopupMenuDivider(),
          ],
          if (record.status == DownloadStatus.downloading)
            const PopupMenuItem(value: 'pause', child: Text('Pause')),
          if (record.status == DownloadStatus.paused && record.pausedByScheduler)
            const PopupMenuItem(value: 'pause',
                child: Text('Keep paused (cancel auto-resume)')),
          if (record.status == DownloadStatus.paused ||
              record.status == DownloadStatus.failed ||
              record.status == DownloadStatus.queued)
            const PopupMenuItem(value: 'resume', child: Text('Resume / Retry')),
          if (record.status == DownloadStatus.failed ||
              record.status == DownloadStatus.paused)
            const PopupMenuItem(value: 'restart',
                child: Text('Restart from zero (discard partial)')),
          if (record.status == DownloadStatus.queued) ...[
            const PopupMenuItem(value: 'top', child: Text('Move to top of queue')),
            const PopupMenuItem(value: 'bottom', child: Text('Move to bottom of queue')),
            const PopupMenuItem(value: 'earlier', child: Text('Move earlier in queue')),
            const PopupMenuItem(value: 'later', child: Text('Move later in queue')),
          ],
          const PopupMenuItem(value: 'path', child: Text('Show file path')),
          const PopupMenuItem(value: 'diagnostics', child: Text('Diagnostics')),
          const PopupMenuDivider(),
          if (record.status != DownloadStatus.downloading)
            for (final category in DownloadCategory.values)
              if (record.category != category)
                PopupMenuItem(value: 'category:${category.name}',
                    child: Text('Move to ${category.folder}')),
          const PopupMenuItem(value: 'copyUrl', child: Text('Copy download URL')),
          const PopupMenuItem(value: 'remove', child: Text('Remove from list')),
        ],
      );

  Widget _statusBar(List<DownloadRecord> all) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Text('${all.length} total downloads • '
            '${widget.controller.activeCount} active • '
            '${widget.controller.interruptedCount} recoverable • '
            '${widget.controller.queuePaused ? 'Queue held' : 'Queue running'} • '
            '${widget.controller.scheduleWindow.enabled ? widget.controller.withinDownloadWindow ? 'Window open' : 'Window closed' : 'Always on'} • '
            'Speed limit: ${widget.controller.speedLimitKibPerSecond == 0 ? 'Unlimited' : '${widget.controller.speedLimitKibPerSecond} KiB/s'} • '
            'Save folder: ${widget.controller.downloadDirectory.path}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11)),
      );
}

class _QueueSettingsDialog extends StatefulWidget {
  const _QueueSettingsDialog({
    required this.controller,
    this.background,
    this.completion,
  });

  final DownloadController controller;
  final AndroidBackgroundKeeper? background;
  final AndroidCompletionCoordinator? completion;

  @override
  State<_QueueSettingsDialog> createState() => _QueueSettingsDialogState();
}

class _QueueSettingsDialogState extends State<_QueueSettingsDialog> {
  late int _limit;
  late int _concurrent;
  late int _perHost;
  late int _retries;
  late bool _reconnectEnabled;
  late bool _clipboardEnabled;
  late bool _windowEnabled;
  late int _days;
  late TimeOfDay _start;
  late TimeOfDay _end;
  bool _changingBackground = false;
  bool _changingCompletionPreference = false;
  String? _backgroundFeedback;
  String? _completionFeedback;

  @override
  void initState() {
    super.initState();
    _limit = widget.controller.speedLimitKibPerSecond;
    _concurrent = widget.controller.maxSimultaneous;
    _perHost = widget.controller.maxActivePerHost;
    _retries = widget.controller.maxAutomaticRetries;
    _reconnectEnabled = widget.controller.autoResumeOnReconnectEnabled;
    _clipboardEnabled = widget.controller.clipboardMonitoringEnabled;
    final window = widget.controller.scheduleWindow;
    _windowEnabled = window.enabled;
    _days = window.weekdays;
    _start = TimeOfDay(hour: window.startMinute ~/ 60,
        minute: window.startMinute % 60);
    _end = TimeOfDay(hour: window.endMinute ~/ 60,
        minute: window.endMinute % 60);
  }

  Future<void> _pickWindowTime({required bool start}) async {
    final result = await showTimePicker(
        context: context, initialTime: start ? _start : _end);
    if (result != null && mounted) {
      setState(() {
        if (start) {
          _start = result;
        } else {
          _end = result;
        }
      });
    }
  }

  Future<void> _applyWindow() async {
    try {
      await widget.controller.setDownloadWindow(DownloadScheduleWindow(
        enabled: _windowEnabled,
        startMinute: _start.hour * 60 + _start.minute,
        endMinute: _end.hour * 60 + _end.minute,
        weekdays: _days,
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download time window saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid download window: $error')));
      }
    }
  }

  Future<void> _toggleAndroidBackground(bool enabled) async {
    final background = widget.background;
    if (background == null) {
      return;
    }
    setState(() {
      _changingBackground = true;
      _backgroundFeedback = null;
    });
    try {
      final success = await background.changeEnabled(enabled);
      if (!mounted) {
        return;
      }
      setState(() {
        _backgroundFeedback = success
            ? enabled
                ? 'Background service will run only during active downloads.'
                : 'Background service disabled.'
            : background.error ?? 'Background service was not enabled.';
      });
    } finally {
      if (mounted) {
        setState(() => _changingBackground = false);
      }
    }
  }

  Future<void> _toggleAutomaticExport(bool enabled) async {
    if (widget.completion == null) {
      return;
    }
    setState(() {
      _changingCompletionPreference = true;
      _completionFeedback = null;
    });
    try {
      if (enabled &&
          !await AndroidCompletionCoordinator.supportsPublicDownloads()) {
        _completionFeedback = 'Automatic public Downloads export requires '
            'Android 10 or newer.';
        return;
      }
      await widget.controller.setAndroidAutoExportEnabled(enabled);
      _completionFeedback = enabled
          ? 'Newly completed downloads will be copied to Downloads/JDM.'
          : 'Automatic Downloads export disabled.';
    } catch (error) {
      _completionFeedback = 'Could not update Downloads export: $error';
    } finally {
      if (mounted) {
        setState(() => _changingCompletionPreference = false);
      }
    }
  }

  Future<void> _toggleCompletionNotifications(bool enabled) async {
    if (widget.completion == null) {
      return;
    }
    setState(() {
      _changingCompletionPreference = true;
      _completionFeedback = null;
    });
    try {
      if (enabled &&
          !await AndroidCompletionCoordinator.requestNotificationPermission()) {
        _completionFeedback = 'Notifications are disabled or permission was '
            'declined in Android settings.';
        return;
      }
      await widget.controller.setAndroidCompletionNotificationsEnabled(enabled);
      _completionFeedback = enabled
          ? 'Android alerts will appear when downloads complete or fail.'
          : 'Android download alerts disabled.';
    } catch (error) {
      _completionFeedback = 'Could not update notification settings: $error';
    } finally {
      if (mounted) {
        setState(() => _changingCompletionPreference = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Speed and queue settings'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Total download speed limit'),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _limit,
                isExpanded: true,
                items: const [0, 64, 128, 256, 512, 1024, 2048, 5120, 10240]
                    .map((limit) => DropdownMenuItem(
                          value: limit,
                          child: Text(limit == 0 ? 'Unlimited' : '$limit KiB/s'),
                        ))
                    .toList(),
                onChanged: (value) async {
                  if (value == null) {
                    return;
                  }
                  setState(() => _limit = value);
                  await widget.controller.setSpeedLimitKibPerSecond(value);
                },
              ),
              const SizedBox(height: 22),
              Text('Simultaneous downloads: $_concurrent'),
              Slider(
                min: 1,
                max: 5,
                divisions: 4,
                value: _concurrent.toDouble(),
                label: '$_concurrent',
                onChanged: (value) => setState(() => _concurrent = value.round()),
                onChangeEnd: (value) =>
                    widget.controller.setMaximumActiveDownloads(value.round()),
              ),
              Text('Maximum active downloads per website: $_perHost'),
              Slider(
                min: 1,
                max: 5,
                divisions: 4,
                value: _perHost.toDouble(),
                label: '$_perHost',
                onChanged: (value) => setState(() => _perHost = value.round()),
                onChangeEnd: (value) => widget.controller
                    .setMaximumActivePerHost(value.round()),
              ),
              const Text('Queue automation avoids filling all connection '
                  'slots with downloads from the same server. Manual queue '
                  'priority is respected across available hosts.',
                  style: TextStyle(fontSize: 12)),
              const Divider(height: 32),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Recurring download window'),
                subtitle: const Text('Automatically pause transfers outside '
                    'the chosen device-local hours; resume ONLY tasks paused '
                    'by this scheduler. Requires JDM to be running.'),
                value: _windowEnabled,
                onChanged: (value) => setState(() => _windowEnabled = value),
              ),
              Wrap(spacing: 5, runSpacing: 4, children: [
                for (var index = 0; index < 7; index++)
                  FilterChip(
                    label: Text(const ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][index]),
                    selected: (_days & (1 << index)) != 0,
                    onSelected: (selected) => setState(() => _days = selected
                        ? _days | (1 << index) : _days & ~(1 << index)),
                  ),
              ]),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: () => _pickWindowTime(start: true),
                  icon: const Icon(Icons.access_time),
                  label: Text('From ${_start.format(context)}'),
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(
                  onPressed: () => _pickWindowTime(start: false),
                  icon: const Icon(Icons.access_time_filled),
                  label: Text('Until ${_end.format(context)}'),
                )),
              ]),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _applyWindow,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Apply download window'),
              ),
              const SizedBox(height: 8),
              Text(widget.controller.scheduleWindow.enabled
                  ? widget.controller.withinDownloadWindow
                      ? 'Current policy: OPEN (downloads allowed)'
                      : 'Current policy: CLOSED (auto-paused)'
                  : 'Current policy: always allowed',
                  style: const TextStyle(fontSize: 12)),
              const Divider(height: 32),
              if (Platform.isWindows)
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Suggest links copied to clipboard'),
                  subtitle: const Text('Optional local-only monitoring while '
                      'JDM is running. No link is queued without confirmation. '
                      'Never sends clipboard text to a server.'),
                  value: _clipboardEnabled,
                  onChanged: (enabled) async {
                    setState(() => _clipboardEnabled = enabled);
                    await widget.controller.setClipboardMonitoringEnabled(enabled);
                  },
                ),
              const Text('Speed limits apply to built-in HTTP and HLS '
                  'downloads, including segmented connections. External '
                  'FFmpeg transfers are not throttled.',
                  style: TextStyle(fontSize: 12)),
              const Divider(height: 32),
              const Text('Automatic retries for transient network errors'),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _retries,
                isExpanded: true,
                items: List.generate(6, (value) => DropdownMenuItem(
                  value: value,
                  child: Text(value == 0 ? 'Disabled' : '$value retries'),
                )),
                onChanged: (value) async {
                  if (value == null) {
                    return;
                  }
                  setState(() => _retries = value);
                  await widget.controller.setMaxAutomaticRetries(value);
                },
              ),
              const SizedBox(height: 6),
              const Text('Retries only network timeouts, connection errors, '
                  'HTTP 408/429 and HTTP 5xx with increasing delays. '
                  'Other errors stop; manual Resume / Retry remains available.',
                  style: TextStyle(fontSize: 12)),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto resume after reconnect'),
                subtitle: const Text('When the source cannot be reached, '
                    'JDM checks again with increasing delays (up to 60 s). '
                    'Requires the app process to remain running.'),
                value: _reconnectEnabled,
                onChanged: (enabled) async {
                  setState(() => _reconnectEnabled = enabled);
                  await widget.controller.setAutoResumeOnReconnect(enabled);
                },
              ),
              if (widget.background != null) ...[
                const SizedBox(height: 16),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep downloading in background'),
                  subtitle: const Text('Android: show a persistent download '
                      'notification and request system permissions. '
                      'Stops when no downloads are active.'),
                  value: widget.controller.androidBackgroundEnabled,
                  onChanged: _changingBackground ? null : _toggleAndroidBackground,
                ),
                if (_changingBackground) const LinearProgressIndicator(),
                if (_backgroundFeedback != null)
                  Text(_backgroundFeedback!,
                      style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                const Text('Android may stop this service due to battery '
                    'restrictions, its dataSync time limit, or force-stop. '
                    'Scheduled downloads are not guaranteed while JDM is '
                    'closed.', style: TextStyle(fontSize: 12)),
              ],
              if (widget.completion != null) ...[
                const Divider(height: 32),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-export completed downloads'),
                  subtitle: const Text('Android 10+: copy each NEW completed '
                      'file to public Downloads/JDM, keeping the original.'),
                  value: widget.controller.androidAutoExportEnabled,
                  onChanged: _changingCompletionPreference
                      ? null : _toggleAutomaticExport,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Download complete / failed alerts'),
                  subtitle: const Text('Notify when a new download finishes. '
                      'Android 13+ asks for notification permission.'),
                  value: widget.controller.androidCompletionNotificationsEnabled,
                  onChanged: _changingCompletionPreference
                      ? null : _toggleCompletionNotifications,
                ),
                if (_changingCompletionPreference)
                  const LinearProgressIndicator(),
                if (_completionFeedback != null)
                  Text(_completionFeedback!,
                      style: const TextStyle(fontSize: 12)),
                const Text('Already completed files are not automatically '
                    're-exported when this setting is enabled. '
                    'Use the item menu to export an older file.',
                    style: TextStyle(fontSize: 12)),
              ],
            ],
          )),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
}

String _kindLabel(DownloadKind kind) => switch (kind) {
      DownloadKind.file => 'File',
      DownloadKind.directVideo => 'Video',
      DownloadKind.hls => 'HLS MPEG-TS',
      DownloadKind.dash => 'DASH (MPD)',
    };

String _bytes(int? size) {
  if (size == null) {
    return 'Unknown';
  }
  const names = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var index = 0;
  while (value >= 1024 && index < names.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${names[index]}';
}

class _SpeedGraphPainter extends CustomPainter {
  const _SpeedGraphPainter(this.samples, this.color);

  final List<DownloadSpeedSample> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    final guide = Paint()
      ..color = color.withAlpha(36)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 2),
        Offset(size.width, size.height - 2), guide);
    canvas.drawLine(Offset(0, size.height / 2),
        Offset(size.width, size.height / 2), guide);
    if (samples.isEmpty) {
      return;
    }
    final peak = samples.fold<double>(1, (maximum, sample) =>
        sample.bytesPerSecond > maximum ? sample.bytesPerSecond : maximum);
    // Display the last minute of throughput, newest value on the right.
    final step = size.width / 59;
    final firstX = size.width - (samples.length - 1) * step;
    final path = Path();
    for (var index = 0; index < samples.length; index++) {
      final x = firstX + index * step;
      final y = (size.height - 4) *
          (1 - samples[index].bytesPerSecond / peak) + 2;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _SpeedGraphPainter oldDelegate) => true;
}

class _DownloadInput {
  const _DownloadInput(this.url, this.name, this.quality, this.scheduledAt,
      this.category, this.alternateUrls, this.retryPolicy, this.expectedSha256);
  final String url;
  final String name;
  final VideoQuality quality;
  final DateTime? scheduledAt;
  final DownloadCategory? category;
  final List<String> alternateUrls;
  final DownloadRetryPolicy retryPolicy;
  final String? expectedSha256;
}

String _durationLabel(Duration? duration) {
  if (duration == null) {
    return 'Unknown';
  }
  if (duration.inSeconds == 0) {
    return 'Finishing';
  }
  if (duration.inDays > 0) {
    return '${duration.inDays}d ${duration.inHours % 24}h';
  }
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes % 60}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  }
  return '${duration.inSeconds}s';
}

String _whenString(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _AddDownloadDialog extends StatefulWidget {
  const _AddDownloadDialog();

  @override
  State<_AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<_AddDownloadDialog> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _name = TextEditingController();
  final _mirrors = TextEditingController();
  final _sha256 = TextEditingController();
  VideoQuality _quality = VideoQuality.highest;
  DownloadRetryPolicy _retryPolicy = DownloadRetryPolicy.standard;
  DownloadCategory? _category;
  DateTime? _scheduledAt;

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (!mounted || day == null) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: _scheduledAt == null
          ? TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10)))
          : TimeOfDay.fromDateTime(_scheduledAt!),
    );
    if (!mounted || time == null) {
      return;
    }
    final selection = DateTime(day.year, day.month, day.day,
        time.hour, time.minute);
    if (!selection.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a future download time.')),
      );
      return;
    }
    setState(() => _scheduledAt = selection);
  }

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _mirrors.dispose();
    _sha256.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add download'),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _url,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'HTTP or HTTPS URL',
                    prefixIcon: Icon(Icons.link),
                  ),
                  keyboardType: TextInputType.url,
                  validator: (value) {
                    final uri = Uri.tryParse(value?.trim() ?? '');
                    return uri != null && {'http', 'https'}.contains(uri.scheme) &&
                            uri.host.isNotEmpty
                        ? null
                        : 'Enter a valid HTTP or HTTPS URL';
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Filename (optional)',
                    prefixIcon: Icon(Icons.drive_file_rename_outline),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<DownloadCategory?>(
                  initialValue: _category,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Download category / folder',
                    prefixIcon: Icon(Icons.folder_outlined),
                  ),
                  items: [
                    const DropdownMenuItem<DownloadCategory?>(
                      value: null, child: Text('Automatic by file type')),
                    ...DownloadCategory.values.map((category) =>
                        DropdownMenuItem<DownloadCategory?>(
                          value: category, child: Text(category.folder),
                        )),
                  ],
                  onChanged: (category) => setState(() => _category = category),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _mirrors,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Alternate URLs / Mirrors (optional)',
                    hintText: 'One direct HTTP(S) URL per line (max 5)',
                    prefixIcon: Icon(Icons.alt_route_outlined),
                  ),
                  validator: (text) {
                    final urls = (text ?? '').split(RegExp(r'[\r\n]+'))
                        .map((value) => value.trim())
                        .where((value) => value.isNotEmpty).toList();
                    if (urls.length > 5) {
                      return 'Use at most 5 mirrors';
                    }
                    if (urls.any((value) {
                      final uri = Uri.tryParse(value);
                      return uri == null || !{'http', 'https'}.contains(uri.scheme) ||
                          uri.host.isEmpty || uri.userInfo.isNotEmpty;
                    })) {
                      return 'Every mirror needs a valid HTTP(S) URL';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 6),
                const Text('JDM switches mirrors only before any data is '
                    'written, so partial files are never mixed between sources. '
                    'Mirrors are for direct files/videos, not HLS or DASH.',
                    style: TextStyle(fontSize: 11)),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _sha256,
                  decoration: const InputDecoration(
                    labelText: 'Expected SHA-256 (optional)',
                    hintText: '64 hexadecimal characters',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                  maxLines: 2,
                  minLines: 1,
                  validator: (value) {
                    final digest = value?.trim() ?? '';
                    return digest.isEmpty || RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest)
                        ? null : 'Enter a 64-character hexadecimal SHA-256';
                  },
                ),
                const SizedBox(height: 8),
                const Text('A supplied SHA-256 must match the fully downloaded '
                    'file before it can be marked Completed. A mismatch '
                    'retains temporary bytes for diagnostics.',
                    style: TextStyle(fontSize: 11)),
                const SizedBox(height: 12),
                DropdownButtonFormField<DownloadRetryPolicy>(
                  initialValue: _retryPolicy,
                  decoration: const InputDecoration(
                    labelText: 'Automatic retry policy',
                    prefixIcon: Icon(Icons.autorenew),
                  ),
                  items: const [
                    DropdownMenuItem(value: DownloadRetryPolicy.standard,
                        child: Text('Standard (global setting)')),
                    DropdownMenuItem(value: DownloadRetryPolicy.extended,
                        child: Text('Extended (up to 5 retries)')),
                    DropdownMenuItem(value: DownloadRetryPolicy.never,
                        child: Text('Never (manual retry only)')),
                  ],
                  onChanged: (policy) {
                    if (policy != null) {
                      setState(() => _retryPolicy = policy);
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<VideoQuality>(
                  initialValue: _quality,
                  decoration: const InputDecoration(
                    labelText: 'HLS video quality',
                    prefixIcon: Icon(Icons.high_quality_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: VideoQuality.highest,
                        child: Text('Highest available')),
                    DropdownMenuItem(value: VideoQuality.balanced,
                        child: Text('Balanced / middle')),
                    DropdownMenuItem(value: VideoQuality.lowest,
                        child: Text('Lowest available')),
                  ],
                  onChanged: (quality) {
                    if (quality != null) {
                      setState(() => _quality = quality);
                    }
                  },
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    onPressed: _pickSchedule,
                    icon: const Icon(Icons.schedule),
                    label: Text(_scheduledAt == null
                        ? 'Start now / choose schedule'
                        : _whenString(_scheduledAt!)),
                  )),
                  if (_scheduledAt != null)
                    IconButton(
                      tooltip: 'Clear schedule',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _scheduledAt = null),
                    ),
                ]),
                const SizedBox(height: 6),
                const Text('Schedules run while JDM is open; closing the app '
                    'does not start downloads in the background.',
                    style: TextStyle(fontSize: 11)),
              ],
            ),
          )),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.pop(context, _DownloadInput(
                  _url.text, _name.text, _quality, _scheduledAt,
                  _category,
                  _mirrors.text.split(RegExp(r'[\r\n]+'))
                      .map((value) => value.trim())
                      .where((value) => value.isNotEmpty).toList(),
                  _retryPolicy,
                  _sha256.text.trim().isEmpty ? null : _sha256.text.trim(),
                ));
              }
            },
            icon: const Icon(Icons.download),
            label: Text(_scheduledAt == null ? 'Start' : 'Schedule'),
          ),
        ],
      );
}
