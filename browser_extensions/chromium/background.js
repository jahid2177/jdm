"use strict";

const HOST = "com.jahidul.jdm";
const MENU_LINK = "jdm-download-link";
const MENU_PAGE = "jdm-download-page";
const MENU_VIDEO = "jdm-download-video";

function isSupportedUrl(url) {
  try {
    const u = new URL(url);
    return (u.protocol === "http:" || u.protocol === "https:") &&
        !u.username && !u.password;
  } catch (_) {
    return false;
  }
}

function sendToHost(url, fileName = "") {
  return new Promise((resolve) => {
    if (!isSupportedUrl(url)) {
      resolve({ok: false, error: "Only HTTP/HTTPS links are supported"});
      return;
    }
    chrome.runtime.sendNativeMessage(
      HOST, {action: "add_download", url, fileName}, (response) => {
        const error = chrome.runtime.lastError?.message;
        resolve(error ? {ok: false, error} :
            (response || {ok: false, error: "No response from JDM"}));
      }
    );
  });
}

async function queueLink(url, fileName = "") {
  const result = await sendToHost(url, fileName);
  await chrome.storage.local.set({lastResult: result, lastUrl: url});
  await chrome.action.setBadgeBackgroundColor({color: result.ok ? "#167b43" : "#bd3030"});
  await chrome.action.setBadgeText({text: result.ok ? "OK" : "ERR"});
  return result;
}

function installMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({id: MENU_LINK, title: "Download link with JDM", contexts: ["link"]});
    chrome.contextMenus.create({id: MENU_PAGE, title: "Download page URL with JDM", contexts: ["page"]});
    chrome.contextMenus.create({id: MENU_VIDEO, title: "Download video with JDM", contexts: ["video"]});
  });
}

chrome.runtime.onInstalled.addListener(installMenus);
chrome.runtime.onStartup.addListener(installMenus);
chrome.contextMenus.onClicked.addListener((info, tab) => {
  const url = info.menuItemId === MENU_LINK ? info.linkUrl :
      info.menuItemId === MENU_VIDEO ? info.srcUrl :
      info.menuItemId === MENU_PAGE ? (info.pageUrl || tab?.url) : null;
  if (url) void queueLink(url);
});
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.action !== "add_download") return false;
  queueLink(message.url, message.fileName || "").then(sendResponse);
  return true;
});
