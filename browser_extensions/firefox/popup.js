"use strict";
const form = document.getElementById("form");
const status = document.getElementById("status");
const send = document.getElementById("send");

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
