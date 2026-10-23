# Jahid Download Manager (JDM)

**Developer:** Md Jahidul Islam  
**Platforms:** Windows 10/11 and Android  
**Technology:** Flutter/Dart

This repository contains **Milestones 15–20 (v2.0.0 source candidate)**, a cross-platform HTTP(S)
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

## New in Milestone 8 — completed file actions and public Downloads export

- A **completed** download's action menu now contains **Open file** and
  **Share file** on Android and Windows, with the relevant OS app chooser.
  The original JDM file remains intact. Missing, empty and unfinished files
  are rejected before launching any native file action.
- Windows: **Show in Windows Explorer** selects the completed file in its
  folder. Every download also has **Copy download URL**.
- Android 10+ (API 29+): **Export to Downloads/JDM** copies a completed file
  from JDM's app-private storage to the user-visible shared Downloads area
  through **MediaStore.Downloads**. This is a copy, not a move; the original
  stays available for resume/history and is never deleted by exporting.
- The Android export uses a **64-KiB streaming buffer**, so a large video
  does not need to fit in RAM. It marks the destination `IS_PENDING` during
  writing, publishes the entry only after successfully writing and closing,
  and deletes an unfinished destination entry on failure. The original file
  is untouched after an export failure.
- A dedicated Kotlin `MainActivity` implements the Android MediaStore
  platform channel. It validates that the source file is inside JDM's app
  storage, and performs the disk copy on a worker thread.
- New Android downloads go to JDM's app-private application-support `downloads`
  directory, where Android's file-sharing provider can safely authorize a
  chosen viewer. Existing records keep their earlier `app_flutter` file paths;
  Open/Share copies those *legacy* files into a temporary provider-readable
  location when requested. The original remains unchanged. Large legacy
  files need enough extra temporary disk space to be opened or shared.
- Android 9 or older: public Downloads export intentionally returns an
  **unsupported-version** error; legacy storage permission/SAF fallback has
  not yet been implemented. Open and Share are independent of MediaStore.
- No broad `MANAGE_EXTERNAL_STORAGE` or unnecessary storage permissions are
  requested. An Android FileProvider exposes only the app's file/cache and
  app-specific external-file roots to explicitly chosen receiving apps.
- Open and Share use pinned Flutter plugins compatible with Dart 3.4. Windows
  file sharing depends on a suitable operating-system handler, and Open
  depends on a corresponding installed application for the file type.
- Added file action validation tests for unfinished, missing, empty and
  completed files.

**Milestone 8 default:** Android app-private storage is still the JDM download
engine's main destination. When auto-export is disabled, choose **Export to
Downloads/JDM** for each completed item. Do not delete the app or its data
before exporting wanted files. The Kotlin source is provided
under `android/app/src/main/kotlin/com/jahidul/jahid_download_manager/` and
must remain present when the platform scaffold is generated in GitHub Actions.

## New in Milestone 9 — automatic export, completion alerts and Windows installer

- Android **Speed and queue settings** now has two independent opt-in switches:
  **Auto-export completed downloads** and **Download completed notifications**.
  Both preferences persist locally and are disabled by default.
- Android 10+ automatically copies a **newly completed** download to the
  user-visible `Downloads/JDM` folder when auto-export is enabled. Android 9
  or older cannot enable this switch. No file is moved or removed.
- Newly completed downloads are tracked by ID. The automatic exporter shares
  its in-progress copy with manual export requests, preventing concurrent
  duplicate copies of the same file. A successful destination URI is saved in
  the download record, so restarting JDM does not re-export it.
- Export errors are saved on the task and shown in the Android downloads list;
  the user can manually retry Export. Existing completed files are **not**
  exported in bulk just because the switch was enabled or JDM restarted.
- Completion notifications: Android 13+ requests `POST_NOTIFICATIONS`
  permission when the user enables alerts. On older supported Android
  versions, the OS notification-enabled state is checked. Successful new
  transfers issue individual notifications containing only the filename,
  with a tap opening JDM. They do not trigger after merely opening JDM with
  an existing completed history.
- **Process requirement:** Automatic copying and notifications use the
  running JDM process. Android force-stop or process death can interrupt an
  in-progress export; that file may need manual export after relaunch.
