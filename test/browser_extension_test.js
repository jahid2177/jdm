"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const base = path.join(__dirname, "..", "browser_extensions");

async function chromium() {
  const listeners = {};
  let callCount = 0;
  const chrome = {
    runtime: {
      onInstalled: {addListener: fn => listeners.installed = fn},
      onStartup: {addListener: fn => listeners.startup = fn},
      onMessage: {addListener: fn => listeners.message = fn},
      sendNativeMessage: (host, request, callback) => {
        callCount++;
        assert.equal(host, "com.jahidul.jdm");
        assert.equal(request.action, "add_download");
        callback({ok: true, taskId: "test"});
      }
    },
    contextMenus: {
      removeAll: cb => cb(),
      create: () => {},
      onClicked: {addListener: fn => listeners.clicked = fn}
    },
    storage: {local: {set: async () => {}}},
    action: {setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}}
  };
  const code = fs.readFileSync(path.join(base, "chromium", "background.js"), "utf8");
  vm.runInNewContext(code, {chrome, URL});
  listeners.installed();
  const result = await new Promise(resolve => listeners.message({
    action: "add_download", url: "https://example.com/file.zip"
  }, null, resolve));
  assert.equal(result.ok, true);
  const denied = await new Promise(resolve => listeners.message({
    action: "add_download", url: "file:///etc/passwd"
  }, null, resolve));
  assert.equal(denied.ok, false);
  assert.equal(callCount, 1);
}

async function firefox() {
  const listeners = {};
  let callCount = 0;
  const browser = {
    runtime: {
      onInstalled: {addListener: fn => listeners.installed = fn},
      onStartup: {addListener: fn => listeners.startup = fn},
      onMessage: {addListener: fn => listeners.message = fn},
      sendNativeMessage: async (host, request) => {
        callCount++;
        assert.equal(host, "com.jahidul.jdm");
        assert.equal(request.action, "add_download");
        return {ok: true, taskId: "test"};
      }
    },
    contextMenus: {
      removeAll: async () => {},
      create: () => {},
      onClicked: {addListener: fn => listeners.clicked = fn}
    },
    storage: {local: {set: async () => {}}},
    browserAction: {setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}}
  };
  const code = fs.readFileSync(path.join(base, "firefox", "background.js"), "utf8");
  vm.runInNewContext(code, {browser, URL});
  listeners.installed();
  const result = await listeners.message({
    action: "add_download", url: "https://example.com/file.zip"
  });
  assert.equal(result.ok, true);
  const denied = await listeners.message({
    action: "add_download", url: "javascript:alert(1)"
  });
  assert.equal(denied.ok, false);
  assert.equal(callCount, 1);
}

(async () => {
  for (const folder of ["chromium", "firefox"]) {
    const manifest = JSON.parse(fs.readFileSync(
        path.join(base, folder, "manifest.json"), "utf8"));
    assert.ok(manifest.permissions.includes("nativeMessaging"));
    assert.ok(manifest.permissions.includes("contextMenus"));
  }
  await chromium();
  await firefox();
  process.stdout.write("Browser extension messaging tests passed.\n");
})().catch(error => { console.error(error); process.exitCode = 1; });
