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
    interval: 600
    running: true
    repeat: true
    property int phase: 0
    onTriggered: {
      phase++
      if (phase === 1) files.open(JSON.stringify({ root: shell.demoHome, query: "invoice" }))
      // Waits for the index and the search to finish before grabbing.
      if ((phase === 3 || phase === 5) && !shell.settled()) {
        phase--
        return
      }
      if (phase === 3) shell.save(shell.findCard(files), "search.png")
      if (phase === 4) files.openActions(files.currentItem)
      if (phase === 5) shell.save(shell.findCard(files), "actions.png")
      if (phase === 6) files.close()
      if (phase === 7) Qt.quit()
    }
  }
}
