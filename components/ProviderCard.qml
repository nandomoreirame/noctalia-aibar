import QtQuick 6.11
import QtQuick.Layouts 6.11
import qs.Commons
import qs.Widgets
import "ui"
import "../utils/pace.js" as Pace
import "../utils/format.js" as Format

// One source (a Claude account or Grok): header, a row per window, extra usage or products, and the error.
Card {
  id: root

  property string sourceKey: "claude"
  property var pluginApi: null
  // Claude sources this card can switch between, and the one shown.
  property var accounts: []
  property int accountIndex: 0

  signal accountSelected(int index)

  readonly property var main: pluginApi?.mainInstance ?? null
  readonly property var source: main ? main.sourceOf(sourceKey) : null
  readonly property string provider: source?.provider ?? "claude"
  readonly property var usage: main ? main.stateOf(sourceKey) : null
  readonly property bool frozen: source?.frozen ?? false
  readonly property string email: main ? main.accountEmail(sourceKey) : ""
  readonly property var snapshot: Pace.project(usage ? usage.snapshot : null, nowMs())
  readonly property bool hasSnapshot: !!snapshot
  readonly property var exhaustedWindow: Pace.exhausted(snapshot, nowMs())
  readonly property string planLabel: {
    const plan = snapshot && provider === "claude" ? String(snapshot.plan || "") : "";
    if (plan === "")
      return "";
    return plan.charAt(0).toUpperCase() + plan.slice(1);
  }

  readonly property int padding: Math.round(12 * Style.uiScaleRatio)

  Layout.fillWidth: true
  implicitHeight: body.implicitHeight + padding * 2

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

  function detailLine(w) {
    const now = nowMs();
    const reset = Format.countdown(w.end, now);
    const resets = reset !== "" ? tr("panel.resets", { t: reset }) : "";
    const pace = Pace.pace(w, now);
    let paceText = "";
    if (pace.delta !== null) {
      const points = Math.abs(pace.delta);
      if (points <= 2)
        paceText = tr("pace.on");
      else if (pace.delta > 0)
        paceText = tr("pace.ahead", { n: points });
      else
        paceText = tr("pace.behind", { n: points });
    }
    if (resets !== "" && paceText !== "")
      return resets + " · " + paceText;
    return resets !== "" ? resets : paceText;
  }

  function errorText() {
    const msg = Format.errorMessage(usage, provider, nowMs(), frozen || !!exhaustedWindow);
    return msg ? tr(msg.key, msg.vars) : "";
  }

  function limitText() {
    const msg = Format.limitMessage(exhaustedWindow, nowMs());
    return msg ? tr(msg.key, msg.vars) : "";
  }

  function extraText() {
    return Format.moneyText(snapshot ? snapshot.extra : null, tr("format.decimal"));
  }

  Column {
    id: body
    x: root.padding
    y: root.padding
    width: parent.width - root.padding * 2
    spacing: Math.round(8 * Style.uiScaleRatio)

    RowLayout {
      width: parent.width
      spacing: Style.marginS

      NIcon {
        icon: root.provider === "grok" ? "brand-x" : "asterisk"
        applyUiScale: false
        color: Color.mOnSurface
      }

      NText {
        // The badge and the email tell accounts apart; the bar tooltip keeps the full name.
        text: root.tr("provider." + root.provider)
        font.weight: Style.fontWeightSemiBold
        pointSize: Style.fontSizeM
        color: Color.mOnSurface
      }

      NText {
        visible: root.planLabel !== ""
        text: root.planLabel
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
      }

      Item {
        Layout.fillWidth: true
      }

      NText {
        // A frozen account's last status is the point, so its age stays visible.
        visible: root.hasSnapshot && (root.frozen || !(root.usage && root.usage.stale))
        text: {
          const fetchedAt = root.snapshot ? root.snapshot.fetchedAt : root.nowMs();
          if (Format.minutesAgo(fetchedAt, root.nowMs()) === 0)
            return root.tr("panel.updated-now");
          return root.tr("panel.updated", { t: Format.ago(fetchedAt, root.nowMs()) });
        }
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
      }

      Rectangle {
        visible: root.frozen
        radius: height / 2
        color: Qt.alpha(Color.mPrimary, 0.18)
        implicitWidth: frozenLabel.implicitWidth + Style.marginS * 2
        implicitHeight: frozenLabel.implicitHeight + Math.round(2 * Style.uiScaleRatio)

        NText {
          id: frozenLabel
          anchors.centerIn: parent
          text: root.tr("panel.frozen")
          pointSize: Style.fontSizeXS
          color: Color.mPrimary
        }
      }

      Rectangle {
        visible: !root.frozen && !!(root.usage && root.usage.stale)
        radius: height / 2
        color: Qt.alpha(Color.mError, 0.18)
        implicitWidth: staleLabel.implicitWidth + Style.marginS * 2
        implicitHeight: staleLabel.implicitHeight + Math.round(2 * Style.uiScaleRatio)

        NText {
          id: staleLabel
          anchors.centerIn: parent
          text: root.tr("panel.stale")
          pointSize: Style.fontSizeXS
          color: Color.mError
        }
      }
    }

    RowLayout {
      visible: root.email !== "" || root.accounts.length > 1
      width: parent.width
      spacing: Style.marginS

      NText {
        Layout.fillWidth: true
        text: root.email
        elide: Text.ElideRight
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
      }

      // "Ativa · Congelada": small text switch, the shown account in primary.
      Repeater {
        model: root.accounts.length > 1 ? root.accounts : []

        RowLayout {
          id: switchItem
          required property var modelData
          required property int index
          readonly property bool current: index === root.accountIndex
          spacing: Style.marginS

          NText {
            visible: switchItem.index > 0
            text: "·"
            pointSize: Style.fontSizeXS
            color: Color.mOnSurfaceVariant
          }

          NText {
            id: switchLabel
            text: switchItem.modelData.frozen ? switchItem.modelData.name : root.tr("panel.active")
            pointSize: Style.fontSizeXS
            font.weight: switchItem.current ? Style.fontWeightSemiBold : Style.fontWeightRegular
            font.underline: switchMouse.containsMouse || activeFocus
            color: switchItem.current ? Color.mPrimary : Color.mOnSurfaceVariant
            activeFocusOnTab: true

            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.checked: switchItem.current

            Keys.onPressed: function (event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                root.accountSelected(switchItem.index);
                event.accepted = true;
              }
            }

            MouseArea {
              id: switchMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.accountSelected(switchItem.index)
            }
          }
        }
      }
    }

    NText {
      visible: !root.hasSnapshot && root.errorText() === ""
      width: parent.width
      text: root.tr("panel.no-data")
      color: Color.mOnSurfaceVariant
      pointSize: Style.fontSizeS
    }

    Column {
      visible: root.hasSnapshot
      width: parent.width
      spacing: Style.marginS

      Repeater {
        model: root.snapshot ? root.snapshot.windows || [] : []

        UsageRow {
          required property var modelData
          width: body.width
          label: root.windowName(modelData)
          percent: modelData.percent
          status: Pace.status(modelData, root.nowMs())
          detail: root.detailLine(modelData)
        }
      }

      UsageRow {
        visible: !!(root.snapshot && root.snapshot.extra)
        width: parent.width
        label: root.tr("window.extra")
        percent: root.snapshot && root.snapshot.extra ? root.snapshot.extra.percent : null
        rightText: root.extraText()
        status: root.snapshot && root.snapshot.extra && root.snapshot.extra.percent >= 90 ? "critical" : "ok"
      }

      Repeater {
        model: root.snapshot && root.provider === "grok" ? root.snapshot.products || [] : []

        RowLayout {
          required property var modelData
          width: body.width

          Accessible.role: Accessible.StaticText
          Accessible.name: modelData.name + " " + Format.percentText(modelData.percent)

          NText {
            text: modelData.name
            Layout.fillWidth: true
            elide: Text.ElideRight
            pointSize: Style.fontSizeXS
            color: Color.mOnSurfaceVariant
          }

          NText {
            text: Format.percentText(modelData.percent)
            pointSize: Style.fontSizeXS
            color: Color.mOnSurfaceVariant
          }
        }
      }
    }

    RowLayout {
      visible: root.limitText() !== ""
      width: parent.width
      spacing: Style.marginS

      NIcon {
        icon: "hourglass"
        applyUiScale: false
        color: Color.mError
      }

      NText {
        Layout.fillWidth: true
        text: root.limitText()
        wrapMode: Text.WordWrap
        pointSize: Style.fontSizeS
        color: Color.mError
      }
    }

    RowLayout {
      // Under the rows when a stale snapshot still has an error, and in
      // place of the rows when there is no snapshot.
      visible: root.errorText() !== ""
      width: parent.width
      spacing: Style.marginS

      NIcon {
        icon: "alert-triangle"
        applyUiScale: false
        color: Color.mError
      }

      NText {
        Layout.fillWidth: true
        text: root.errorText()
        wrapMode: Text.WordWrap
        pointSize: Style.fontSizeS
        color: Color.mError
      }
    }
  }
}
