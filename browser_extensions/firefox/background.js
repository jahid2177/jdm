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

async function queueLink(url, fileName = "") {
  let result;
  if (!isSupportedUrl(url)) {
    result = {ok: false, error: "Only HTTP/HTTPS links are supported"};
  } else {
    try {
      result = await browser.runtime.sendNativeMessage(HOST,
          {action: "add_download", url, fileName});
    } catch (error) {
      result = {ok: false, error: error.message};
    }
  }
  await browser.storage.local.set({lastResult: result, lastUrl: url});
  await browser.browserAction.setBadgeBackgroundColor({color: result.ok ? "#167b43" : "#bd3030"});
  await browser.browserAction.setBadgeText({text: result.ok ? "OK" : "ERR"});
  return result;
}

function installMenus() {
  browser.contextMenus.removeAll().then(() => {
    browser.contextMenus.create({id: MENU_LINK, title: "Download link with JDM", contexts: ["link"]});
    browser.contextMenus.create({id: MENU_PAGE, title: "Download page URL with JDM", contexts: ["page"]});
    browser.contextMenus.create({id: MENU_VIDEO, title: "Download video with JDM", contexts: ["video"]});
  });
}
browser.runtime.onInstalled.addListener(installMenus);
browser.runtime.onStartup.addListener(installMenus);
browser.contextMenus.onClicked.addListener((info, tab) => {
  const url = info.menuItemId === MENU_LINK ? info.linkUrl :
      info.menuItemId === MENU_VIDEO ? info.srcUrl :
      info.menuItemId === MENU_PAGE ? (info.pageUrl || tab?.url) : null;
  if (url) void queueLink(url);
});
browser.runtime.onMessage.addListener((message) => {
  if (message?.action === "add_download") {
    return queueLink(message.url, message.fileName || "");
  }
});
