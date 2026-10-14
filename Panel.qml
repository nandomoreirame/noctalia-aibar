import QtQuick 6.11
import QtQuick.Layouts 6.11
import qs.Commons
import qs.Widgets
import "components"
import "components/ui"

// Every source, independent of which one the bar is showing.
Item {
  id: root

  property var pluginApi: null

  readonly property var geometryPlaceholder: panelContainer
  readonly property bool allowAttach: true
  readonly property var main: pluginApi?.mainInstance ?? null

  readonly property var claudeSources: main ? main.sources.filter(s => s.provider === "claude") : []
  readonly property var otherSources: main ? main.sources.filter(s => s.provider !== "claude") : []
  property int claudeTab: 0
  readonly property int claudeIndex: Math.max(0, Math.min(claudeTab, claudeSources.length - 1))

  readonly property int panelMargin: Math.round(10 * Style.uiScaleRatio)

  property real contentPreferredWidth: 380 * Style.uiScaleRatio
  // Sized to the cards; without it SmartPanel falls back to its tall default.
  property real contentPreferredHeight: layout.implicitHeight + panelMargin * 2

  anchors.fill: parent

  function tr(key, vars) {
    if (!pluginApi)
      return key;
    return vars ? pluginApi.tr(key, vars) : pluginApi.tr(key);
  }

  Rectangle {
    id: panelContainer
    anchors.fill: parent
    color: "transparent"

    ColumnLayout {
      id: layout
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: root.panelMargin
      spacing: Math.round(8 * Style.uiScaleRatio)

      RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Math.round(4 * Style.uiScaleRatio)
        spacing: Style.marginS

        NText {
          text: root.tr("panel.title")
          font.weight: Style.fontWeightSemiBold
          pointSize: Style.fontSizeM
          color: Color.mOnSurface
          Layout.fillWidth: true
        }

        PillButton {
          icon: "refresh"
          busy: root.main ? root.main.sources.some(s => root.main.stateOf(s.key).inFlight) : false
          enabled: !busy
          tooltipText: root.tr("panel.refresh")
          onClicked: root.main?.refresh()
        }
      }

      // Claude accounts share one card, switched inside it. The panel is rebuilt
      // on open, so it starts on the active account.
      ProviderCard {
        visible: root.claudeSources.length > 0
        sourceKey: root.claudeSources.length > 0 ? root.claudeSources[root.claudeIndex].key : "claude"
        accounts: root.claudeSources
        accountIndex: root.claudeIndex
        pluginApi: root.pluginApi
        onAccountSelected: index => root.claudeTab = index
      }

      Repeater {
        model: root.otherSources

        ProviderCard {
          required property var modelData
          sourceKey: modelData.key
          pluginApi: root.pluginApi
        }
      }
    }
  }
}