- Windows GitHub Actions continues producing `JDM-Windows-x64.zip`, and now
  additionally compiles **`JDM-Setup-v0.9.0-Windows-x64.exe`** using Inno Setup.
  The per-user installer requires no administrator privileges, includes the
  full Flutter runtime, native messaging host, browser extensions and setup
  scripts, creates a Start Menu shortcut, and offers an optional desktop icon.
  The Windows installer is **unsigned**, so Windows may show a publisher
  warning. Browser extensions still require manual registration/approval.
- Added tests for persisted completion preferences, per-file export state,
  error clearing and backward compatibility with older download records.

**Milestone 9 setting note:** Manual Android Export from Milestone 8 still
works when auto-export is off. With auto-export on, no additional export tap
is necessary after a new completed task while the JDM process remains alive.

## New in Milestone 10 — JSON history backup, intelligent retry and installer guidance

- A new **History** toolbar menu lets Windows and Android users **Export
  history JSON** and **Restore history JSON** using native file dialogs.
  The backup is a versioned JSON document with source URLs, file names, dates,
  media kind, quality and previous status. **Downloaded files are not in the
  backup.** URLs may contain access tokens, so keep exported JSON private.
- Restore is an additive, duplicate-aware operation: existing downloads and
  completed file bytes are untouched. Entries from the backup receive new
  internal IDs and safe local filenames. Every imported item starts **Paused**
  with zero downloaded bytes, even if its old entry was completed. JDM does
  not automatically contact imported URLs. Resume an entry manually to start
  a new download if the remote source is still reachable.
- Backup validation rejects unsupported format versions, invalid HTTP(S)
  URLs, user-info credentials in URLs, malformed entries and oversized files.
  Invalid input is rejected before adding any records.
- The queue can now automatically retry temporary socket/timeout failures and
  HTTP **408, 429 and 5xx** responses for direct HTTP(S) file/video links.
  Retry attempts use increasing delays (2, 4, 8, 16, 32 seconds) and stop
  when the selected limit is reached. Default **2** automatic retries; set
  **0–5** in **Speed and queue settings**. HTTP 404, malformed media, DRM,
  and FFmpeg/HLS unsupported failures are not auto-retried.
- Pending retry time and attempt count persist to local download state.
  Manual **Resume / Retry** resets the retry count and starts immediately;
  **Pause** prevents future automatic attempts. Retries require the JDM
  process to be running.
- Windows per-user installer v1.0.0 includes a **Browser integration setup**
  Start Menu shortcut and optional post-install guide. Chrome/Edge and Firefox
  native messaging registration still requires the user's approval and actual
  extension ID. The installer handles in-use applications more gracefully;
  it does not silently change browser profiles or remove download history.
- Added tests covering history validation, safe additive restore, 503 recovery,
  non-retryable 404, pausing a pending retry, and persisted retry preferences.

**Platform build note:** The source is supplied with GitHub Actions for the
Android ARM64 APK, Windows ZIP and `JDM-Setup-v1.0.0-Windows-x64.exe`.
Host-side Flutter/Dart build verification is still needed on an SDK-equipped
machine; Windows/Android runtime behavior has not been claimed device-tested.

## New in Milestone 11 — mirrors, reconnect, category folders and diagnostics

- **User-supplied alternate mirrors:** In Add Download, provide up to five
  HTTP(S) URLs, one per line. If a direct file/video URL fails with a
  connection error, timeout, HTTP 404/408/429 or HTTP 5xx, JDM can try the
  next mirror. It switches **only when there are zero downloaded bytes and
  no saved segments/partial content**. JDM never combines bytes from two
  servers without validating them. Mirror order and active URL are persisted.
  HLS/DASH URLs do not support mirror switching in this milestone.
- **Reconnect recovery:** When socket connectivity fails, JDM can wait and
  try the same source again at increasing intervals (5, 10, 20, 40, up to
  60 seconds). Toggle **Auto resume after reconnect** under Settings.
  The waiting state and number of checks survive app relaunches. Disabling
  the preference stops pending network-wait tasks; manual Retry still works.
  Reconnect checks only run while the app process is alive and allowed to run
  timers; Android background restrictions still apply.
- **Managed category folders:** New downloads go to a `JDM/<Category>`
  subfolder beneath JDM's download root. Automatic categories include Videos,
  Documents, Music, Archives and General; you can override from Add Download.
  The search bar also has a category filter. Every non-active task offers
  **Move to <Category>**; a completed file is moved to the chosen folder
  without replacing an existing file, while untouched queued/paused tasks
  can update their future destination. Active downloads and partially saved
  transfers cannot move folders until safe. Older saved paths are preserved.
