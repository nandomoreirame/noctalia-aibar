import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets
import "components"

// Both providers, independent of which one the bar is showing.
Item {
  id: root

  property var pluginApi: null

  readonly property var geometryPlaceholder: panelContainer
  readonly property bool allowAttach: true
  readonly property var main: pluginApi?.mainInstance ?? null

  property real contentPreferredWidth: 420 * Style.uiScaleRatio

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
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginM

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS

        NText {
          text: root.tr("panel.title")
          font.weight: Style.fontWeightSemiBold
          pointSize: Style.fontSizeL
          color: Color.mOnSurface
          Layout.fillWidth: true
        }

        NIconButton {
          icon: "refresh"
          tooltipText: root.tr("panel.refresh")
          Accessible.role: Accessible.Button
          Accessible.name: root.tr("panel.refresh")
          activeFocusOnTab: true
          colorBorder: activeFocus ? Color.mPrimary : Color.mOutline
          onClicked: root.main?.refresh()

          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              if (root.main)
                root.main.refresh();
              event.accepted = true;
            }
          }
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
