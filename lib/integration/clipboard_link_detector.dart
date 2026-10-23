/// Extracts a public HTTP(S) URL from clipboard text. Clipboard contents are
/// never sent to the network unless the user explicitly accepts the dialog.
class ClipboardLinkDetector {
  const ClipboardLinkDetector._();

  static String? firstValidLink(String? text) {
    if (text == null || text.length > 32768) return null;
    final candidates = RegExp(r'''https?://[^\s<>"']+''',
        caseSensitive: false).allMatches(text);
    for (final match in candidates) {
      final raw = match.group(0)!
          .replaceFirst(RegExp(r'[.,;\]\)]+$'), '');
      if (raw.length > 4096) continue;
      final url = Uri.tryParse(raw);
      if (url != null && {'http', 'https'}.contains(url.scheme) &&
          url.host.isNotEmpty && url.userInfo.isEmpty &&
          !url.host.contains('..')) {
        return url.toString();
      }
    }
    return null;
  }
}
