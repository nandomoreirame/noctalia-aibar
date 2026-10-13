import QtQuick 6.11
import QtQuick.Layouts 6.11
import qs.Commons
import qs.Widgets
import "../utils/format.js" as Format

// One limit: label, percent, progress bar, and a dim reset/pace line.
Item {
  id: root

  property string label: ""
  property var percent: null
  property string rightText: ""
  property string detail: ""
  property string status: "ok"

  readonly property string valueText: rightText !== "" ? rightText : Format.percentText(percent)
  readonly property color fill: status === "critical" ? Color.mError : status === "ahead" ? Color.mTertiary : Color.mPrimary
  readonly property real fraction: {
    const p = typeof percent === "number" ? percent : 0;
    return Math.min(100, Math.max(0, p)) / 100;
  }

  implicitHeight: column.implicitHeight
  height: implicitHeight

  Accessible.role: Accessible.StaticText
  Accessible.name: label + " " + valueText

  Column {
    id: column
    width: parent.width
    spacing: Math.round(2 * Style.uiScaleRatio)

    RowLayout {
      width: parent.width

      NText {
        text: root.label
        Layout.fillWidth: true
        elide: Text.ElideRight
        pointSize: Style.fontSizeS
        color: Color.mOnSurface
      }

      NText {
        text: root.valueText
        pointSize: Style.fontSizeS
        font.weight: Style.fontWeightSemiBold
        color: Color.mOnSurface
      }
    }

    Rectangle {
      width: parent.width
      height: Math.round(4 * Style.uiScaleRatio)
      radius: height / 2
      color: Qt.alpha(Color.mOnSurface, 0.15)

      Rectangle {
        width: parent.width * root.fraction
        height: parent.height
        radius: parent.radius
        color: root.fill
      }
    }

    NText {
      visible: root.detail !== ""
      width: parent.width
      text: root.detail
      wrapMode: Text.WordWrap
      pointSize: Style.fontSizeXS
      color: Color.mOnSurfaceVariant
    }
  }
}
