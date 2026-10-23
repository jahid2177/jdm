import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'download/download_controller.dart';
import 'download/download_record.dart';
import 'integration/browser_bridge_server.dart';

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
  runApp(JdmApp(controller: controller, bridge: bridge));
}

class JdmApp extends StatefulWidget {
  const JdmApp({super.key, required this.controller, this.bridge});
  final DownloadController controller;
  final BrowserBridgeServer? bridge;

  @override
  State<JdmApp> createState() => _JdmAppState();
}

class _JdmAppState extends State<JdmApp> {
  ThemeMode mode = ThemeMode.system;

  @override
  void dispose() {
    if (widget.bridge != null) unawaited(widget.bridge!.close());
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
  });
  final DownloadController controller;
  final VoidCallback onToggleTheme;

  @override
  State<DownloadHome> createState() => _DownloadHomeState();
}

class _DownloadHomeState extends State<DownloadHome> {
  DownloadFilter filter = DownloadFilter.all;
  String search = '';

  Future<void> _addDownload() async {
    final input = await showDialog<_DownloadInput>(
      context: context,
      builder: (_) => const _AddDownloadDialog(),
    );
    if (input == null) return;
    try {
      await widget.controller.addUrl(input.url, fileName: input.name);
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
    if (action == 'pause') await widget.controller.pause(record.id);
    if (action == 'resume') await widget.controller.resume(record.id);
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
              child: Text('JDM 0.4.0 • Md Jahidul Islam',
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
      DownloadStatus.queued => ('Queued', Colors.orange),
      DownloadStatus.downloading => ('Downloading', Colors.blue),
      DownloadStatus.paused => ('Paused', Colors.grey),
      DownloadStatus.completed => ('Completed', Colors.green),
      DownloadStatus.failed => ('Failed', Colors.red),
    };
    return Tooltip(
      message: record.error ?? label,
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600,
          fontSize: 12)),
    );
  }

  Widget _actions(DownloadRecord record) => PopupMenuButton<String>(
        tooltip: 'Download actions',
        onSelected: (action) => _handle(record, action),
        itemBuilder: (context) => [
          if (record.status == DownloadStatus.downloading)
            const PopupMenuItem(value: 'pause', child: Text('Pause')),
          if (record.status == DownloadStatus.paused ||
              record.status == DownloadStatus.failed ||
              record.status == DownloadStatus.queued)
            const PopupMenuItem(value: 'resume', child: Text('Resume / Retry')),
          const PopupMenuItem(value: 'path', child: Text('Show file path')),
          const PopupMenuItem(value: 'remove', child: Text('Remove from list')),
        ],
      );

  Widget _statusBar(List<DownloadRecord> all) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Text('${all.length} total downloads • '
            '${widget.controller.activeCount} active • '
            'Save folder: ${widget.controller.downloadDirectory.path}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11)),
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
  const _DownloadInput(this.url, this.name);
  final String url;
  final String name;
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
          child: Form(
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
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.pop(context, _DownloadInput(_url.text, _name.text));
              }
            },
            icon: const Icon(Icons.download),
            label: const Text('Start'),
          ),
        ],
      );
}
