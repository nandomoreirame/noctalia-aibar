import QtQuick
import Quickshell
import qs.Commons
import qs.Widgets
import qs.Services.UI
import "utils/pace.js" as Pace
import "utils/format.js" as Format

// Bar entry for the selected provider: percent, reset countdown and a progress bar.
Item {
  id: root

  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var main: pluginApi?.mainInstance ?? null
  readonly property string provider: main?.setting("barProvider") === "grok" ? "grok" : "claude"
  readonly property var usage: provider === "grok" ? main?.grok : main?.claude
  readonly property var win: Pace.primaryWindow(usage?.snapshot)
  readonly property string usageStatus: Pace.status(win, nowMs())
  readonly property bool barIsVertical: (Settings.data.bar.position || "top") === "left" || Settings.data.bar.position === "right"
  readonly property string iconName: provider === "grok" ? "brand-x" : "asterisk"
  readonly property string barLabel: Format.barText(win, nowMs())
  readonly property string providerName: tr("provider." + provider)
  readonly property color fill: usageStatus === "critical" ? Color.mError : usageStatus === "ahead" ? Color.mTertiary : Color.mPrimary
  readonly property real fraction: {
    const p = win && typeof win.percent === "number" ? win.percent : 0;
    return Math.min(100, Math.max(0, p)) / 100;
  }
  readonly property string tooltipText: {
    const lines = [];
    const windows = usage && usage.snapshot ? usage.snapshot.windows || [] : [];
    for (let i = 0; i < windows.length; i++)
      lines.push(windowLine(windows[i]));
    const err = errorText();
    if (err !== "")
      lines.push(err);
    return lines.join("\n");
  }

  function nowMs() {
    return main && main.clockNow ? main.clockNow.getTime() : Date.now();
  }

  function tr(key, vars) {
    if (!pluginApi)
      return key;
    return vars ? pluginApi.tr(key, vars) : pluginApi.tr(key);
  }

  function windowName(w) {
    return tr(Format.windowKey(w));
  }

  function windowLine(w) {
    const reset = Format.countdown(w.end, nowMs());
    const tail = reset !== "" ? " · " + tr("panel.resets", { t: reset }) : "";
    return windowName(w) + ": " + Format.percentText(w.percent) + tail;
  }

  function errorText() {
    const msg = Format.errorMessage(usage, provider, nowMs());
    return msg ? tr(msg.key, msg.vars) : "";
  }

  implicitWidth: barIsVertical ? Math.max(Style.capsuleHeight, Math.round(40 * Style.uiScaleRatio) + Style.marginS * 2) : contentRow.implicitWidth + Style.marginM * 2
  implicitHeight: barIsVertical ? verticalCol.implicitHeight + Style.marginS * 2 : Style.capsuleHeight

  Accessible.role: Accessible.Button
  Accessible.name: providerName + " " + barLabel
  activeFocusOnTab: true

  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      if (pluginApi)
        pluginApi.togglePanel(screen, root);
      event.accepted = true;
    }
  }

  Rectangle {
    anchors.centerIn: parent
    width: root.implicitWidth
    height: root.implicitHeight
    radius: Style.radiusL
    color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
    border.width: root.activeFocus ? Math.max(2, Style.borderS) : 0
    border.color: Color.mPrimary

    Row {
      id: contentRow
      anchors.centerIn: parent
      visible: !root.barIsVertical
      spacing: Style.marginS

      NIcon {
        icon: root.iconName
        applyUiScale: false
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
      }

      NText {
        text: root.barLabel
        pointSize: Style.barFontSize
        font.weight: Style.fontWeightSemiBold
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
        opacity: root.usage && root.usage.stale ? 0.6 : 1
      }

      Rectangle {
        width: Math.round(40 * Style.uiScaleRatio)
        height: Math.round(4 * Style.uiScaleRatio)
        radius: height / 2
        color: Qt.alpha(Color.mOnSurface, 0.15)
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          width: parent.width * root.fraction
          height: parent.height
          radius: parent.radius
          color: root.fill
        }
      }
    }

    Column {
      id: verticalCol
      anchors.centerIn: parent
      visible: root.barIsVertical
      spacing: Math.round(2 * Style.uiScaleRatio)

      NIcon {
        anchors.horizontalCenter: parent.horizontalCenter
        icon: root.iconName
        applyUiScale: false
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
      }

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.round(40 * Style.uiScaleRatio)
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
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton

    onEntered: if (root.tooltipText !== "") TooltipService.show(root, root.tooltipText, BarService.getTooltipDirection(root.screen?.name))
    onExited: TooltipService.hide(root)

    onClicked: mouse => {
      if (mouse.button === Qt.MiddleButton && root.main)
        root.main.toggleBarProvider();
      else if (root.pluginApi)
        root.pluginApi.togglePanel(root.screen, root);
    }
  }
}
