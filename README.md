# Jahid Download Manager (JDM)

**Developer:** Md Jahidul Islam  
**Platforms:** Windows 10/11 and Android  
**Technology:** Flutter/Dart

This repository contains **Milestone 1**, a real cross-platform HTTP(S)
download manager. It is an original project inspired by the workflow of
desktop download managers. It does not contain Internet Download Manager code.

## Implemented in Milestone 1

- Add HTTP/HTTPS download URLs and optionally rename the destination file.
- Stream download data to disk without loading entire files into memory.
- Download up to three different files simultaneously.
- Pause, retry and resume from saved partial files when the server supports
  HTTP Range requests.
- Gracefully restart from byte zero when a server ignores Range requests.
- Persist the download list and partial download metadata across app restarts.
- Recover previous active tasks as paused after an application restart.
- Detect incomplete byte counts and avoid reporting incomplete files as done.
- Sanitize file names and avoid overwriting existing completed files.
- Windows table view and Android card view, live progress, search and filters.
- Light/dark mode, basic error messages and delete-history confirmation.
- Automated test fixtures for ordinary, non-Range and interrupted downloads.
- GitHub Actions workflows for Windows release ZIP and Android ARM64 APK.

## Not yet implemented

This is **not the full IDM-equivalent app**. The following are planned:

- Multi-segment, multi-connection acceleration **within the same file**.
- Android Downloads folder export through Storage Access Framework/MediaStore.
- Chrome/Edge/Firefox extensions and secure Native Messaging host.
- Video detection, HLS/DASH, licensed optional FFmpeg integration.
- Download queues, scheduler, speed limiter, site grabber, tray integration.
- Native Windows installer, background Android service and notifications.
- Per-server retry policies, checksums and advanced test coverage.

## How to run locally

Install the current stable Flutter SDK with Windows/Android prerequisites.
From the repository directory, run:

```bash
flutter create --platforms=windows,android --org com.jahidul .
flutter pub get
flutter analyze
flutter test
```

Windows:

```bash
flutter run -d windows
flutter build windows --release
```

Android:

```bash
flutter run -d android
flutter build apk --release --target-platform android-arm64
```

The Android release manifest includes `INTERNET` permission and explicitly
allows user-entered HTTP URLs. HTTPS is safer and should be preferred.

The initial Android save folder is **app-private documents storage**, not the
public Downloads folder. Removing the Android app may remove these downloaded
files. Do not store your only important copy there. On Windows, files default
to the user's Downloads directory when available.

## GitHub Actions

Push the repository contents to GitHub and open **Actions → Build JDM Windows
and Android → Run workflow**. The workflow generates missing Flutter platform
scaffolding and creates:

- `JDM-Android-arm64` containing `app-release.apk`.
- `JDM-Windows-x64` containing the entire Windows release folder as a ZIP.

For Windows, **extract the full ZIP** before launching the application: the
`.exe` requires DLL/data files from the same release folder.

No APK or Windows EXE has been built or tested in this environment because the
Flutter SDK is not installed here. Build results must be checked in Actions.

## Architecture

- `lib/download/download_record.dart` — persisted task model.
- `lib/download/download_controller.dart` — background HTTP(S) stream and
  pause/resume logic; testable with custom directories.
- `lib/main.dart` — adaptive Flutter UI.
- `test/download_controller_test.dart` — local HTTP fixture tests.
- `.github/workflows/build.yml` — CI builds for both platforms.

## Important limitations

HTTP servers that do not provide valid ranges cannot reliably resume partial
files. This app restarts such downloads. The current milestone does not handle
browser interception, logins, private website sessions or protected media.
Please only download material you are authorized to access.
