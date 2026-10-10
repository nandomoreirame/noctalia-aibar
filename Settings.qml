import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

// Plugin settings. Noctalia calls saveSettings() when the dialog is confirmed.
ColumnLayout {
  id: root

  property var pluginApi: null

  property string barProvider: "claude"
  property int pollMinutes: 5
  property int notifyThreshold: 97
  property string claudeUserAgent: ""

  spacing: Style.marginM

  function tr(key) {
    return pluginApi ? pluginApi.tr(key) : key;
  }

  function value(key) {
    const settings = pluginApi?.pluginSettings ?? {};
    const defaults = pluginApi?.manifest?.metadata?.defaultSettings ?? {};
    return settings[key] === undefined ? defaults[key] : settings[key];
  }

  function loadSettings() {
    barProvider = String(value("barProvider") || "claude");
    const minutes = Number(value("pollMinutes"));
    pollMinutes = minutes === minutes ? minutes : 5;
    const threshold = Number(value("notifyThreshold"));
    notifyThreshold = threshold === threshold ? threshold : 97;
    claudeUserAgent = String(value("claudeUserAgent") || "");
  }

  function saveSettings() {
    if (!pluginApi)
      return;
    const saved = pluginApi.pluginSettings;
    saved.barProvider = barProvider;
    saved.pollMinutes = pollMinutes;
    saved.notifyThreshold = notifyThreshold;
    saved.claudeUserAgent = claudeUserAgent.trim();
    pluginApi.saveSettings();
  }

  onPluginApiChanged: if (pluginApi) loadSettings()
  Component.onCompleted: if (pluginApi) loadSettings()

  NComboBox {
    label: root.tr("settings.bar-provider")
    description: root.tr("settings.bar-provider-desc")
    model: [
      { key: "claude", name: root.tr("provider.claude") },
      { key: "grok", name: root.tr("provider.grok") }
    ]
    currentKey: root.barProvider
    onSelected: key => root.barProvider = key
  }

  NSpinBox {
    label: root.tr("settings.poll")
    from: 2
    to: 60
    value: root.pollMinutes
    suffix: " min"
    onValueChanged: root.pollMinutes = value
  }

  NSpinBox {
    label: root.tr("settings.threshold")
    description: root.tr("settings.threshold-desc")
    from: 0
    to: 100
    value: root.notifyThreshold
    onValueChanged: root.notifyThreshold = value
  }

  NTextInput {
    Layout.fillWidth: true
    label: root.tr("settings.user-agent")
    description: root.tr("settings.user-agent-desc")
    text: root.claudeUserAgent
    onTextChanged: root.claudeUserAgent = text
  }
}
