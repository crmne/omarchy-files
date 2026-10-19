// Renders the real Files overlay searching a made-up home folder, for the
// marketplace preview. Nothing under the real $HOME is listed or indexed:
// the overlay is summoned with the demo folder as its root. Run through
// tools/render-preview.
import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  id: shell

  readonly property string outDir: Quickshell.env("FILES_PREVIEW_OUT")
  readonly property string demoHome: Quickshell.env("FILES_PREVIEW_HOME")
  // Three times the on-screen size, so the preview can show the card large
  // and still sharp.
  readonly property int grabScale: 3

  Plugin.Files { id: files }

  // The card: the bordered surface the overlay draws its content in.
  function findCard(item) {
    if (!item) return null
    if (item !== files && item.borderSpec !== undefined && item.padding !== undefined) return item
    var kids = item.data || item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findCard(kids[i])
      if (found) return found
    }
    return null
  }

  function save(item, name) {
    item.grabToImage(function(result) { result.saveToFile(shell.outDir + "/" + name) },
      Qt.size(item.width * shell.grabScale, item.height * shell.grabScale))
  }

  function settled() {
    var state = JSON.parse(files.state())
    return state.count > 0 && !files.searching && !files.indexing
  }

  Timer {
    interval: 400; running: true; repeat: true
    property int phase: 0
    property var scenes: [
      {name: "code", query: "preview"},
      {name: "pdf", query: "preview.pdf"},
      {name: "audio", query: "preview.wav"},
      {name: "settings", query: "preview"}
    ]
    onTriggered: {
      var scene = scenes[Math.floor(phase / 6)]
      if (!scene) { files.close(); Qt.quit(); return }
      if (phase % 6 === 0) {
        files.cardWidth = 1000
        files.cardHeight = 480
        files.listHeight = files.cardHeight - files.contentMargin * 2 - files.headerHeight - files.contentSpacing * 2 - files.footerHeight
        files.open(JSON.stringify({root: shell.demoHome, query: scene.query}))
      }
      if (phase % 6 === 1 && !shell.settled()) return
      if (phase % 6 === 2 && scene.name === "settings") {
        files.preferences = {root: "/home/demo", excludes: ["go", "Android"], shortcut: "SUPER + CTRL + ALT + SPACE", preview: true}
        files.flipSettings()
      }
      if (phase % 6 === 5) shell.save(shell.findCard(files), scene.name + ".png")
      phase++
    }
  }
}
