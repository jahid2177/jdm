"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function element(tagName, key, href, download = false) {
  return {
    tagName,
    getAttribute: name => name === key ? href :
        name === "download" && download ? "suggested.bin" : null,
    hasAttribute: name => name === "download" && download,
    currentSrc: undefined,
  };
}

for (const target of ["chromium", "firefox"]) {
  const code = fs.readFileSync(path.join(__dirname, "..",
      "browser_extensions", target, "popup.js"), "utf8");
  const fakeElements = [
    element("A", "href", "/archive.zip"),
    element("A", "href", "/archive.zip"), // Deduplicated.
    element("A", "href", "javascript:alert(1)"),
    element("A", "href", "https://user:pass@example.com/private.pdf"),
    element("A", "href", "/not-downloadable-page"),
    element("SOURCE", "src", "/video.m3u8"),
    element("A", "href", "/report", true),
  ];
  const noop = () => {};
  const document = {
    baseURI: "https://example.com/current",
    querySelectorAll: () => fakeElements,
    getElementById: () => ({addEventListener: noop, value: ""}),
  };
  const tabs = {
    query: (_options, callback) => callback ? callback([]) : Promise.resolve([]),
  };
  const mock = target === "chromium"
      ? {chrome: {tabs}}
      : {browser: {tabs}};
  const sandbox = vm.createContext({document, URL, Map, Array, ...mock});
  vm.runInContext(code, sandbox);
  const found = JSON.parse(JSON.stringify(
      vm.runInContext("collectDownloadCandidates()", sandbox)));
  assert.deepEqual(found.map(link => link.url), [
    "https://example.com/archive.zip",
    "https://example.com/video.m3u8",
    "https://example.com/report",
  ]);
  assert.equal(found[2].name, "suggested.bin");
}

console.log("On-demand browser download scanner tests passed.");
