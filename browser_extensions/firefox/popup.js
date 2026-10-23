"use strict";
const form = document.getElementById("form");
const status = document.getElementById("status");
const send = document.getElementById("send");
const scan = document.getElementById("scan");
const results = document.getElementById("results");

function collectDownloadCandidates() {
  const matches = new Map();
  const elements = document.querySelectorAll(
      "a[href], video[src], audio[src], source[src]");
  for (const element of Array.from(elements).slice(0, 2500)) {
    const raw = element.getAttribute("href") || element.currentSrc ||
        element.getAttribute("src");
    if (!raw) continue;
    try {
      const url = new URL(raw, document.baseURI);
      if (!["http:", "https:"].includes(url.protocol) ||
          url.username || url.password) continue;
      const downloadable = /\.(?:zip|rar|7z|pdf|exe|msi|apk|iso|mp4|mkv|mov|webm|mp3|m4a|flac|ts|m3u8|mpd)(?:$|[?#])/i
          .test(url.href) || element.hasAttribute("download") ||
          ["VIDEO", "AUDIO", "SOURCE"].includes(element.tagName);
      if (!downloadable || matches.has(url.href)) continue;
      matches.set(url.href, {url: url.href,
        name: (element.getAttribute("download") || "").slice(0, 120)});
    } catch (_) { /* Skip broken and unsupported links. */ }
    if (matches.size >= 40) break;
  }
  return Array.from(matches.values());
}

function renderCandidates(links) {
  results.replaceChildren();
  if (!links.length) {
    results.textContent = "No supported downloadable links found on this page.";
    return;
  }
  for (const link of links) {
    const row = document.createElement("div");
    row.className = "candidate";
    const label = document.createElement("div");
    label.textContent = link.url;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Add this link to JDM";
    button.addEventListener("click", async () => {
      button.disabled = true;
      try {
        showResult(await browser.runtime.sendMessage({action: "add_download",
          url: link.url, fileName: link.name || ""}));
      } catch (error) {
        showResult({ok: false, error: error.message});
      } finally {
        button.disabled = false;
      }
    });
    row.append(label, button);
    results.append(row);
  }
}

scan.addEventListener("click", async () => {
  scan.disabled = true;
  results.textContent = "Scanning current page...";
  try {
    const tabs = await browser.tabs.query({active: true, currentWindow: true});
    const tabId = tabs[0]?.id;
    if (!Number.isInteger(tabId)) throw new Error("No active tab");
    const injected = await browser.tabs.executeScript(tabId, {
      code: "(" + collectDownloadCandidates.toString() + ")()"
    });
    renderCandidates(injected[0] || []);
  } catch (error) {
    results.textContent = "Cannot scan this page: " + error.message;
  } finally {
    scan.disabled = false;
  }
});

browser.tabs.query({active: true, currentWindow: true}).then((tabs) => {
  const url = tabs[0]?.url;
  if (url && /^https?:\/\//i.test(url)) document.getElementById("url").value = url;
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  send.disabled = true;
  status.className = "";
  status.textContent = "Sending to JDM...";
  try {
    const result = await browser.runtime.sendMessage({
      action: "add_download",
      url: document.getElementById("url").value,
      fileName: document.getElementById("filename").value
    });
    status.className = result?.ok ? "success" : "error";
    status.textContent = result?.ok ? "Added to JDM download queue." :
        "Cannot send: " + (result?.error || "unknown error") +
        ". Ensure JDM is open and the native host is registered.";
  } catch (error) {
    status.className = "error";
    status.textContent = "Cannot send: " + error.message;
  } finally {
    send.disabled = false;
  }
});
