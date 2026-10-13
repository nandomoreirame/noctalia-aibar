import QtQuick 6.11
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI
import "utils/creds.js" as Creds
import "utils/claude.js" as Claude
import "utils/grok.js" as Grok
import "utils/poll.js" as Poll
import "utils/notify.js" as Notify
import "utils/format.js" as Format

// Services only. Views read state through pluginApi.mainInstance.
// Credential text is read inside the poll functions and the token is placed
// on the request header. It is never stored in a property, file or log.
Item {
  id: root

  property var pluginApi: null

  property var claude: Poll.createState()
  property var grok: Poll.createState()
  property var armed: ({})
  // Latest request per provider. Not a binding source; only guards late callbacks.
  property var requests: ({})
  property date clockNow: new Date()

  function setting(key) {
    const settings = pluginApi?.pluginSettings;
    if (settings && settings[key] !== undefined)
      return settings[key];
    const defaults = pluginApi?.manifest?.metadata?.defaultSettings;
    return defaults ? defaults[key] : undefined;
  }

  function tr(key, vars) {
    if (!pluginApi)
      return key;
    return vars ? pluginApi.tr(key, vars) : pluginApi.tr(key);
  }

  function windowLabel(snapshot, item) {
    if (item.id === "period") {
      const found = (snapshot.windows || []).find(w => w.id === "period");
      const kind = found && found.periodType === "monthly" ? "monthly" : "weekly";
      return tr("window.period-" + kind);
    }
    return tr("window." + item.id);
  }

  function onSnapshot(snapshot) {
    const result = Notify.crossings(snapshot, armed, setting("notifyThreshold"));
    armed = result.armed;
    const now = Date.now();
    for (let i = 0; i < result.fire.length; i++) {
      const item = result.fire[i];
      ToastService.showWarning(
        tr("notify.title", {
          provider: tr("provider." + item.provider),
          window: windowLabel(snapshot, item),
          n: Math.round(item.percent)
        }),
        tr("notify.body", { t: Format.countdown(item.end, now) })
      );
    }
  }

  // Usage data only, never a credential. Lets a blocked plan (whose CLI token
  // expired from disuse) still show its bars after a shell restart.
  function saveSnapshot(provider, snapshot) {
    if (provider === "claude")
      snapshotCache.claude = snapshot;
    else
      snapshotCache.grok = snapshot;
    snapshotFile.writeAdapter();
  }

  function restoreSnapshots() {
    claude = Poll.restore(claude, snapshotCache.claude);
    grok = Poll.restore(grok, snapshotCache.grok);
  }

  function applyResult(provider, kind, code, snapshot) {
    const now = Date.now();
    const next = snapshot ? Poll.succeed(provider === "claude" ? claude : grok, snapshot) : Poll.fail(provider === "claude" ? claude : grok, kind, code, now);
    if (provider === "claude")
      claude = next;
    else
      grok = next;
    if (snapshot) {
      onSnapshot(snapshot);
      saveSnapshot(provider, snapshot);
    }
  }

  // headers is a local list of pairs. Nothing in it is logged.
  function httpGet(provider, url, headers, parse) {
    // xhr.timeout is ignored by QML, so a hung request is dropped by
    // Poll.canRequest and aborted here when the next one replaces it.
    const xhr = new XMLHttpRequest();
    const previous = requests[provider];
    requests[provider] = xhr;
    if (previous)
      previous.abort();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE || root.requests[provider] !== xhr)
        return;
      root.requests[provider] = null;
      const status = xhr.status;
      if (status === 0) {
        Logger.w("aibar", provider, status);
        root.applyResult(provider, "network", 0, null);
        return;
      }
      if (status !== 200) {
        Logger.w("aibar", provider, status);
        root.applyResult(provider, "http", status, null);
        return;
      }
      const parsed = parse(xhr.responseText);
      if (!parsed.ok) {
        root.applyResult(provider, parsed.error || "parse", 0, null);
        return;
      }
      root.applyResult(provider, "", 0, parsed.snapshot);
    };
    xhr.open("GET", url);
    for (let i = 0; i < headers.length; i++)
      xhr.setRequestHeader(headers[i][0], headers[i][1]);
    xhr.send();
  }

  function pollClaude() {
    const now = Date.now();
    if (!Poll.canRequest(claude, now))
      return;
    const cred = Creds.claudeToken(claudeFile.text(), now);
    if (!cred.ok) {
      claude = Poll.fail(claude, cred.error, 0, now);
      return;
    }
    claude = Poll.begin(claude, now);
    const plan = cred.plan;
    httpGet("claude", Claude.API_URL, [
      ["Authorization", "Bearer " + cred.token],
      ["anthropic-beta", Claude.BETA],
      ["User-Agent", String(setting("claudeUserAgent") || "")],
      ["Accept", "application/json"]
    ], function (text) {
      return Claude.parseUsage(text, plan, Date.now());
    });
  }

  function pollGrok() {
    const now = Date.now();
    if (!Poll.canRequest(grok, now))
      return;
    const cred = Creds.grokKey(grokFile.text());
    if (!cred.ok) {
      grok = Poll.fail(grok, cred.error, 0, now);
      return;
    }
    grok = Poll.begin(grok, now);
    httpGet("grok", Grok.API_URL, [
      ["Authorization", "Bearer " + cred.key],
      ["X-XAI-Token-Auth", Grok.TOKEN_AUTH],
      ["Accept", "application/json"]
    ], function (text) {
      return Grok.parseBilling(text, Date.now());
    });
  }

  // Re-read the credential files instead of trusting the cached text: a CLI
  // login can replace the file in a way the watcher misses. onLoaded polls.
  function refresh() {
    claudeFile.reload();
    grokFile.reload();
  }

  function toggleBarProvider() {
    if (!pluginApi)
      return;
    pluginApi.pluginSettings.barProvider = setting("barProvider") === "grok" ? "claude" : "grok";
    pluginApi.saveSettings();
  }

  FileView {
    id: snapshotFile
    path: Settings.cacheDir + "aibar-snapshots.json"
    blockLoading: false
    printErrors: false
    onLoaded: root.restoreSnapshots()

    JsonAdapter {
      id: snapshotCache
      property var claude: null
      property var grok: null
    }
  }

  FileView {
    id: claudeFile
    path: (Quickshell.env("HOME") || "") + "/.claude/.credentials.json"
    blockLoading: false
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.pollClaude()
    onLoadFailed: root.pollClaude()
  }

  FileView {
    id: grokFile
    path: (Quickshell.env("HOME") || "") + "/.grok/auth.json"
    blockLoading: false
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.pollGrok()
    onLoadFailed: root.pollGrok()
  }

  Timer {
    // A missing setting must not become NaN (that interval spins).
    readonly property int minutes: {
      const value = Number(root.setting("pollMinutes"));
      return value === value ? value : 5;
    }
    interval: Math.max(2, minutes) * 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.clockNow = new Date()
  }

  IpcHandler {
    target: "plugin:aibar"

    function refresh(): void {
      root.refresh();
    }

    function toggle(): void {
      root.toggleBarProvider();
    }
  }
}
