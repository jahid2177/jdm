import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'download/download_controller.dart';
import 'download/download_record.dart';
import 'integration/android_background_keeper.dart';
import 'integration/browser_bridge_server.dart';
import 'integration/completed_file_actions.dart';
import 'integration/windows_tray_controller.dart';

Future<void> main() async {
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
  runApp(JdmApp(
    controller: controller,
    bridge: bridge,
    tray: tray,
    background: background,
  ));
}

class JdmApp extends StatefulWidget {
  const JdmApp({
    super.key,
    required this.controller,
    this.bridge,
    this.tray,
    this.background,
  });
  final DownloadController controller;
  final BrowserBridgeServer? bridge;
  final WindowsTrayController? tray;
  final AndroidBackgroundKeeper? background;

  @override
  State<JdmApp> createState() => _JdmAppState();
}

class _JdmAppState extends State<JdmApp> {
  ThemeMode mode = ThemeMode.system;

  @override
  void dispose() {
    // Closing the Windows window does not dispose this widget; it only hides
    // the window. The tray's explicit Exit closes the browser bridge.
    if (widget.tray == null && widget.bridge != null) {
      unawaited(widget.bridge!.close());
    }
    widget.background?.dispose();
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
          onToggleTheme: () => setState(() {
            mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
          }),
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
  });
  final DownloadController controller;
  final VoidCallback onToggleTheme;
  final AndroidBackgroundKeeper? background;

  @override
  State<DownloadHome> createState() => _DownloadHomeState();
}

class _DownloadHomeState extends State<DownloadHome> {
  DownloadFilter filter = DownloadFilter.all;
  String search = '';
  final Set<String> _busyFileActions = {};

  Future<void> _addDownload() async {
    final input = await showDialog<_DownloadInput>(
      context: context,
      builder: (_) => const _AddDownloadDialog(),
    );
    if (input == null) return;
    try {
      await widget.controller.addUrl(
        input.url,
        fileName: input.name,
        quality: input.quality,
        scheduledAt: input.scheduledAt,
      );
    } catch (error) {
      if (!mounted) return;
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
    if (accepted == true) await widget.controller.remove(record.id);
  }

  Future<void> _handle(DownloadRecord record, String action) async {
    if (action == 'open' || action == 'share' ||
        action == 'reveal' || action == 'export') {
      await _runFileAction(record, action);
      return;
    }
    if (action == 'copyUrl') {
      await Clipboard.setData(ClipboardData(text: record.url));
      if (mounted) _message('Download URL copied to clipboard.');
      return;
    }
    if (action == 'pause') await widget.controller.pause(record.id);
    if (action == 'resume') await widget.controller.resume(record.id);
    if (action == 'earlier') await widget.controller.moveEarlier(record.id);
    if (action == 'later') await widget.controller.moveLater(record.id);
    if (action == 'remove') await _remove(record);
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

  Future<void> _runFileAction(DownloadRecord record, String action) async {
    if (!_busyFileActions.add(record.id)) return;
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
          if (mounted) _message('Exporting to Downloads/JDM…');
          await CompletedFileActions.exportToAndroidDownloads(record);
          if (mounted) _message('Saved to Downloads/JDM: ${record.fileName}');
          break;
      }
    } catch (failure) {
      if (mounted) _message('File action failed: $failure');
    } finally {
      _busyFileActions.remove(record.id);
      if (mounted) setState(() {});
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
    }
  }

