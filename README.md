# Jahid Download Manager (JDM)

**Developer:** Md Jahidul Islam  
**Platforms:** Windows 10/11 and Android  
**Technology:** Flutter/Dart

This repository contains **Milestone 7**, a cross-platform HTTP(S)
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

## New in Milestone 4 — video link handling

- Identify direct MP4, M4V, MKV, MOV, WebM, AVI and TS downloads from URL
  extensions or the server's `Content-Type` header.
- Identify HLS `.m3u8` and DASH `.mpd` links, including extensionless HLS
  endpoints when the server returns the HLS MIME type.
- Download **completed, unencrypted MPEG-TS HLS video-on-demand playlists**.
  The HLS parser resolves relative segment links and can select the highest
  advertised bandwidth variant when audio is already muxed in the video.
- Assemble verified MPEG-TS packets in segment order, producing a **`.ts`
  file**. Never rename raw MPEG-TS bytes to `.mp4`.
- Save completed HLS segment count and committed output length. On resume,
  discard interrupted segment tails; restart if playlist URLs change.
- Show a video type label and HLS segment progress in Windows and Android UI.
- Add a **Download video with JDM** context-menu command for HTML video
  elements exposing an HTTP(S) source URL in Chrome, Edge and Firefox.
- Fail explicitly for encrypted HLS, live playlists, fragmented MP4, separate
  audio tracks, byte-range playlists, discontinuities and DASH media merging.
- New automated fixture tests for HLS playlist parsing, download assembly,
  change recovery and clearly reported unsupported formats.

## New in Milestone 5 — scheduling, quality selection, optional FFmpeg

- Add a **Start now / choose schedule** control in the Windows and Android
  dialog. Queued downloads wait until the selected local date and time, then
  start when a slot is free. The scheduled time persists in local state.
- **Scheduling runs only while JDM is running.** Launching the application
  again restarts timers; the current version has no Windows background service
  or Android WorkManager/background job.
- Add **Highest / Balanced / Lowest** quality selection for HLS master
  playlists. Variants are ranked by advertised bandwidth; this changes HLS
  MPEG-TS selection. It is not a promise of a certain resolution or bitrate.
- On Windows, **optionally** remux unencrypted DASH MPD and selected unsupported
  HLS cases (fMP4 or separate-audio playlists) to MP4 using the user's own
  installed FFmpeg binary. FFmpeg is not bundled, and not all source codecs
  are compatible with MP4 stream-copying. Quality control for this FFmpeg
  fallback is currently limited to FFmpeg's own stream selection.
- A Windows session must define `JDM_FFMPEG_PATH` as the **full path** to an
  installed `ffmpeg.exe`, then launch JDM from that environment. Example:

  ```powershell
  $env:JDM_FFMPEG_PATH = 'C:\Tools\ffmpeg\bin\ffmpeg.exe'
  .\jahid_download_manager.exe
  ```

- MPD manifests declaring `ContentProtection` are rejected. FFmpeg's allowed
  input protocols are restricted to `http,https,tcp,tls` (no `crypto` or local
  file input). No cookies, credentials, DRM removal or live capture are added.
- MP4 output is only marked **Completed** after a successful FFmpeg exit,
  output file existence, minimum length and MP4 `ftyp` signature check.
  Interrupted FFmpeg remux jobs restart from the beginning on retry.
- On Android, there is **no FFmpeg integration** in this milestone; normal
  downloads and the basic unencrypted MPEG-TS HLS path still work.

**What it does not do:** This is not a universal streaming video ripper. It
does not fetch DRM-protected media, private browser cookies,
`blob:`/`mediasource:` URLs or arbitrary live streams. The optional Windows
remuxer supports only sources that FFmpeg can stream-copy into MP4; encrypted
and protected content remain unsupported. An HLS `.ts` file requires a player
capable of reading MPEG Transport Streams.

## New in Milestone 6 — queue controls and download speed limiting

- Open **Speed and queue settings** from the top-bar tuning icon on Windows
  and Android. Choose one global cap: Unlimited, 64, 128, 256, 512, 1024,
  2048, 5120 or 10240 **KiB/s**. The limit applies across all built-in
  HTTP(S) downloads and MPEG-TS HLS segment workers **combined**.
- The shared token bucket sits ahead of disk writes; it also covers multi-
  connection segmented downloads. Its per-second burst capacity means
  instantaneous transfer rates can exceed the long-term configured average.
- FFmpeg runs externally and **does not obey this limiter**. Neither do browser
  downloads happening outside JDM.
- Set **1–5 simultaneous downloads**. Lowering the value affects new starts;
  already-active tasks are allowed to finish or be paused manually.
