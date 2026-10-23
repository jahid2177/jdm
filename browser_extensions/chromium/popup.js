"use strict";
const form = document.getElementById("form");
const status = document.getElementById("status");
const send = document.getElementById("send");

function showResult(result) {
  status.className = result?.ok ? "success" : "error";
  status.textContent = result?.ok ? "Added to JDM download queue." :
      "Cannot send: " + (result?.error || "unknown error") +
      ". Ensure JDM is open and the native host is registered.";
}

chrome.tabs.query({active: true, currentWindow: true}, (tabs) => {
  const url = tabs[0]?.url;
  if (url && /^https?:\/\//i.test(url)) document.getElementById("url").value = url;
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  send.disabled = true;
  status.className = "";
  status.textContent = "Sending to JDM...";
  chrome.runtime.sendMessage({
    action: "add_download",
    url: document.getElementById("url").value,
    fileName: document.getElementById("filename").value
  }, (result) => {
    send.disabled = false;
    showResult(chrome.runtime.lastError ?
        {ok: false, error: chrome.runtime.lastError.message} : result);
  });
});
