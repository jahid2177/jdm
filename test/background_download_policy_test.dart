import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/integration/background_download_policy.dart';

void main() {
  test('foreground service is opt-in and only for active downloads', () {
    expect(shouldKeepAndroidDownloadService(
        optedIn: false, activeTransfers: 3), isFalse);
    expect(shouldKeepAndroidDownloadService(
        optedIn: true, activeTransfers: 0), isFalse);
    expect(shouldKeepAndroidDownloadService(
        optedIn: true, activeTransfers: 1), isTrue);
  });
}
