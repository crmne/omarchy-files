import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  property string fontFamily: Style.font.menuFamily
  property string helper: ""
  property string path: ""
  property string searchRoot: ""
  property bool active: false
  property var result: ({})
  property int serial: 0
  function refresh() {
    serial++
    result = ({})
    if (reader.running) reader.running = false
    delay.restart()
  }
  onPathChanged: refresh()
  onSearchRootChanged: refresh()
  onActiveChanged: refresh()
  Timer {
    id: delay
    interval: 120
    onTriggered: {
      if (!root.active || !root.path) return
      if (reader.running) { restart(); return }
      reader.serial = root.serial
      reader.environment = {CRMNE_FILES_PATH: root.path, CRMNE_FILES_ROOT: root.searchRoot}
      reader.running = true
    }
  }
  Process {
    id: reader
    property int serial: 0
    command: ["timeout", "-k", "1", "3", root.helper, "preview"]
    stdout: StdioCollector { id: output }
    onExited: function(code) {
      if (serial !== root.serial || !root.active) return
      try {
        var reply = JSON.parse(output.text)
        root.result = reply.ok ? reply.result : {message: "Preview unavailable."}
      } catch (e) { root.result = {message: "Preview unavailable or exceeded its limits."} }
    }
  }
  Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Commons.Color.menu.text; opacity: 0.15 }
  Column {
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.lg
    spacing: Style.spacing.md
    Text { font.family: root.fontFamily; width: parent.width; text: root.result.name || "Preview"; textFormat: Text.PlainText; elide: Text.ElideMiddle; color: Commons.Color.menu.text; font.pixelSize: Style.font.heading }
    Text { font.family: root.fontFamily; width: parent.width; text: root.result.size !== undefined ? root.result.size.toLocaleString() + " bytes\n" + root.result.modified : ""; color: Commons.Color.menu.text; opacity: 0.65; font.pixelSize: Style.font.caption }
    Image { visible: root.result.kind === "image"; width: parent.width; height: Math.min(width, root.height - Style.space(120)); fillMode: Image.PreserveAspectFit; source: root.result.image || ""; sourceSize.width: 512; sourceSize.height: 512; asynchronous: true }
    Flickable {
      visible: root.result.kind === "text"
      width: parent.width; height: Math.max(0, root.height - y - Style.space(30)); clip: true
      contentHeight: contents.implicitHeight
      Text { font.family: root.fontFamily; id: contents; width: parent.width; text: root.result.text || ""; textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere; color: Commons.Color.menu.text;  font.pixelSize: Style.font.caption }
    }
    Text { font.family: root.fontFamily; width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.result.truncated ? "First 16 KiB shown." : root.result.message || (reader.running ? "Loading…" : ""); color: Commons.Color.menu.text; opacity: 0.65; font.pixelSize: Style.font.caption }
  }
}
