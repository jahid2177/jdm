import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/integration/windows_browser_integration.dart';

void main() {
  final chromeId = List.filled(32, 'a').join();
  final edgeId = List.filled(32, 'b').join();
  const installedPath = r'C:\Apps\JDM\browser_extensions\chromium';

  test('rejects made-up browser extension IDs', () {
    expect(WindowsBrowserIntegration.isValidExtensionId(chromeId), true);
    expect(WindowsBrowserIntegration.isValidExtensionId('not-an-id'), false);
    expect(WindowsBrowserIntegration.isValidExtensionId(
        List.filled(32, 'z').join()), false);
    expect(() => WindowsBrowserIntegration.manifest(installedPath, ['wrong']),
        throwsFormatException);
  });

  test('native host manifest allows only validated explicit browser IDs', () {
    final config = WindowsBrowserIntegration.manifest(
      r'C:\Apps\JDM\jdm_native_host.exe', [edgeId, chromeId, edgeId],
    );
    expect(config['name'], WindowsBrowserIntegration.hostName);
    expect(config['type'], 'stdio');
    expect(config['allowed_origins'], [
      'chrome-extension://$chromeId/',
      'chrome-extension://$edgeId/',
    ]);
  });

  test('detects only an unpacked JDM folder across browser profiles', () async {
    final root = await Directory.systemTemp.createTemp('jdm-browser-detect-');
    try {
      final defaultProfile = Directory('${root.path}${Platform.pathSeparator}Default');
      await defaultProfile.create();
      await File('${defaultProfile.path}${Platform.pathSeparator}Preferences')
          .writeAsString(jsonEncode({
        'extensions': {'settings': {
          chromeId: {'path': 'C:/Apps/JDM/browser_extensions/chromium/'},
          edgeId: {'path': r'C:\Apps\Another Extension'},
        }},
      }));
      final secondProfile = Directory('${root.path}${Platform.pathSeparator}Profile 1');
      await secondProfile.create();
      await File('${secondProfile.path}${Platform.pathSeparator}Preferences')
          .writeAsString(jsonEncode({
        'extensions': {'settings': {
          edgeId: {'path': installedPath},
        }},
      }));
      final detected = await WindowsBrowserIntegration.detectIds(
        JdmBrowser.chrome,
        profilesRoot: root,
        extensionPath: installedPath,
      );
      expect(detected, [chromeId, edgeId]);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
