import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef FreeDiskBytesReader = Future<int?> Function(String destinationPath);

/// A best-effort disk-space query; unknown availability is NOT treated as
/// enough space. Callers can explicitly distinguish unknown from verified.
class DownloadStorageGuard {
  DownloadStorageGuard({
    FreeDiskBytesReader? reader,
    this.reserveBytes = 64 * 1024 * 1024,
  }) : _reader = reader ?? SystemFreeDiskBytes.read;

  final FreeDiskBytesReader _reader;
  final int reserveBytes;

  Future<DiskSpaceAssessment> assess(
    String destination, {
    required int? bytesStillToWrite,
    int assemblyBytes = 0,
  }) async {
    if (assemblyBytes < 0 || (bytesStillToWrite != null && bytesStillToWrite < 0)) {
      throw ArgumentError('Estimated remaining bytes cannot be negative.');
    }
    final needed = reserveBytes + (bytesStillToWrite ?? 0) + assemblyBytes;
    int? available;
    try {
      available = await _reader(destination);
    } catch (_) {
      available = null;
    }
    if (available != null && available < 0) {
      available = null;
    }
    return DiskSpaceAssessment(
      freeBytes: available,
      neededBytes: needed,
      totalSizeKnown: bytesStillToWrite != null,
    );
  }
}

class DiskSpaceAssessment {
  const DiskSpaceAssessment({
    required this.freeBytes,
    required this.neededBytes,
    required this.totalSizeKnown,
  });

  final int? freeBytes;
  final int neededBytes;
  final bool totalSizeKnown;

  bool get canConfirmSpace => freeBytes != null;
  bool get insufficient => freeBytes != null && freeBytes! < neededBytes;
}

class InsufficientDiskSpaceException implements Exception {
  const InsufficientDiskSpaceException(this.available, this.needed);
  final int available;
  final int needed;

  @override
  String toString() => 'Insufficient disk space: $available bytes available, '
      '$needed bytes required (including safety reserve). Free space and '
      'then Resume / Retry. Existing partial data was preserved.';
}

class SystemFreeDiskBytes {
  SystemFreeDiskBytes._();

  static const _androidChannel = MethodChannel('com.jahidul.jdm/storage');

  static Future<int?> read(String destinationPath) async {
    if (Platform.isAndroid) {
      try {
        return await _androidChannel.invokeMethod<int>(
            'availableBytes', {'path': destinationPath});
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
    }
    if (Platform.isWindows) {
      // Accept only a drive letter. No user-controlled path or command is
      // interpolated into PowerShell. UNC paths return an unknown capacity.
      final match = RegExp(r'^([a-zA-Z]):[\\/]').firstMatch(destinationPath);
      if (match == null) {
        return null;
      }
      final drive = '${match.group(1)!.toUpperCase()}:\\';
      final command = '[Console]::Out.Write('
          '([System.IO.DriveInfo]::new("$drive")).AvailableFreeSpace)';
      try {
        final result = await Process.run('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-Command', command,
        ]).timeout(const Duration(seconds: 6));
        if (result.exitCode != 0) {
          return null;
        }
        return int.tryParse(result.stdout.toString().trim());
      } on FileSystemException {
        return null;
      } on TimeoutException {
        return null;
      } on ProcessException {
        return null;
      }
    }
    return null;
  }
}