- **Statistics and diagnostics:** Use History → Download statistics to view
  total/completed/failed/active/offline counts, stored completed bytes and
  per-category counts. Use an item's **Diagnostics** action for source URL,
  current mirror, retry count, offline checks, active progress, last error and
  destination path. URL-bearing diagnostics can contain private tokens.
- Versioned JSON history backups now include categories while retaining
  compatibility with previous v1 history backups lacking a category field.
- Added tests for mirror failover, refusal to mix partial content, invalid
  mirror URLs, connectivity restoration, disabling reconnect, category moves,
  filename collision handling and persisted mirror/settings metadata.

**Important:** Mirror URLs must point to the same intended file; JDM does not
perform cryptographic content equality checks between different hosts. It
avoids mixing bytes by switching only before any data is saved. The Windows
installer for this milestone is `JDM-Setup-v1.1.0-Windows-x64.exe`.

## New in Milestone 12 — queue priority, duplicates, speed chart and alerts

- **Duplicate URL detection:** Adding the exact same primary HTTP(S) URL again
  shows a confirmation dialog, with an explicit **Add another copy** choice.
  The download engine rejects duplicates by default; callers must explicitly
  opt in to create another one. Existing completed files are not overwritten.
  The Windows browser bridge returns HTTP 409 `duplicate_download` rather
  than silently enqueueing a second copy.
- **Enhanced queue:** Queued items have **Move to top of queue** and
  **Move to bottom of queue** commands alongside the existing one-step
  controls. The queue menu also offers **Retry all failed downloads**. Queue
  reorder persists across application restarts. Bulk retry preserves
  existing partial files; the normal resume validator still applies.
- **Live speed graph:** A compact 60-sample graph displays measured aggregate
  transfer throughput and the observed peak in both Windows and Android
  layouts. JDM calculates it using actual byte-count differences per sample
  while transfers run, not a promised network speed. Empty/idle periods show
  zero speed. The graph history is in memory, not exported to backups.
- **Download status alerts:** In-app notices announce newly completed or
  failed downloads, without replaying old completed history at startup.
  Android adds native failed-download notifications alongside its existing
  successful-download notifications, gated by the same opt-in permission and
  setting. Windows updates its tray tooltip with the latest completed/failed
  filename (plus in-app alerts while the app is open). **Windows system toast
  notifications are not implemented** in this milestone.
- Added tests for duplicate confirmation enforcement, queue top/bottom
  movement, bulk retry, measured throughput, completed/failed alert
  transitions, and browser bridge duplicate responses.

## New in Milestone 13 — SHA-256 integrity, retry policies and monitoring

- **SHA-256 integrity:** Every fully downloaded file is hashed using a
  streaming SHA-256 calculation before its temporary file becomes a completed
  destination file. The Add URL dialog accepts an optional expected SHA-256
  (exactly 64 hexadecimal characters, case-insensitive). A mismatch marks
  the entry **Failed**, records the calculated digest and never publishes the
  mismatching temporary file as a completed download. Existing completed
  files are never overwritten. The calculated digest is preserved in the
  download state for diagnostics.
- **Clean restart:** Failed and paused items offer **Restart from zero** with
  confirmation. The operation deletes only JDM-managed partial and segment
  files, clears stale resume validators and queues a new transfer. It never
  deletes an existing completed file. Resume / Retry still retains partial
  bytes and their usual HTTP validation rules.
- **Per-download retry policies:** Each new item can use **Standard** (the
  app-wide 0–5 setting), **Extended** (up to 5 transient-error retries), or
  **Never** (manual retry only, including no automatic reconnect or mirror
  failover). These choices persist across restarts. Integrity mismatches,
  invalid content and HTTP 4xx errors (except selected transient statuses)
  are not automatically retried.
- **Live monitoring:** A new toolbar action displays each active or waiting
  download with measured throughput, downloaded bytes, a best-effort ETA,
  retry policy and connection health. Diagnostics include SHA-256 values,
  retry limit and latest progress. A download that reports no new bytes for
  15 seconds is flagged as potentially stalled; this is informational and
  does not forcibly terminate the transfer. ETA is marked unknown when
  total size or a usable throughput estimate is unavailable.
- Added local HTTP fixture tests for valid/mismatched hashes, preserved
  partial files, clean restart, invalid digests, per-item retries and ETA.

