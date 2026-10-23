import 'package:flutter_test/flutter_test.dart';
import 'package:jahid_download_manager/download/download_record.dart';

// Prevent flutter create from adding its generic MyApp counter test.
// Exercise a real, dependency-free JDM model instead.
void main() {
  test('categorizes completed download names consistently', () {
    expect(
      DownloadCategoryDetails.infer('guide.pdf', DownloadKind.file),
      DownloadCategory.documents,
    );
    expect(
      DownloadCategoryDetails.infer('video.mkv', DownloadKind.file),
      DownloadCategory.videos,
    );
    expect(
      DownloadCategoryDetails.infer('stream.m3u8', DownloadKind.hls),
      DownloadCategory.videos,
    );
  });
}
