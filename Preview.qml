import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import qs.Commons as Commons

Item {
  id: root
  property string fontFamily: Style.font.menuFamily
  property string helper: ""
  property string path: ""
  property string searchRoot: ""
  property bool active: false
  property var result: ({})
  property var cache: ({})
  property var cacheOrder: []
  function cacheKey() { return JSON.stringify([searchRoot, path, page, position]) }
  function remember(key, value) {
    if (!value.fingerprint) return
    var entries = Object.assign({}, cache)
    var order = cacheOrder.filter(function(x) { return x !== key })
    entries[key] = value
    order.push(key)
    while (order.length > 8 || JSON.stringify(entries).length > 4 * 1024 * 1024) {
      delete entries[order.shift()]
      if (!order.length) break
    }
    cache = entries; cacheOrder = order
  }
  function escaped(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;").replace(/ /g, "&nbsp;").replace(/\t/g, "&nbsp;&nbsp;&nbsp;&nbsp;").replace(/\n/g, "<br>")
  }
  function highlighted() {
    // Only generated font tags are markup. Every character from the file is escaped.
    return (result.tokens || []).map(function(token) {
      var color = /^#[0-9a-f]{6}$/i.test(token[2] || "") ? token[2] : Commons.Color.menu.text
      return "<font color=\"" + color + "\">" + root.escaped(token[1]) + "</font>"
    }).join("")
  }
  property int serial: 0
  property int page: 1
  property real position: 0
  property string playbackError: ""
  property bool stoppingAudio: false
  function stamp(seconds) {
    seconds = Math.max(0, Math.floor(seconds || 0))
    return Math.floor(seconds / 60) + ":" + (seconds % 60 < 10 ? "0" : "") + seconds % 60
  }
  function stopAudio() {
    stoppingAudio = true
    audio.running = false
  }
  function playAudio() {
    if (!root.active || audio.running || !root.result.audio) return
    playbackError = ""
    stoppingAudio = false
    audio.environment = {CRMNE_FILES_PATH: path, CRMNE_FILES_ROOT: searchRoot, CRMNE_FILES_POSITION: String(position)}
    audio.running = true
  }
  function seek(value) {
    stopAudio()
    position = Math.max(0, Math.min(value, Math.max(0, (result.duration || 0) - 0.1)))
    if (result.kind === "video") refresh(false)
  }
  function refresh(reset) {
    stopAudio()
    if (reset !== false) { page = 1; position = 0; playbackError = "" }
    serial++
    result = ({})
    if (reader.running) reader.running = false
    delay.restart()
  }
  onPathChanged: refresh()
  onSearchRootChanged: refresh()
  onActiveChanged: { if (!active) { cache = ({}); cacheOrder = [] }; refresh() }
  Timer {
    id: delay
    interval: /\.(pdf|mp4|mov|mkv|webm|avi|docx|xlsx|pptx|odt|zip|7z|rar)$/i.test(root.path) ? 120 : 40
    onTriggered: {
      if (!root.active || !root.path) return
      if (reader.running) { restart(); return }
      reader.serial = root.serial
      reader.key = root.cacheKey()
      var cached = root.cache[reader.key]
      reader.environment = {CRMNE_FILES_PATH: root.path, CRMNE_FILES_ROOT: root.searchRoot, CRMNE_FILES_PAGE: String(root.page), CRMNE_FILES_POSITION: String(root.position), CRMNE_FILES_FINGERPRINT: cached ? cached.fingerprint : ""}
      reader.running = true
    }
  }
  Process {
    id: reader
    objectName: "previewDecoder"
    property string key: ""
    property int serial: 0
    command: ["timeout", "-k", "1", "8", root.helper, "preview"]
    stdout: StdioCollector { id: output }
    onExited: function(code) {
      if (serial !== root.serial || !root.active) return
      try {
        var reply = JSON.parse(output.text)
        if (reply.ok) {
          root.result = reply.result.unchanged && root.cache[key] ? root.cache[key] : reply.result
          root.remember(key, root.result)
        } else root.result = {message: reply.error || "Preview unavailable."}
      } catch (e) { root.result = {message: "Preview unavailable or exceeded its limits."} }
    }
  }
  Process {
    id: audio
    objectName: "previewAudio"
    command: ["timeout", "-k", "1", "40", root.helper, "play"]
    stdout: StdioCollector { id: playbackOutput }
    onExited: function(code) {
      if (code !== 0 && root.active && !root.stoppingAudio) root.playbackError = "Audio preview could not be played."
    }
  }
  Component.onDestruction: stopAudio()
  Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Commons.Color.menu.text; opacity: 0.15 }
  Column {
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.lg
    spacing: Style.spacing.md
    Text { font.family: root.fontFamily; width: parent.width; text: root.result.name || "Preview"; textFormat: Text.PlainText; elide: Text.ElideMiddle; color: Commons.Color.menu.text; font.pixelSize: Style.font.heading }
    Text { font.family: root.fontFamily; width: parent.width; text: root.result.size !== undefined ? root.result.size.toLocaleString() + " bytes\n" + root.result.modified : ""; color: Commons.Color.menu.text; opacity: 0.65; font.pixelSize: Style.font.caption }
    Image { visible: !!root.result.image; width: parent.width; height: Math.min(width, root.height - Style.space(230)); fillMode: Image.PreserveAspectFit; source: root.result.image || ""; sourceSize.width: 512; sourceSize.height: 512; asynchronous: true }
    Row {
      visible: root.result.kind === "pdf"
      spacing: Style.spacing.sm
      Button { fontFamily: root.fontFamily; text: "‹"; enabled: root.page > 1; onClicked: { root.page--; root.refresh(false) } }
      Text { font.family: root.fontFamily; text: "Page " + root.page + " / " + (root.result.pages || "?"); color: Commons.Color.menu.text; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
      Button { fontFamily: root.fontFamily; text: "›"; enabled: root.page < (root.result.pages || 1); onClicked: { root.page++; root.refresh(false) } }
    }
    Column {
      visible: root.result.kind === "audio" || root.result.kind === "video"
      width: parent.width
      spacing: Style.spacing.sm
      Text { font.family: root.fontFamily; text: root.stamp(root.position) + " / " + root.stamp(root.result.duration); color: Commons.Color.menu.text; font.pixelSize: Style.font.body }
      PanelSlider {
        width: parent.width
        minimum: 0; maximum: Math.max(1, root.result.duration || 0); value: root.position; step: 1
        enabled: (root.result.duration || 0) > 0 && !audio.running
        onReleased: function(value) { root.seek(value) }
      }
      Button {
        visible: root.result.audio === true
        fontFamily: root.fontFamily
        text: audio.running ? "Stop audio" : "Play audio (up to 30 s)"
        onClicked: audio.running ? root.stopAudio() : root.playAudio()
      }
      Text { font.family: root.fontFamily; width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.playbackError || (root.result.kind === "video" ? "Drag to preview another frame. Enter opens the full video." : "Playback starts only when you press Play."); color: Commons.Color.menu.text; opacity: 0.65; font.pixelSize: Style.font.caption }
    }
    Flickable {
      visible: root.result.kind === "text"
      width: parent.width; height: Math.max(0, root.height - y - Style.space(30)); clip: true
      Rectangle { parent: contents.parent; width: parent.width; height: Math.max(parent.height, contents.implicitHeight); color: /^#[0-9a-f]{6}$/i.test(root.result.background || "") ? root.result.background : "transparent"; z: -1 }
      contentHeight: contents.implicitHeight
      Text { font.family: root.fontFamily; id: contents; width: parent.width; text: root.result.tokens ? root.highlighted() : root.result.text || ""; textFormat: root.result.tokens ? Text.StyledText : Text.PlainText; wrapMode: Text.WrapAnywhere; color: Commons.Color.menu.text;  font.pixelSize: Style.font.caption }
    }
    Text { font.family: root.fontFamily; width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: root.result.truncated ? "First 16 KiB shown." : root.result.message || (reader.running ? "Loading…" : ""); color: Commons.Color.menu.text; opacity: 0.65; font.pixelSize: Style.font.caption }
  }
}