**Limitations:** The expected SHA-256 must come from a trusted source. A
matching hash confirms downloaded bytes match that value, not that the source
is harmless. Streaming HLS or DASH outputs are hashed after remux/assembly;
an expected digest must therefore describe the resulting saved file bytes.

## New in Milestone 14 — download health, disk space and safe recovery

- **Download Health Dashboard:** The heart/monitor toolbar action now shows
  active downloads, potentially stalled transfers, items flagged for low disk
  space and downloads eligible for recovery after an unexpected shutdown.
  Per-item rows show throughput, ETA, latest space measurement and the storage
  estimate. The **Check disk** action refreshes disk observations without
  restarting a transfer.
- **Disk Space Guard:** Before writing known-length direct HTTP responses, and
  before segmented downloads and their final assembly, JDM checks available
  space using Android's `StatFs` or Windows' `DriveInfo.AvailableFreeSpace`.
  A configurable safety reserve defaults to 64 MiB. Segmented downloads
  account for the extra assembled output alongside segment files. If confirmed
  available space is insufficient, the task fails without deleting existing
  partial files; free space and use **Resume / Retry**. HLS/DASH streams and
  unknown-length HTTP responses can only have their reserve checked upfront.
  Single-stream HTTP transfers also recheck every 32 MiB while receiving data.
  When the platform cannot query a destination (e.g., Windows UNC paths), the
  space is shown as **unknown** and the transfer is allowed to proceed.
- **Recovery Center:** Unexpectedly interrupted in-progress entries are
  restored as paused, with a persisted recovery marker. A confirmation in the
  Health Dashboard queues **only these interrupted items**. Deliberately
  paused, failed, and completed items are not resumed by this action. Queue
  pause and concurrency limits remain in force.
- **Finish already downloaded data without network:** If a direct file's
  temporary length matches the saved size, or all durable segmented bytes
  were written before shutdown, JDM can finish assembling and SHA-256 hashing
  locally without fetching those same bytes again. Fully committed HLS output
  is also eligible. No completed user file is silently overwritten.
- **Safer single-stream resume:** Partial HTTP data is appended only when the
  server confirms its saved strong ETag or Last-Modified validator on a valid
  byte-range response. Without a stored validator, JDM restarts the response
  from byte zero instead of mixing two possibly different resources. Existing
  unverified bytes remain until a successful HTTP response is accepted.
- Added offline/local HTTP tests for disk estimates, low-capacity refusal,
  retry after disk space becomes available, interrupted-job recovery,
  full-partial local completion, and missing-validator safety.

**Note:** Space availability is a point-in-time observation, not a disk-space
reservation. Concurrent applications can still fill the drive after a check.
JDM preserves whatever partial data it can on an I/O failure.

The historical v1.4.0 Windows installer name was
`JDM-Setup-v1.4.0-Windows-x64.exe`. As before, the installer and APK must be
built through GitHub Actions; this source archive does not contain binaries.

## Milestone 15 — recurring download windows and queue scheduling

- **Speed and queue settings** now contains a recurring download window with
  selectable weekdays, start/end device-local times, including overnight
  windows that carry into the following day. Clicking **Apply download window**
  persists the selection. This is separate from each job's existing one-shot
  start date/time: both conditions must allow the job to begin.
- A scheduler tick runs every 15 seconds while JDM is alive. When the window
  closes, in-progress jobs close their transfer sockets/processes and preserve
  partial bytes. Queued tasks become **Paused by schedule**.
- Only scheduler-paused entries resume when the window reopens. Choose
  **Keep paused (cancel auto-resume)** on an entry to opt it out. Manual
  pauses and unexpected shutdown recovery remain paused until consent.
  **Hold queued downloads** continues to block automatic starts at all times.
- No OS wake alarm, headless Windows service, or process-independent Android
  scheduler has been added. The user's machine must be awake, and JDM must be
  running. Changes to time zones or DST are interpreted in device-local time.

## Milestone 16 — privacy-preserving clipboard suggestions

- On Windows, the new clipboard button checks for a public HTTP(S) URL on
  demand. An opt-in **Suggest links copied to clipboard** setting scans while
  JDM is running. It is disabled by default; copied text stays on-device.
- Each found link requires explicit **Add to queue** approval. Ignored links
  are not added. Duplicate links are rejected by JDM's existing URL guard.
  URLs with embedded username/password are rejected.

## Milestone 17 — on-demand browser page scanner

