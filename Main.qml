import QtQuick 6.11
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI
import "utils/accounts.js" as Accounts
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

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property var extraAccounts: Accounts.parseAccounts(setting("claudeAccounts"))
  readonly property var sources: Accounts.sources(extraAccounts)
  readonly property string barKey: Accounts.resolveKey(sources, String(setting("barProvider") || ""))
  // Request state per source key, replaced as a whole so bindings update.
  property var states: ({})
  // Logged account per Claude source ({ uuid, email } from its .claude.json).
  property var accounts: ({})
  // Credential FileView per Claude source key. Not a binding source.
  property var credFiles: ({})
  property var armed: ({})
  // Latest request per source. Not a binding source; only guards late callbacks.
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

  function stateOf(key) {
    return states[key] || Poll.createState();
  }

  function setState(key, s) {
    const next = Object.assign({}, states);
    next[key] = s;
    states = next;
  }

  function sourceOf(key) {
    for (let i = 0; i < sources.length; i++)
      if (sources[i].key === key)
        return sources[i];
    return null;
  }

  function accountUuid(key) {
    return accounts[key] ? accounts[key].uuid : "";
  }

  function accountEmail(key) {
    return accounts[key] ? accounts[key].email : "";
  }

  function cachedSnapshot(key) {
    const cache = { claude: snapshotCache.claude, grok: snapshotCache.grok, byAccount: snapshotCache.byAccount };
    return Accounts.cachedSnapshot(cache, key, accountUuid(key));
  }

  // A source's .claude.json was (re)read. claude-swap moves logins between
  // ~/.claude and the freeze dir, so the account behind a key can change.
  function syncAccount(key, text) {
    const info = Accounts.accountOf(text);
    const change = Accounts.accountChange(accountUuid(key), info ? info.uuid : "");
    if (change === "none")
      return;
    const next = Object.assign({}, accounts);
    next[key] = info;
    accounts = next;
    const current = stateOf(key);
    if (change === "adopt") {
      // The live snapshot already belongs to this account; a stale one may be
      // the pre-account cache, so the account's own cache replaces it.
      const cached = cachedSnapshot(key);
      if (current.snapshot && !current.stale)
        saveSnapshot(key, current.snapshot);
      else if (cached)
        setState(key, Object.assign({}, current, { snapshot: cached, stale: true }));
      return;
    }
    const pending = requests[key];
    requests[key] = null;
    if (pending)
      pending.abort();
    setState(key, Poll.restore(Poll.createState(), cachedSnapshot(key)));
    if (credFiles[key])
      pollClaude(key, credFiles[key]);
  }

  // "Claude Code", "Claude Code · Trabalho" or "Grok".
  function sourceName(key) {
    const source = sourceOf(key);
    const base = tr("provider." + (source ? source.provider : "claude"));
    return source && source.name ? base + " · " + source.name : base;
  }

  function windowLabel(snapshot, item) {
    if (item.id === "period") {
      const found = (snapshot.windows || []).find(w => w.id === "period");
      const kind = found && found.periodType === "monthly" ? "monthly" : "weekly";
      return tr("window.period-" + kind);
    }
    return tr("window." + item.id);
  }

  function onSnapshot(key, snapshot) {
    const result = Notify.crossings(snapshot, armed, setting("notifyThreshold"), key);
    armed = result.armed;
    const now = Date.now();
    for (let i = 0; i < result.fire.length; i++) {
      const item = result.fire[i];
      ToastService.showWarning(
        tr("notify.title", {
          provider: sourceName(key),
          window: windowLabel(snapshot, item),
          n: Math.round(item.percent)
        }),
        tr("notify.body", { t: Format.countdown(item.end, now) })
      );
    }
  }

  // Usage data only, never a credential. Lets a blocked plan (whose CLI token
  // expired from disuse) still show its bars after a shell restart.
  // Claude snapshots are kept per account id (see Accounts.cachedSnapshot).
  function saveSnapshot(key, snapshot) {
    const uuid = accountUuid(key);
    if (uuid) {
      const byAccount = Object.assign({}, snapshotCache.byAccount || {});
      byAccount[uuid] = snapshot;
      snapshotCache.byAccount = byAccount;
    } else if (key === "claude")
      snapshotCache.claude = snapshot;
    else if (key === "grok")
      snapshotCache.grok = snapshot;
    else
      return;
    snapshotFile.writeAdapter();
  }

  function restoreSnapshots() {
    const next = Object.assign({}, states);
    for (let i = 0; i < sources.length; i++) {
      const key = sources[i].key;
      next[key] = Poll.restore(stateOf(key), cachedSnapshot(key));
    }
    states = next;
  }

  function applyResult(key, kind, code, snapshot) {
    const now = Date.now();
    setState(key, snapshot ? Poll.succeed(stateOf(key), snapshot) : Poll.fail(stateOf(key), kind, code, now));
    if (snapshot) {
      onSnapshot(key, snapshot);
      saveSnapshot(key, snapshot);
    }
  }

  // headers is a local list of pairs. Nothing in it is logged.
  // account: the source's account id when the request started; an answer that
  // arrives after a swap belongs to the other account and is dropped.
  function httpGet(key, url, headers, parse, account) {
    // xhr.timeout is ignored by QML, so a hung request is dropped by
    // Poll.canRequest and aborted here when the next one replaces it.
    const xhr = new XMLHttpRequest();
    const previous = requests[key];
    requests[key] = xhr;
    if (previous)
      previous.abort();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE || root.requests[key] !== xhr)
        return;
      root.requests[key] = null;
      if (account && root.accountUuid(key) !== account)
        return;
      const status = xhr.status;
      if (status === 0) {
        Logger.w("aibar", key, status);
        root.applyResult(key, "network", 0, null);
        return;
      }
      if (status !== 200) {
        Logger.w("aibar", key, status);
        root.applyResult(key, "http", status, null);
        return;
      }
      const parsed = parse(xhr.responseText);
      if (!parsed.ok) {
        root.applyResult(key, parsed.error || "parse", 0, null);
        return;
      }
      root.applyResult(key, "", 0, parsed.snapshot);
    };
    xhr.open("GET", url);
    for (let i = 0; i < headers.length; i++)
      xhr.setRequestHeader(headers[i][0], headers[i][1]);
    xhr.send();
  }

  // file is the FileView holding the account's credentials.
  function pollClaude(key, file) {
    const now = Date.now();
    const current = stateOf(key);
    if (!Poll.canRequest(current, now))
      return;
    const cred = Creds.claudeToken(file.text(), now);
    if (!cred.ok) {
      setState(key, Poll.fail(current, cred.error, 0, now));
      return;
    }
    setState(key, Poll.begin(current, now));
    const plan = cred.plan;
    const account = accountUuid(key);
    httpGet(key, Claude.API_URL, [
      ["Authorization", "Bearer " + cred.token],
      ["anthropic-beta", Claude.BETA],
      ["User-Agent", String(setting("claudeUserAgent") || "")],
      ["Accept", "application/json"]
    ], function (text) {
      return Claude.parseUsage(text, plan, Date.now());
    }, account);
  }

  function pollGrok() {
    const now = Date.now();
    const current = stateOf("grok");
    if (!Poll.canRequest(current, now))
      return;
    const cred = Creds.grokKey(grokFile.text());
    if (!cred.ok) {
      setState("grok", Poll.fail(current, cred.error, 0, now));
      return;
    }
    setState("grok", Poll.begin(current, now));
    httpGet("grok", Grok.API_URL, [
      ["Authorization", "Bearer " + cred.key],
      ["X-XAI-Token-Auth", Grok.TOKEN_AUTH],
      ["Accept", "application/json"]
    ], function (text) {
      return Grok.parseBilling(text, Date.now());
    }, "");
  }

  // Re-read the credential files instead of trusting the cached text: a CLI
  // login can replace the file in a way the watcher misses. onLoaded polls.
  function refresh() {
    claudeFile.reload();
    claudeConfig.reload();
    grokFile.reload();
    const extra = extraFiles.instances;
    for (let i = 0; i < extra.length; i++)
      extra[i].reload();
  }

  function toggleBarProvider() {
    if (!pluginApi)
      return;
    pluginApi.pluginSettings.barProvider = Accounts.nextKey(sources, barKey);
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
      property var byAccount: ({})
    }
  }

  FileView {
    id: claudeFile
    path: root.home + "/.claude/.credentials.json"
    blockLoading: false
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.pollClaude("claude", claudeFile)
    onLoadFailed: root.pollClaude("claude", claudeFile)
    Component.onCompleted: root.credFiles["claude"] = claudeFile
  }

  // Read for oauthAccount only (which account is logged); it holds no token.
  FileView {
    id: claudeConfig
    path: Accounts.configPath("", root.home)
    blockLoading: false
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.syncAccount("claude", text())
  }

  // Credentials and account of each frozen Claude account (its config dir).
  Variants {
    id: extraFiles
    model: root.extraAccounts

    Scope {
      id: account
      required property var modelData

      function reload() {
        accountConfig.reload();
        accountFile.reload();
      }

      FileView {
        id: accountConfig
        path: Accounts.configPath(account.modelData.dir, root.home)
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.syncAccount(account.modelData.key, text())
      }

      FileView {
        id: accountFile
        path: Accounts.credPath(account.modelData.dir, root.home)
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.pollClaude(account.modelData.key, accountFile)
        onLoadFailed: root.pollClaude(account.modelData.key, accountFile)
        Component.onCompleted: root.credFiles[account.modelData.key] = accountFile
      }
    }
  }

  FileView {
    id: grokFile
    path: root.home + "/.grok/auth.json"
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
