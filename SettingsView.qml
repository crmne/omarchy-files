import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ui" as Fields

FocusScope {
  id: root
  property string fontFamily: Style.font.menuFamily
  property var preferences: ({root: Quickshell.env("HOME"), excludes: ["go", "Android"], shortcut: "SUPER + CTRL + ALT + SPACE", preview: true})
  property string helper: ""
  property string message: ""
  readonly property bool saving: writer.running
  property bool applyShortcut: false
  property bool previewEnabled: true
  signal back()
  signal saved(var preferences)
  signal rebuild()
  function reset() {
    folder.text = preferences.root
    excludes.text = preferences.excludes.join(", ")
    shortcut.text = preferences.shortcut
    applyShortcut = false
    previewEnabled = preferences.preview
    message = ""
    folder.forceActiveFocus()
  }
  Keys.onEscapePressed: root.back()
  function save() {
    if (writer.running) return
    var payload = {root: folder.text, excludes: excludes.text.split(",").map(function(x) { return x.trim() }).filter(function(x) { return x.length }), shortcut: shortcut.text, preview: previewEnabled, applyShortcut: applyShortcut}
    writer.payload = JSON.stringify(payload)
    writer.running = true
  }
  Process {
    id: writer
    property string payload: ""
    command: [root.helper, "save"]
    stdinEnabled: true
    onStarted: { write(payload); stdinEnabled = false }
    stdout: StdioCollector { id: output }
    onExited: function() {
      stdinEnabled = true
      try {
        var response = JSON.parse(output.text)
        if (!response.ok) { root.message = response.error; return }
        root.preferences = response.result
        root.applyShortcut = false
        root.message = "Settings saved."
        root.saved(response.result)
      } catch (e) { root.message = "Could not save settings." }
    }
  }
  Flickable {
    anchors.fill: parent
    contentHeight: form.height
    clip: true
    Column {
      id: form
      width: parent.width
      spacing: Style.spacing.md
      Row {
        spacing: Style.spacing.md
        Button { fontFamily: root.fontFamily; text: "‹ Back to search"; onClicked: root.back() }
        Text { font.family: root.fontFamily; text: "Files settings"; color: Commons.Color.menu.text; font.pixelSize: Style.font.heading }
      }
      Text { font.family: root.fontFamily; text: "Search location"; color: Commons.Color.menu.text; font.pixelSize: Style.font.body }
      Fields.KeyField { font.family: root.fontFamily; id: folder; objectName: "searchLocation"; width: parent.width; maximumLength: 2048 }
      Text { font.family: root.fontFamily; text: "Excluded folder names or patterns (comma separated)"; color: Commons.Color.menu.text; font.pixelSize: Style.font.body }
      Fields.KeyField { font.family: root.fontFamily; id: excludes; objectName: "excludedFolders"; width: parent.width; maximumLength: 4096 }
      Text { font.family: root.fontFamily; text: "Opening shortcut"; color: Commons.Color.menu.text; font.pixelSize: Style.font.body }
      Fields.KeyField { font.family: root.fontFamily; id: shortcut; objectName: "openingShortcut"; width: parent.width; maximumLength: 100 }
      Toggle { fontFamily: root.fontFamily; width: parent.width; label: "Apply shortcut to Hyprland"; checked: root.applyShortcut; onClicked: root.applyShortcut = !root.applyShortcut }
      Text { font.family: root.fontFamily;
        width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
        color: Commons.Color.menu.text; opacity: 0.7; font.pixelSize: Style.font.caption
        text: root.applyShortcut
          ? "Apply will bind " + shortcut.text + ", create ~/.config/hypr/crmne-files.lua and load it from bindings.lua. Conflicting shortcuts are rejected. Backups are kept; failed validation restores the previous files."
          : "No shortcut is installed automatically. Enable the option above to apply this binding."
      }
      Toggle { fontFamily: root.fontFamily; width: parent.width; label: "Show file previews"; checked: root.previewEnabled; onClicked: root.previewEnabled = !root.previewEnabled }
      Row {
        spacing: Style.spacing.md
        Button { fontFamily: root.fontFamily; text: writer.running ? "Saving…" : "Save settings"; enabled: !writer.running; onClicked: root.save() }
        Button { fontFamily: root.fontFamily; text: "Rebuild search index"; onClicked: { root.rebuild(); root.message = "Rebuilding the index for saved settings…" } }
      }
      Text { font.family: root.fontFamily; width: parent.width; text: root.message; wrapMode: Text.Wrap; textFormat: Text.PlainText; color: Commons.Color.menu.text; font.pixelSize: Style.font.body }
      Text { font.family: root.fontFamily;
        width: parent.width; wrapMode: Text.Wrap; color: Commons.Color.menu.text; opacity: 0.7; font.pixelSize: Style.font.caption
        text: "↑ / ↓ Select · Enter Open · Tab Actions · Esc Back\nCtrl+V / Shift+Insert Paste · Ctrl+U Clear search"
      }
    }
  }
}