  Future<void> _settings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _QueueSettingsDialog(
        controller: widget.controller,
        background: widget.background,
      ),
    );
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
              ],
            ),
            IconButton(
              tooltip: 'Speed and queue settings',
              icon: const Icon(Icons.tune),
              onPressed: _settings,
            ),
            IconButton(
              tooltip: 'Change theme',
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
                          if (!isDesktop) _mobileFilters(),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: TextField(
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search),
                                hintText: 'Search downloads',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                isDense: true,
                              ),
                              onChanged: (value) => setState(() => search = value),
                            ),
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
              child: Text('JDM 0.8.0 • Md Jahidul Islam',
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
                  if (record.error != null) ...[
                    const SizedBox(height: 6),
                    Text(record.error!, style: const TextStyle(color: Colors.red,
                        fontSize: 12)),
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
        record.scheduledAt?.isAfter(DateTime.now()) == true
            ? 'Scheduled' : 'Queued',
        Colors.orange,
      ),
      DownloadStatus.downloading => ('Downloading', Colors.blue),
      DownloadStatus.paused => ('Paused', Colors.grey),
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
          if (record.status == DownloadStatus.paused ||
              record.status == DownloadStatus.failed ||
              record.status == DownloadStatus.queued)
            const PopupMenuItem(value: 'resume', child: Text('Resume / Retry')),
          if (record.status == DownloadStatus.queued) ...[
            const PopupMenuItem(value: 'earlier', child: Text('Move earlier in queue')),
            const PopupMenuItem(value: 'later', child: Text('Move later in queue')),
          ],
          const PopupMenuItem(value: 'path', child: Text('Show file path')),
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
            '${widget.controller.queuePaused ? 'Queue held' : 'Queue running'} • '
            'Speed limit: ${widget.controller.speedLimitKibPerSecond == 0 ? 'Unlimited' : '${widget.controller.speedLimitKibPerSecond} KiB/s'} • '
            'Save folder: ${widget.controller.downloadDirectory.path}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11)),
      );
}

class _QueueSettingsDialog extends StatefulWidget {
  const _QueueSettingsDialog({required this.controller, this.background});

  final DownloadController controller;
  final AndroidBackgroundKeeper? background;

  @override
  State<_QueueSettingsDialog> createState() => _QueueSettingsDialogState();
}

class _QueueSettingsDialogState extends State<_QueueSettingsDialog> {
  late int _limit;
  late int _concurrent;
  bool _changingBackground = false;
  String? _backgroundFeedback;

  @override
  void initState() {
    super.initState();
    _limit = widget.controller.speedLimitKibPerSecond;
    _concurrent = widget.controller.maxSimultaneous;
  }

  Future<void> _toggleAndroidBackground(bool enabled) async {
    final background = widget.background;
    if (background == null) return;
    setState(() {
      _changingBackground = true;
      _backgroundFeedback = null;
    });
    try {
      final success = await background.changeEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _backgroundFeedback = success
            ? enabled
                ? 'Background service will run only during active downloads.'
                : 'Background service disabled.'
            : background.error ?? 'Background service was not enabled.';
      });
    } finally {
      if (mounted) setState(() => _changingBackground = false);
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
                  if (value == null) return;
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
              const Text('Speed limits apply to built-in HTTP and HLS '
                  'downloads, including segmented connections. External '
                  'FFmpeg transfers are not throttled.',
                  style: TextStyle(fontSize: 12)),
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
  if (size == null) return 'Unknown';
  const names = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var index = 0;
  while (value >= 1024 && index < names.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 1)} ${names[index]}';
}

class _DownloadInput {
  const _DownloadInput(this.url, this.name, this.quality, this.scheduledAt);
  final String url;
  final String name;
  final VideoQuality quality;
  final DateTime? scheduledAt;
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
  VideoQuality _quality = VideoQuality.highest;
  DateTime? _scheduledAt;

  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (!mounted || day == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _scheduledAt == null
          ? TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10)))
          : TimeOfDay.fromDateTime(_scheduledAt!),
    );
    if (!mounted || time == null) return;
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
                    if (quality != null) setState(() => _quality = quality);
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
                  _url.text, _name.text, _quality, _scheduledAt));
              }
            },
            icon: const Icon(Icons.download),
            label: Text(_scheduledAt == null ? 'Start' : 'Schedule'),
          ),
        ],
      );
}