- Top-bar **Queue actions** provides **Hold queued downloads**, **Start queued
  downloads**, **Pause all downloads** and **Resume all paused**.
- Every queued item has **Move earlier in queue** and **Move later in queue**
  actions; the queue-position badge shows the current priority. Earlier items
  start before later ones when capacity becomes available.
- Queue hold state, parallel-task limit and speed cap persist to local
  application support storage. Existing file and scheduled-download state is
  kept separately from these settings.
- Manual **Resume all** keeps future schedules intact. Manual **Resume / Retry**
  on an individual download overrides that particular task's schedule.
- Added fixture tests for queue holding/reordering, Pause All/Resume All,
  persisted settings, and actual token-bucket throttling.

## New in Milestone 7 — Windows tray and Android background downloading

- On Windows, the JDM icon appears in the **system tray**. Closing its main
  window hides the window without stopping ongoing transfers or the browser
  integration bridge. Left-click the tray icon or choose **Open JDM** to restore.
- Windows tray actions: **Pause all downloads**, **Resume all paused**, and
  **Exit JDM**. Exit pauses/waits for active writers, saves state, closes the
  browser bridge, removes the tray icon and exits the application. Windows
  tray setup failure falls back to a normally closable window.
- On Android, **Speed and queue settings** now offers the opt-in **Keep
  downloading in background** switch. Enabling it asks the Android system for
  required foreground/background permissions and can ask to exempt JDM from
  battery optimization. Permission refusal leaves the feature off.
- While enabled and there is an active download, a visible **dataSync**
  foreground-service notification stays active. The service uses the same
  downloader/Flutter isolate, and releases its wake and Wi-Fi locks after the
  last active transfer. Queued-only, paused and completed states do not start
  the service. The user's preference survives an application restart.
- **Limits:** Foreground execution improves reliability when the user
  switches apps or turns the screen off, but is **not** an independent Android
  job engine and does not survive force-stop or process termination. Android
  15+ targets have a six-hour dataSync foreground-service allowance per
  24-hour period while backgrounded (subject to system reset rules). Android
  battery policy and OEM restrictions may terminate the service earlier.
- Download schedules still do not run after JDM exits or Android kills it;
  scheduled-only jobs do not keep a permanent foreground service running.
- Added a unit test of the foreground eligibility policy and a persisted
  background-download preference assertion.

**Build/test status:** Source and CI are provided, but Windows/Android
native builds must be run in the GitHub Actions workflow or an SDK-equipped
machine. Neither platform's system behavior is asserted as device-tested in
this source release.

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
   should add that HTTP(S) URL to its list and show progress. You can also
   right-click a video element and use **Download video with JDM** if the
   browser exposes its direct HTTP(S) source link.

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

**Scope:** Browsers send a URL selected by the user. They do not extract
private-site sessions or inspect network streams. Direct video files and the
HLS VOD subset above are now accepted; full DASH or protected media is not.
Some page URLs download HTML rather than embedded video.

## Not yet implemented

This is **not the full IDM-equivalent app**. The following are planned:

- Adaptive connection tuning and configurable per-host connection limits.
- Android Downloads folder export through Storage Access Framework/MediaStore.
- Packaging and signing browser store extensions for general distribution.
- Automatic browser download interception (if supported by browser policies).
- Android-compatible licensed media muxer and advanced live capture.
- Scheduler execution while JDM is closed, site grabber and a persistent
  Windows background *service* independent of the running tray application.
- Native Windows installer; Android background job restart after process death,
  persistent progress/complete notifications and platform download folder export.
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
- `lib/download/download_rate_limiter.dart` — shared global token bucket
  for built-in file and HLS downloads.
- `lib/main.dart` — adaptive Flutter UI.
- `lib/integration/browser_bridge_server.dart` — authenticated loopback IPC.
- `lib/video/video_source_detector.dart` — URL/MIME media classification.
- `lib/video/hls_vod_downloader.dart` — conservative MPEG-TS HLS VOD downloader.
- `lib/video/ffmpeg_muxer.dart` — optional Windows FFmpeg invocation and DASH
  content-protection manifest check.
- `native_messaging/` — Windows Native Messaging protocol and executable.
- `browser_extensions/` — unpacked Chromium and Firefox add-ons.
- `browser_integration/` — per-browser Windows registration scripts.
- `test/browser_bridge_test.dart` — native protocol and loopback queue tests.
- `test/video_download_test.dart` — local MPEG-TS HLS and DASH detection tests.
- `test/scheduled_download_test.dart` — scheduler persistence, pause, and
  deferred-start tests.
- `test/queue_rate_limit_test.dart` — queue ordering, pause/resume-all,
  preference persistence, and token-bucket timing tests.
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
