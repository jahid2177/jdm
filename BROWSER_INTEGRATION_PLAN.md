# JDM Browser Integration — Milestones 3 and 17

Native Messaging connects a user-initiated browser context-menu action to the
running JDM Windows application. It does **not** intercept every browser
download or bypass website authentication.

## Flow

1. Chrome/Edge/Firefox extension shows **Download link with JDM** on HTTP(S) links.
2. Extension sends a restricted `add_download` message to the OS-registered host.
3. `jdm_native_host.exe` validates the URL and reads the current JDM app's
   ephemeral localhost endpoint/token from per-user Windows APPDATA.
4. Dart HTTP server listening on `127.0.0.1` verifies the token, then calls
   `DownloadController.addUrl`. The new task appears in the app.
5. Result is reported to the extension; success is not claimed until JDM
   acknowledges the queued task.

## Security decisions

- No always-on content scripts, permanent remote host permissions, arbitrary
  command execution, registry-wide privileged installation, or cookie
  extraction. Milestone 17 adds a **user-initiated** active-tab DOM link scan
  with `activeTab` permission and Chromium's `scripting` permission.
- Host accepts HTTP and HTTPS URLs only; limit is 64 KiB input and 16 KiB IPC.
- Local endpoint has a randomly chosen TCP port and 256-bit token.
- Per-browser native host manifests list explicit extension IDs; no wildcards.
- Firefox uses a stable `gecko.id` for its allowed-extensions manifest.
- Native host writes only framed protocol messages to stdout; errors to stderr.
- JDM must already be running; stale bridge configs report not running.

## Current limitations

The browser popup's scanner displays up to 40 HTTP(S) file/media links when
the user selects **Scan active page for download links**. Each queued item
requires its own confirmation click; the page is never scanned in the
background or sent wholesale to JDM.

The browser extension transfers plain direct URLs, not credentials, session
cookies, video streams, POST bodies or signed-in browser state. Windows browser
integration is intentionally separate from future Android share-intent support.

See [README.md](README.md) for Windows registration steps.
