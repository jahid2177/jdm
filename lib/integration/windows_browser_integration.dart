import 'dart:convert';
import 'dart:io';

/// The native-messaging registration belongs to the logged-in Windows user.
/// Chromium does not permit an unpacked extension to be silently enabled by
/// an installer; the user must first approve it in the browser.
enum JdmBrowser { chrome, edge }

extension JdmBrowserDetails on JdmBrowser {
  String get label => this == JdmBrowser.chrome ? 'Google Chrome' : 'Microsoft Edge';

  String get executable => this == JdmBrowser.chrome ? 'chrome' : 'msedge';

  String get extensionsPage => this == JdmBrowser.chrome
      ? 'chrome://extensions' : 'edge://extensions';

  String get userDataDirectory => this == JdmBrowser.chrome
      ? 'Google\\Chrome\\User Data' : 'Microsoft\\Edge\\User Data';

  String get registryKey => this == JdmBrowser.chrome
      ? r'HKCU\Software\Google\Chrome\NativeMessagingHosts\com.jahidul.jdm'
      : r'HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.jahidul.jdm';

  String get manifestName => this == JdmBrowser.chrome
      ? 'chrome-host.json' : 'edge-host.json';
}

class WindowsBrowserIntegration {
  static const hostName = 'com.jahidul.jdm';
  static final RegExp _idPattern = RegExp(r'^[a-p]{32}$');

  static bool isValidExtensionId(String id) => _idPattern.hasMatch(id);

  static String get extensionDirectory =>
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}browser_extensions${Platform.pathSeparator}chromium';

  static String get nativeHostExecutable =>
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}jdm_native_host.exe';

  static String _normalizePath(String path) => path.trim()
      .replaceAll('/', '\\')
      .replaceAll(RegExp(r'\\+$'), '')
      .toLowerCase();

  /// Detects only unpacked extensions whose exact on-disk path matches JDM's
  /// bundled extension. An unrelated extension is never granted access.
  static Future<List<String>> detectIds(
    JdmBrowser browser, {
    Directory? profilesRoot,
    String? extensionPath,
  }) async {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (profilesRoot == null && (localAppData == null || localAppData.isEmpty)) {
      return const [];
    }
    final browserFolder = browser.userDataDirectory.replaceAll(
      '\\', Platform.pathSeparator,
    );
    final root = profilesRoot ?? Directory(
      '$localAppData${Platform.pathSeparator}$browserFolder',
    );
    if (!await root.exists()) {
      return const [];
    }
    final expectedPath = _normalizePath(extensionPath ?? extensionDirectory);
    final ids = <String>{};
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory) {
        continue;
      }
      final name = item.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (name != 'Default' && !RegExp(r'^Profile \d+$').hasMatch(name)) {
        continue;
      }
      final preferences = File('${item.path}${Platform.pathSeparator}Preferences');
      if (!await preferences.exists()) {
        continue;
      }
      try {
        final content = jsonDecode(await preferences.readAsString());
        if (content is! Map) {
          continue;
        }
        final extensions = content['extensions'];
        final settings = extensions is Map ? extensions['settings'] : null;
        if (settings is! Map) {
          continue;
        }
        for (final entry in settings.entries) {
          final id = entry.key;
          if (id is! String || !isValidExtensionId(id)) {
            continue;
          }
          final details = entry.value;
          final installedPath = details is Map ? details['path'] : null;
          if (installedPath is String &&
              _normalizePath(installedPath) == expectedPath) {
            ids.add(id);
          }
        }
      } on FileSystemException {
        // A locked or inaccessible browser profile cannot block the wizard.
      } on FormatException {
        // A partially written Preferences file is not a valid source of IDs.
      }
    }
    return ids.toList()..sort();
  }

  static Map<String, Object> manifest(String executable, Iterable<String> ids) {
    final valid = ids.map((id) => id.trim().toLowerCase()).toSet();
    if (valid.isEmpty || valid.any((id) => !isValidExtensionId(id))) {
      throw const FormatException('A real 32-letter browser extension ID is required.');
    }
    return {
      'name': hostName,
      'description': 'Jahid Download Manager browser bridge',
      'path': executable,
      'type': 'stdio',
      'allowed_origins': valid.map((id) => 'chrome-extension://$id/').toList()..sort(),
    };
  }

  /// Registers the selected, user-approved extension IDs without PowerShell.
  /// Existing IDs for other profiles of the same browser are preserved.
  static Future<void> register(JdmBrowser browser, Iterable<String> ids) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Browser registration is supported on Windows only.');
    }
    final host = File(nativeHostExecutable);
    if (!await host.exists()) {
      throw StateError('jdm_native_host.exe is missing. Reinstall the full Windows build.');
    }
    if (!await Directory(extensionDirectory).exists()) {
      throw StateError('The bundled browser extension folder is missing. '
          'Reinstall JDM or extract the complete Windows release ZIP.');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw StateError('Windows LOCALAPPDATA folder was not found.');
    }
    final manifestFolder = Directory(
      '$localAppData${Platform.pathSeparator}JahidDownloadManager'
      '${Platform.pathSeparator}NativeMessaging',
    );
    await manifestFolder.create(recursive: true);
    final file = File('${manifestFolder.path}${Platform.pathSeparator}${browser.manifestName}');
    final allowed = <String>{...ids.map((id) => id.trim().toLowerCase())};
    if (await file.exists()) {
      try {
        final old = jsonDecode(await file.readAsString());
        if (old is Map && old['allowed_origins'] is List) {
          for (final origin in old['allowed_origins'] as List) {
            if (origin is! String) {
              continue;
            }
            const prefix = 'chrome-extension://';
            if (origin.startsWith(prefix) && origin.endsWith('/')) {
              final id = origin.substring(prefix.length, origin.length - 1);
              if (isValidExtensionId(id)) {
                allowed.add(id);
              }
            }
          }
        }
      } on FormatException {
        // Replace a corrupt old manifest with the user's validated selection.
      }
    }
    final contents = manifest(host.absolute.path, allowed);
    await file.writeAsString(jsonEncode(contents), flush: true);

    final result = await Process.run('reg.exe', [
      'add', browser.registryKey, '/ve', '/t', 'REG_SZ',
      '/d', file.absolute.path, '/f',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Windows could not register ${browser.label}: ${result.stderr}');
    }
  }
}
