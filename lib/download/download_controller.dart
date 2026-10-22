import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'download_record.dart';
import 'segmented_downloader.dart';

/// Streaming HTTP(S) downloader shared by Windows and Android.
/// Uses verified byte ranges when available and a single stream otherwise.
class DownloadController extends ChangeNotifier {
  DownloadController._(
    this._stateDirectory,
    this.downloadDirectory, {
    this.segmentThresholdBytes = 2 * 1024 * 1024,
    this.connectionsPerFile = 4,
  });

  factory DownloadController.forTesting(
    Directory stateDirectory,
    Directory downloadDirectory, {
    int segmentThresholdBytes = 2 * 1024 * 1024,
    int connectionsPerFile = 4,
  ) => DownloadController._(
        stateDirectory,
        downloadDirectory,
        segmentThresholdBytes: segmentThresholdBytes,
        connectionsPerFile: connectionsPerFile,
      );

  static Future<DownloadController> create() async {
    final stateDirectory = await getApplicationSupportDirectory();
    final publicDownloads = Platform.isWindows ? await getDownloadsDirectory() : null;
    // Android scoped storage initially uses an app-private folder.
    final downloads = publicDownloads ?? await getApplicationDocumentsDirectory();
    final controller = DownloadController._(stateDirectory, downloads);
    await controller.initialize();
    return controller;
  }

  final Directory _stateDirectory;
  final Directory downloadDirectory;
  final int segmentThresholdBytes;
  final int connectionsPerFile;
  final List<DownloadRecord> _records = [];
  final Map<String, HttpClient> _clients = {};
  final Set<String> _activeIds = {};
  Future<void> _pendingSave = Future.value();
  Future<void> _finalizeBarrier = Future.value();
  int _sequence = 0;
  int maxSimultaneous = 3;

  List<DownloadRecord> get downloads => List.unmodifiable(_records);
  int get activeCount => _activeIds.length;

  File get _stateFile =>
      File('${_stateDirectory.path}${Platform.pathSeparator}downloads.json');

  Future<void> initialize() async {
    await _stateDirectory.create(recursive: true);
    await downloadDirectory.create(recursive: true);
    for (final file in [_stateFile, File('${_stateFile.path}.bak')]) {
      if (!await file.exists()) continue;
      try {
        final data = jsonDecode(await file.readAsString()) as List<dynamic>;
        _records
          ..clear()
          ..addAll(data.map((e) =>
              DownloadRecord.fromJson(Map<String, dynamic>.from(e as Map))));
        break;
      } catch (_) {
        // Recover from the previous snapshot if a write was interrupted.
      }
    }
    for (final record in _records) {
      if (record.status == DownloadStatus.downloading) {
        record.status = DownloadStatus.paused;
      }
      if (record.status != DownloadStatus.completed) {
        if (record.segments.isNotEmpty) {
          try {
            await SegmentedDownloader.syncFiles(record);
          } catch (error) {
            record.status = DownloadStatus.failed;
            record.error = error.toString();
          }
        } else {
          final part = _partialFile(record);
          if (await part.exists()) record.downloadedBytes = await part.length();
        }
      }
    }
    notifyListeners();
  }

  static String safeName(String value) {
    var name = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (name.isEmpty || name == '.' || name == '..') name = 'download';
    final stem = name.split('.').first.toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) {
      name = '_$name';
    }
    return name.length > 180 ? name.substring(0, 180) : name;
  }

