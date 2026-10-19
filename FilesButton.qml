import QtQuick
import Quickshell
import qs.Ui

BarWidget {
  id: root
  moduleName: "crmne.files"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰥨"
    tooltipText: "Find files"
    onPressed: function(button) { if (button === Qt.LeftButton) Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "crmne.files"]) }
  }
}
