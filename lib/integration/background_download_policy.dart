/// Keeping the Android foreground service alive is only justified for
/// an explicitly opted-in user with an actively transferring download.
/// A future scheduled item by itself must not hold a permanent wake lock.
bool shouldKeepAndroidDownloadService({
  required bool optedIn,
  required int activeTransfers,
}) => optedIn && activeTransfers > 0;
