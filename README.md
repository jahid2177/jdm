# Jahid Download Manager (JDM)

**Developer:** Md Jahidul Islam  
**Platforms:** Windows 10/11 and Android  
**Technology:** Flutter/Dart

This repository contains **Milestone 3**, a cross-platform HTTP(S)
download manager. It is an original project inspired by the workflow of
desktop download managers. It does not contain Internet Download Manager code.

## Implemented through Milestone 2

- Add HTTP/HTTPS download URLs and optionally rename the destination file.
- Stream download data to disk without loading entire files into memory.
- Download up to three different files simultaneously.
- Split eligible individual files into up to four concurrent HTTP byte-range
  connections. Each connection writes its own temporary segment file.
- Verify `Content-Range`, total byte count, resource validator and final
  assembled size before marking segmented downloads complete.
- Persist and recover individual segment progress after a restart.
- Invalidate old segments if the remote ETag/Last-Modified identity changes.
- Automatically fall back to a single connection when Range is unsupported.
- Display the connection count in Windows and Android download lists.
- Pause, retry and resume from saved partial files when the server supports
  HTTP Range requests.
- Gracefully restart from byte zero when a server ignores Range requests.
- Persist the download list and partial download metadata across app restarts.
- Recover previous active tasks as paused after an application restart.
- Detect incomplete byte counts and avoid reporting incomplete files as done.
- Sanitize file names and avoid overwriting existing completed files.
- Windows table view and Android card view, live progress, search and filters.
- Light/dark mode, basic error messages and delete-history confirmation.
- Automated test fixtures for ordinary, segmented, non-Range, restarted and
  interrupted downloads, plus byte-range coverage.
- GitHub Actions workflows for Windows release ZIP and Android ARM64 APK.

## New in Milestone 3 — Windows browser integration

- Chrome and Microsoft Edge Manifest V3 extension with a **Download link with
  JDM** context menu, **Download page URL with JDM**, and toolbar URL form.
- Firefox extension with corresponding context menus and toolbar form.
- Windows Native Messaging host implemented in **pure Dart**, compiled to
  `jdm_native_host.exe` in the Windows CI build.
- Native host uses the browser's registered permission list to accept requests
  and forwards validated HTTP(S) URLs to a token-authenticated Windows-local
  JDM bridge; each request is acknowledged after JDM queues the download.
- A lightweight loopback server lives in the running Windows Flutter app.
- PowerShell per-user install/uninstall scripts for browser native host
  registration; no administrator privileges are required in a standard setup.
- Tests for malformed native messages, forbidden URL schemes, unauthenticated
  bridge requests and valid end-to-end queueing with a local test HTTP server.

### Browser extension setup on Windows

1. Download the **JDM-Windows-x64** GitHub Actions artifact and extract it
   completely to a **permanent folder**. Keep all the DLLs and data files
   alongside `jahid_download_manager.exe`. The build ZIP also contains
   `jdm_native_host.exe`, `browser_extensions` and `browser_integration`.
2. **Chrome:** open `chrome://extensions`, turn on **Developer mode**, select
   **Load unpacked**, choose `browser_extensions/chromium` inside the extracted
   JDM folder, and copy the actual 32-letter extension ID shown by Chrome.
3. **Edge:** open `edge://extensions`, enable Developer mode, use **Load
   unpacked** for that same `browser_extensions/chromium` folder and copy the
   **Edge extension ID** (it can differ from Chrome's ID).
4. Open **PowerShell** in the extracted JDM folder. For each installed browser,
   run the relevant registration command below with its real extension ID:

   ```powershell
   & .\browser_integration\install_windows.ps1 -Browser Chrome -ExtensionId 'PASTE_REAL_CHROME_ID'
   & .\browser_integration\install_windows.ps1 -Browser Edge -ExtensionId 'PASTE_REAL_EDGE_ID'
   ```

5. **Firefox (development):** in `about:debugging#/runtime/this-firefox`,
   choose **Load Temporary Add-on** and select
   `browser_extensions/firefox/manifest.json`. Then register its native host:

   ```powershell
   & .\browser_integration\install_windows.ps1 -Browser Firefox
   ```

   A temporary Firefox add-on disappears when Firefox restarts. To distribute
   it permanently, the extension must be packaged and signed according to
   Mozilla's add-on policies.

6. Start `jahid_download_manager.exe` **before** sending any links. Restart
   the browsers after registering the native host. Right-click a direct file
   link and choose **Download link with JDM**, or use the toolbar form. JDM
   should add that HTTP(S) URL to its list and show progress.

Windows may block unsigned PowerShell scripts depending on local execution
policy. Respect your organization's security policy; a signed installer is a
future enhancement. Never use made-up extension IDs: each browser's real ID
must be explicitly registered.

To remove the JDM native host registration for a browser, run:

```powershell
& .\browser_integration\uninstall_windows.ps1 -Browser Chrome
```

Change `Chrome` to `Edge` or `Firefox` for that browser. This unregisters only
JDM's per-user native host and its related manifest; it does not erase saved
downloads or uninstall the browser extension. Moving the extracted release
folder after registration requires running the install script again.

**Scope:** Browsers send a URL selected by the user. This does not intercept
every download or share signed-in browser cookies, HTTP headers, DRM playback,
HLS/DASH manifests, or restricted streams. Some page URLs download HTML rather
than video or other embedded media; this is expected for Milestone 3.

## Not yet implemented

This is **not the full IDM-equivalent app**. The following are planned:

- Adaptive connection tuning and configurable per-host connection limits.
- Android Downloads folder export through Storage Access Framework/MediaStore.
- Packaging and signing browser store extensions for general distribution.
- Automatic browser download interception (if supported by browser policies).
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
- `JDM-Windows-x64` containing the entire Windows release folder as a ZIP,
  including the Dart native host EXE and browser-extension setup files.

For Windows, **extract the full ZIP** before launching the application: the
`.exe` requires DLL/data files from the same release folder.

No APK or Windows EXE has been built or tested in this environment because the
Flutter SDK is not installed here. Build results must be checked in Actions.

## Architecture

- `lib/download/download_record.dart` — persisted task model.
- `lib/download/download_controller.dart` — background HTTP(S) stream and
  pause/resume logic; testable with custom directories.
- `lib/main.dart` — adaptive Flutter UI.
- `lib/integration/browser_bridge_server.dart` — authenticated loopback IPC.
- `native_messaging/` — Windows Native Messaging protocol and executable.
- `browser_extensions/` — unpacked Chromium and Firefox add-ons.
- `browser_integration/` — per-browser Windows registration scripts.
- `test/browser_bridge_test.dart` — native protocol and loopback queue tests.
- `test/download_controller_test.dart` — local HTTP fixture tests.
- `.github/workflows/build.yml` — CI builds for both platforms.

## Important limitations

HTTP servers that do not provide valid ranges cannot reliably resume partial
files. This app restarts such downloads. A file must be at least **2 MiB**,
provide valid byte-range responses, and expose an ETag or Last-Modified
validator to use the segmented engine. Smaller or incompatible files use one
stream. There is no guarantee that multiple connections will improve speed.

The current milestone does not handle automatic browser interception,
login sessions, private-site cookies or protected media.
Please only download material you are authorized to access.