- Chrome/Edge and Firefox extension popups include **Scan active page for
  download links**. On user action, the extension reads visible DOM links,
  media URLs and download attributes from the active tab only. It finds up
  to 40 unique public HTTP(S) candidates among the first 2,500 elements.
- A separate **Add this link to JDM** action is required for every candidate;
  no automatic browser interception or download hijacking is enabled.
  Browser-internal pages may disallow script injection. HTTP URLs needing
  cookies, signed-in sessions or DRM processing are not supported.

## Milestone 18 — performance and queue automation

- Configurable **Maximum active downloads per website (1–5)**. The queue
  respects the existing global simultaneous-download limit and manual order,
  but defers work from an already-saturated source while unrelated hosts
  may proceed. The default limit is 2 per host. Active transfers already in
  flight when the setting changes are allowed to unwind/finish safely.
- The queue refuses to launch a second worker for an ID whose previous
  writer is still active, including during scheduled pause/resume transitions.

## Milestone 19 — Windows UI/UX and preferences

- Settings contain day chips, time pickers, schedule state and per-host queue
  controls. The task list distinguishes **Paused by schedule** from a manual
  pause. The status bar shows whether the download window is open or closed.
- The top-bar theme control now cycles **System → Light → Dark**. Its choice
  persists locally across restarts rather than resetting to System each time.

## Milestone 20 — release-readiness and verification

- The version is `2.0.0+20` (installer `JDM-Setup-v2.0.0-Windows-x64.exe`).
  CI performs preflight source/manifest consistency checks, Dart formatting,
  Flutter analysis, Flutter tests, two independent browser extension tests,
  and the existing Windows ZIP / Windows installer / Android APK builds.
- **GitHub Release publication is manual.** CI creates downloadable Actions
  artifacts; it does not push tags, upload a public release or bypass GitHub
  workflow permissions.
- The source archive is **not a verified stable binary** until the Windows
  and Android GitHub jobs succeed and the app is tested on actual devices.
  In the source-editing environment only Node extension tests and Python
  preflight can run (Flutter SDK unavailable).

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

- Adaptive connection tuning beyond the new queue-level per-host limit.
- A user-selected Storage Access Framework export path and Android 9-and-older
  public Downloads compatibility.
- Packaging and signing browser store extensions for general distribution.
- Automatic browser interception (the current feature is on-demand scanning).
- Android-compatible licensed media muxer and advanced live capture.
- Scheduler execution while JDM is closed, site grabber and a persistent
  Windows background *service* independent of the running tray application.
- Windows installer code signing and automatic browser-host registration;
  Android background job restart after process death and persistent progress
  notifications.
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

The Android save folder is **app-private application storage**, not the
public Downloads folder. Removing the Android app may remove these downloaded
files. Enable automatic export or use the manual export action before removal.
Do not store your only important copy there. On Windows, files default
to the user's Downloads directory when available.

## GitHub Actions

Push the repository contents to GitHub and open **Actions → Build JDM Windows
and Android → Run workflow**. The workflow generates missing Flutter platform
scaffolding and creates:

- `JDM-Android-arm64` containing `app-release.apk`.
- `JDM-Windows-x64` containing the entire Windows release folder as a ZIP,
  including the Dart native host EXE and browser-extension setup files.
- `JDM-Windows-Installer-x64` containing the Windows Setup EXE.

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
- `lib/integration/android_completion_coordinator.dart` — running-process
  completed-task tracking, automatic MediaStore export, notifications.
- `android/.../MainActivity.kt` — MediaStore export and Android completion
  notification/permission integration.
- `installer/jdm.iss` — Windows per-user installer template.
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
- `lib/download/download_schedule_window.dart` — recurring local-time policy.
- `lib/integration/clipboard_link_detector.dart` — safe link suggestion parser.
- `test/milestones_15_to_20_test.dart` — scheduler/queue/privacy tests.
- `test/browser_page_scanner_test.js` — on-demand browser DOM scanner tests.
- `tools/check_release.py` — read-only release consistency preflight.
- `.github/workflows/build.yml` — CI builds for both platforms.

## Important limitations

HTTP servers that do not provide valid ranges cannot reliably resume partial
files. This app restarts such downloads. A file must be at least **2 MiB**,
provide valid byte-range responses, and expose an ETag or Last-Modified
validator to use the segmented engine. Smaller or incompatible files use one
stream. There is no guarantee that multiple connections will improve speed.

This source release does not handle automatic browser interception,
login sessions, private-site cookies or protected media.
Please only download material you are authorized to access.