  Future<DownloadRecord> addUrl(String input, {String? fileName}) async {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Enter a valid HTTP or HTTPS URL.');
    }
    final inferred = uri.pathSegments.isEmpty || uri.pathSegments.last.isEmpty
        ? 'download'
        : uri.pathSegments.last;
    final name = safeName(fileName == null || fileName.trim().isEmpty
        ? inferred
        : fileName);
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final record = DownloadRecord(
      id: id,
      url: uri.toString(),
      fileName: name,
      savePath: '${downloadDirectory.path}${Platform.pathSeparator}$name',
      createdAt: DateTime.now(),
    );
    _records.insert(0, record);
    notifyListeners();
    await _save();
    _pump();
    return record;
  }

  File _partialFile(DownloadRecord record) =>
      File('${record.savePath}.${record.id}.jdm-part');

  Future<void> pause(String id) async {
    final record = _find(id);
    if (record == null || record.status != DownloadStatus.downloading) return;
    record.status = DownloadStatus.paused;
    _clients[id]?.close(force: true);
    notifyListeners();
    await _save();
  }

  Future<void> resume(String id) async {
    final record = _find(id);
    if (record == null || record.status == DownloadStatus.completed) return;
    // A paused socket may still be unwinding; wait for its writer to close.
    if (_activeIds.contains(id)) await waitForIdle(id: id);
    record.status = DownloadStatus.queued;
    record.error = null;
    notifyListeners();
    await _save();
    _pump();
  }

  Future<void> remove(String id) async {
    final record = _find(id);
    if (record == null) return;
    if (_activeIds.contains(id)) {
      await pause(id);
      await waitForIdle(id: id);
    }
    final part = _partialFile(record);
    if (await part.exists()) await part.delete();
    await SegmentedDownloader.deleteSegments(record);
    // Completed files remain on disk when history is removed.
    _records.remove(record);
    notifyListeners();
    await _save();
  }

  DownloadRecord? _find(String id) {
    for (final record in _records) {
      if (record.id == id) return record;
    }
    return null;
  }

  void _pump() {
    for (final record in _records.reversed) {
      if (_activeIds.length >= maxSimultaneous) break;
      if (record.status != DownloadStatus.queued) continue;
      _activeIds.add(record.id);
      unawaited(_run(record));
    }
  }

  Future<void> _run(DownloadRecord record) async {
    record.status = DownloadStatus.downloading;
    record.error = null;
    notifyListeners();
    try {
      await _save();
      await _download(record);
      if (record.status == DownloadStatus.downloading) {
        record.status = DownloadStatus.completed;
        record.bytesPerSecond = 0;
      }
    } catch (error) {
      if (record.status != DownloadStatus.paused) {
        record.status = DownloadStatus.failed;
        record.error = error.toString();
      }
    } finally {
      _clients.remove(record.id)?.close(force: true);
      _activeIds.remove(record.id);
      notifyListeners();
      try {
        await _save();
      } catch (error) {
        debugPrint('Could not save download state: $error');
      }
      _pump();
    }
  }

  Future<void> _download(DownloadRecord record) async {
    final part = _partialFile(record);
    await part.parent.create(recursive: true);
    final existing = await part.exists() ? await part.length() : 0;
    if (record.segments.isNotEmpty || existing == 0) {
      final probe = await SegmentedDownloader.probe(Uri.parse(record.url));
      if (record.status != DownloadStatus.downloading) return;
      if (record.segments.isNotEmpty) {
        final previous = RangeProbe(
          record.totalBytes ?? 0, record.etag, record.lastModified,
        );
        final canResume = probe != null &&
            probe.totalBytes == previous.totalBytes &&
            probe.validator != null &&
            probe.validator == previous.validator;
        if (!canResume) {
          // Never append saved segments to an unverified or changed resource.
          await SegmentedDownloader.deleteSegments(record);
          record.segments.clear();
          record.usedConnections = 1;
          record.downloadedBytes = 0;
          record.totalBytes = null;
          record.etag = null;
          record.lastModified = null;
          await _save();
        }
      }
      if (record.segments.isEmpty && existing == 0 && probe != null &&
          probe.validator != null &&
          probe.totalBytes >= segmentThresholdBytes) {
        record.segments.addAll(
          SegmentedDownloader.plan(probe.totalBytes, connectionsPerFile),
        );
        record.usedConnections = record.segments.length;
        record.totalBytes = probe.totalBytes;
        record.etag = probe.etag;
        record.lastModified = probe.lastModified;
        record.downloadedBytes = 0;
        await _save();
      }
      if (record.segments.isNotEmpty) {
        final client = HttpClient()
          ..autoUncompress = false
          ..connectionTimeout = const Duration(seconds: 25)
          ..maxConnectionsPerHost = connectionsPerFile.clamp(1, 16).toInt();
        _clients[record.id] = client;
        final clock = Stopwatch()..start();
        var lastMillis = 0;
        var lastBytes = record.downloadedBytes;
        await SegmentedDownloader.fetchAll(
          record: record,
          client: client,
          isDownloading: () => record.status == DownloadStatus.downloading,
          onProgress: () {
            final now = clock.elapsedMilliseconds;
            if (now - lastMillis < 500) return;
            final elapsed = now - lastMillis;
            record.bytesPerSecond =
                (record.downloadedBytes - lastBytes) * 1000 / elapsed;
            lastMillis = now;
            lastBytes = record.downloadedBytes;
            notifyListeners();
            unawaited(_save().catchError((Object _) {}));
          },
        );
        if (record.status != DownloadStatus.downloading) return;
        await SegmentedDownloader.assemble(record, part);
        final segmentBasePath = record.savePath;
        await _finalizeFile(record, part);
        try {
          await SegmentedDownloader.deleteSegments(
            record,
            basePath: segmentBasePath,
          );
        } catch (error) {
          debugPrint('Could not remove temporary segments: $error');
        }
        record.segments.clear();
        return;
      }
    }
    if (record.status == DownloadStatus.downloading) {
      await _downloadSingle(record, part);
    }
  }

  Future<void> _downloadSingle(DownloadRecord record, File part) async {
    var existing = await part.exists() ? await part.length() : 0;
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 25);
    _clients[record.id] = client;
    final request = await client.getUrl(Uri.parse(record.url));
    request.followRedirects = true;
    request.maxRedirects = 6;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (existing > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      final validator = record.etag != null && !record.etag!.startsWith('W/')
          ? record.etag
          : record.lastModified;
      if (validator != null) request.headers.set('If-Range', validator);
    }
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(record.url));
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw StateError('Server returned an encoded response unexpectedly.');
    }

    int? total;
    var mode = FileMode.write;
    if (response.statusCode == HttpStatus.partialContent) {
      final header = response.headers.value(HttpHeaders.contentRangeHeader);
      final match = header == null
          ? null
          : RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(header);
      if (match == null) throw const FormatException('Invalid Content-Range.');
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (start != existing || end < start || match.group(3) == '*') {
        throw const FormatException('Unexpected server byte range.');
      }
      total = int.parse(match.group(3)!);
      if (end >= total) throw const FormatException('Invalid range total.');
      final freshEtag = response.headers.value(HttpHeaders.etagHeader);
      if (record.etag != null && freshEtag != null && freshEtag != record.etag) {
        throw const FormatException('The remote file changed.');
      }
      mode = FileMode.append;
    } else {
      // The server ignored Range: safely restart instead of appending bytes.
      existing = 0;
      record.downloadedBytes = 0;
      total = response.contentLength >= 0 ? response.contentLength : null;
      record.etag = null;
      record.lastModified = null;
    }

    record.totalBytes = total;
    record.etag = response.headers.value(HttpHeaders.etagHeader) ?? record.etag;
    record.lastModified = response.headers.value(HttpHeaders.lastModifiedHeader) ??
        record.lastModified;
    record.downloadedBytes = existing;
    notifyListeners();

    final writer = await part.open(mode: mode);
    var lastNotify = DateTime.now();
    var lastSpeedBytes = existing;
    try {
      await for (final bytes in response) {
        if (record.status != DownloadStatus.downloading) break;
        await writer.writeFrom(bytes);
        record.downloadedBytes += bytes.length;
        final now = DateTime.now();
        final elapsed = now.difference(lastNotify).inMilliseconds;
        if (elapsed >= 500) {
          record.bytesPerSecond =
              (record.downloadedBytes - lastSpeedBytes) * 1000 / elapsed;
          lastSpeedBytes = record.downloadedBytes;
          lastNotify = now;
          notifyListeners();
          unawaited(_save().catchError((Object _) {}));
        }
      }
      await writer.flush();
    } finally {
      await writer.close();
    }
    if (record.status != DownloadStatus.downloading) return;
    final size = await part.length();
    if (total != null && size != total) {
      throw StateError('Incomplete download: $size of $total bytes.');
    }

    await _finalizeFile(record, part);
  }

  Future<void> _finalizeFile(DownloadRecord record, File part) async {
    // Serialize final names so simultaneous downloads cannot overwrite each
    // other between the existence check and the rename.
    final permission = Completer<void>();
    final previous = _finalizeBarrier;
    _finalizeBarrier = permission.future;
    await previous;
    try {
      final size = await part.length();
      var destination = File(record.savePath);
      if (await destination.exists()) {
        final dot = record.fileName.lastIndexOf('.');
        final stem = dot > 0 ? record.fileName.substring(0, dot) : record.fileName;
        final suffix = dot > 0 ? record.fileName.substring(dot) : '';
        var index = 1;
        do {
          destination = File(
            '${downloadDirectory.path}${Platform.pathSeparator}$stem ($index)$suffix',
          );
          index++;
        } while (await destination.exists());
      }
      await part.rename(destination.path);
      record.savePath = destination.path;
      record.downloadedBytes = size;
      record.totalBytes = size;
    } finally {
      permission.complete();
    }
  }

  Future<void> waitForIdle({String? id}) async {
    while (id == null ? _activeIds.isNotEmpty : _activeIds.contains(id)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await _pendingSave;
  }

  Future<void> _save() {
    final snapshot = jsonEncode(_records.map((e) => e.toJson()).toList());
    _pendingSave = _pendingSave.catchError((Object _) {}).then((_) async {
      final file = _stateFile;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      if (await file.exists()) {
        await file.copy('${file.path}.bak');
        await file.delete();
      }
      await temporary.rename(file.path);
    });
    return _pendingSave;
  }

  @override
  void dispose() {
    for (final client in _clients.values) {
      client.close(force: true);
    }
    super.dispose();
  }
}
