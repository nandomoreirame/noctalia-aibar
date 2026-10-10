import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets
import "components"
import "components/ui"

// Both providers, independent of which one the bar is showing.
Item {
  id: root

  property var pluginApi: null

  readonly property var geometryPlaceholder: panelContainer
  readonly property bool allowAttach: true
  readonly property var main: pluginApi?.mainInstance ?? null

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
          busy: (root.main?.claude.inFlight ?? false) || (root.main?.grok.inFlight ?? false)
          enabled: !busy
          tooltipText: root.tr("panel.refresh")
          onClicked: root.main?.refresh()
        }
      }

      ProviderCard {
        provider: "claude"
        pluginApi: root.pluginApi
      }

      ProviderCard {
        provider: "grok"
        pluginApi: root.pluginApi
      }
    }
  }
}
