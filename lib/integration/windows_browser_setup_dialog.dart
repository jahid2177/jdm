import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'windows_browser_integration.dart';

/// Guided, per-user Chrome/Edge setup. Browsers must explicitly approve an
/// unpacked extension; JDM handles Native Messaging registration afterward.
class WindowsBrowserSetupDialog extends StatefulWidget {
  const WindowsBrowserSetupDialog({super.key});

  @override
  State<WindowsBrowserSetupDialog> createState() =>
      _WindowsBrowserSetupDialogState();
}

class _WindowsBrowserSetupDialogState
    extends State<WindowsBrowserSetupDialog> {
  final chromeId = TextEditingController();
  final edgeId = TextEditingController();
  bool busy = false;
  String feedback = '';

  @override
  void dispose() {
    chromeId.dispose();
    edgeId.dispose();
    super.dispose();
  }

  Future<void> _openBrowser(JdmBrowser browser) async {
    try {
      // All arguments are fixed by the app, not constructed from web content.
      final result = await Process.run('cmd.exe', [
        '/c', 'start', '""', browser.executable, browser.extensionsPage,
      ]);
      if (result.exitCode != 0) {
        throw StateError('${browser.label} could not be opened.');
      }
    } catch (_) {
      _setFeedback('Open ${browser.extensionsPage} directly in ${browser.label}.');
    }
  }

  void _setFeedback(String value) {
    if (mounted) {
      setState(() => feedback = value);
    }
  }

  Future<void> _perform(Future<String> Function() action) async {
    setState(() => busy = true);
    try {
      _setFeedback(await action());
    } on Object catch (error) {
      _setFeedback('Setup could not finish: $error');
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<String> _detect(JdmBrowser browser) async {
    final ids = await WindowsBrowserIntegration.detectIds(browser);
    if (ids.isEmpty) {
      return 'No approved JDM extension was found in ${browser.label}. '
          'Use Load unpacked first, then retry, or paste the ID below.';
    }
    await WindowsBrowserIntegration.register(browser, ids);
    return '${browser.label} connected (${ids.length} profile ID(s)). '
        'Restart the browser to activate Download with JDM.';
  }

  Future<String> _registerManual(
    JdmBrowser browser, TextEditingController controller,
  ) async {
    final id = controller.text.trim().toLowerCase();
    if (!WindowsBrowserIntegration.isValidExtensionId(id)) {
      return 'Copy the actual 32-letter extension ID from '
          '${browser.extensionsPage}, then try again.';
    }
    await WindowsBrowserIntegration.register(browser, [id]);
    return '${browser.label} connected. Restart the browser to activate JDM.';
  }

  Widget _browserSection(JdmBrowser browser, TextEditingController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(browser.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : () => _openBrowser(browser),
              icon: const Icon(Icons.open_in_new),
              label: Text('Open ${browser.label} extensions'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: busy ? null : () => _perform(() => _detect(browser)),
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Detect and connect automatically'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLength: 32,
              decoration: InputDecoration(
                labelText: '${browser.label} extension ID (if detection fails)',
                border: const OutlineInputBorder(),
                helperText: 'Copy ID from the browser extensions page.',
                suffixIcon: IconButton(
                  tooltip: 'Paste extension ID',
                  onPressed: busy ? null : () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null && mounted) {
                      controller.text = data!.text!.trim();
                    }
                  },
                  icon: const Icon(Icons.content_paste),
                ),
              ),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => _perform(
                () => _registerManual(browser, controller),
              ),
              child: Text('Connect ${browser.label} using ID'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Browser Integration Setup'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('1. Copy the JDM extension folder below.'),
                const SizedBox(height: 5),
                SelectableText(WindowsBrowserIntegration.extensionDirectory),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                      text: WindowsBrowserIntegration.extensionDirectory,
                    ));
                    _setFeedback('Extension folder copied.');
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy extension folder'),
                ),
                const SizedBox(height: 12),
                const Text('2. Open your browser extensions page, enable '
                    'Developer mode, click Load unpacked, and select the '
                    'copied folder. Browser approval is required.'),
                const SizedBox(height: 8),
                const Text('3. Click Detect and connect automatically below. '
                    'If no extension is detected yet, paste its ID instead.'),
                const SizedBox(height: 8),
                _browserSection(JdmBrowser.chrome, chromeId),
                _browserSection(JdmBrowser.edge, edgeId),
                if (busy) const LinearProgressIndicator(),
                if (feedback.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(feedback),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
}
