// Passes each tab's media state to the native host, and its commands back to the tab.
const HOST = "com.github.heditrigui.dynamic_island";
const RETRY_MS = 5000;

const tabs = new Map(); // tab id -> Map(frame id -> { port, state, updated })
let host = null;

function mainFrame(frames) {
  const reporting = [...frames.values()].filter(frame => frame.state);
  const playing = reporting.filter(frame => frame.state.playing);
  const newest = list => list.reduce((a, b) => (b.updated > a.updated ? b : a));
  return playing.length ? newest(playing) : reporting.length ? newest(reporting) : null;
}

function publish(tabId) {
  if (!host) return;
  const frames = tabs.get(tabId);
  const frame = frames && mainFrame(frames);
  host.postMessage({ tab: tabId, state: frame ? frame.state : null });
}

function connectHost() {
  if (host) return;
  host = chrome.runtime.connectNative(HOST);
  host.onMessage.addListener(({ tab, command, position }) => {
    const frames = tabs.get(tab);
    const frame = frames && mainFrame(frames);
    if (frame) frame.port.postMessage({ command, position });
  });
  host.onDisconnect.addListener(() => {
    console.warn("Native host disconnected:", chrome.runtime.lastError && chrome.runtime.lastError.message);
    host = null;
    setTimeout(connectHost, RETRY_MS);
  });
  for (const tabId of tabs.keys()) publish(tabId);
}

chrome.runtime.onConnect.addListener(port => {
  const tabId = port.sender.tab && port.sender.tab.id;
  if (tabId === undefined) return;
  const frameId = port.sender.frameId;
  if (!tabs.has(tabId)) tabs.set(tabId, new Map());
  const frames = tabs.get(tabId);
  frames.set(frameId, { port, state: null, updated: 0 });

  port.onMessage.addListener(({ state }) => {
    frames.set(frameId, { port, state, updated: Date.now() });
    connectHost();
    publish(tabId);
  });
  port.onDisconnect.addListener(() => {
    if (frames.get(frameId) && frames.get(frameId).port === port) frames.delete(frameId);
    if (frames.size === 0) tabs.delete(tabId);
    publish(tabId);
  });
});

// Pages that were already open have no content script until they are reloaded.
chrome.runtime.onInstalled.addListener(async () => {
  for (const tab of await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] }))
    chrome.scripting
      .executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["content.js"] })
      .catch(() => {});
});

connectHost();
