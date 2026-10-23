"""Fail early if source and packaged-artifact version metadata diverge.

This check only reads repository files. It does not publish or upload files.
"""
from pathlib import Path
import json
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
version = "2.0.0"
checks = {
    "pubspec.yaml": f"version: {version}+20",
    "installer/jdm.iss": f"AppVersion={version}",
    ".github/workflows/build.yml": f"JDM-Setup-v{version}-Windows-x64.exe",
    "lib/main.dart": f"JDM {version}",
    "installer/BROWSER_SETUP.txt": f"Version {version}",
}

for path, marker in checks.items():
    source = ROOT / path
    if not source.is_file() or marker not in source.read_text(encoding="utf-8"):
        sys.exit(f"Release preflight failed: {path} lacks {marker!r}")

for browser in ("chromium", "firefox"):
    base = ROOT / "browser_extensions" / browser
    manifest = json.loads((base / "manifest.json").read_text(encoding="utf-8"))
    if manifest["version"] != version:
        sys.exit(f"Version mismatch: {browser}")
    if "activeTab" not in manifest["permissions"]:
        sys.exit(f"Missing opt-in page-scan permission: {browser}")
    if browser == "chromium" and "scripting" not in manifest["permissions"]:
        sys.exit("Chromium requires the scripting permission")
    for script in ("popup.js", "background.js"):
        if not (base / script).is_file():
            sys.exit(f"Missing extension file: {browser}/{script}")

ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml")
if not (ROOT / "lib/download/download_schedule_window.dart").is_file():
    sys.exit("Missing scheduling policy")
if not (ROOT / "lib/integration/clipboard_link_detector.dart").is_file():
    sys.exit("Missing clipboard link detector")
if not re.search(r"(?m)^name:\s*jahid_download_manager\s*$",
                 (ROOT / "pubspec.yaml").read_text(encoding="utf-8")):
    sys.exit("Flutter package name does not match source imports")
print(f"JDM {version}: release source consistency checks passed")
