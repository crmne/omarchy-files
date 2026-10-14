import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "FilesModel.js" as Model

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "crmne.files"
  // Where the search looks: $HOME, unless a summon payload names a folder.
  property string home: Quickshell.env("HOME")
  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/crmne-files")).replace(/^file:\/\//, ""))
  readonly property int resultLimit: 200
  // Rebuild the index on open once it is older than this many seconds.
  readonly property int indexMaxAge: 60

  property bool opened: false

  // "results" lists files, "actions" lists what can be done to one of them,
  // and "apps" lists the applications Open With offers.
  property string view: "results"
  property string query: ""
  property string scope: ""
  property var resultRows: []
  property var scopeStack: []
  property var removedPaths: ({})

  property var actionTarget: null
  property string actionQuery: ""
  property var actionRows: []
  property int resultsIndex: 0
  property int actionsIndex: 0
  property var apps: []
  property var appRows: []
  property bool appsLoading: false

  property int selectedIndex: 0
  property bool cursorActive: true
  property bool resetSelection: true

  property bool hasIndex: true
  property bool searching: searchProc.running || debounce.running
  property bool indexing: indexProc.running
  property int searchSerial: 0
  property var wantedCommand: []

  property bool trashConfirmOpen: false
  property var trashTarget: null
  onOpenedChanged: if (!opened) { trashConfirmOpen = false; trashTarget = null }

  // Shares the [menu] surface tokens, so a theme that styles the menu styles
  // this overlay the same way.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int rowSpacing: Style.spacing.xs
  property int footerHeight: Style.font.caption + Style.spacing.sm * 2
  // Seven result rows and the top of an eighth, so the fold reads as more
  // below. The card keeps this height while results change under it.
  property int listHeight: detailRowHeight * 7 + rowSpacing * 7 + rowPeek
  property int cardWidth: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(contentMargin * 2 + headerHeight + contentSpacing + listHeight + contentSpacing + footerHeight,
    panel.height - Style.gapsOut * 2)

  readonly property var currentItem: {
    if (root.view !== "results") return root.actionTarget
    if (root.selectedIndex < 0 || root.selectedIndex >= root.resultRows.length) return null
    return root.resultRows[root.selectedIndex]
  }
  readonly property string filterText: root.view === "results" ? root.query : root.actionQuery

  // ------------------------------------------------------------ lifecycle

  // payloadJson may carry {"query": "...", "scope": "Downloads"} to open
  // straight onto a search or a folder, and {"root": "/abs/path"} to search
  // a folder other than $HOME.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.home = Model.rootFrom(payload, Quickshell.env("HOME"))
    root.view = "results"
    root.scopeStack = []
    root.scope = String(payload.scope || "").replace(/^\/+|\/+$/g, "")
    root.query = String(payload.query || "")
    root.resultRows = []
    root.actionTarget = null
    root.selectedIndex = 0
    root.cursorActive = true
    root.resetSelection = true
    pointerGate.reset()
    displayModel.clear()
    root.opened = true
    root.runSearch()
    root.refreshIndex()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Read-only snapshot for scripts and tests:
  // omarchy-shell shell call crmne.files state ""
  function state() {
    return JSON.stringify({
      opened: root.opened,
      view: root.view,
      scope: root.scope,
      query: root.query,
      actionQuery: root.actionQuery,
      selectedIndex: root.selectedIndex,
      count: displayModel.count,
      hasIndex: root.hasIndex,
      indexing: root.indexing,
      selected: root.currentItem ? root.currentItem.rel : "",
      labels: root.visibleLabels()
    })
  }

  function visibleLabels() {
    var out = []
    for (var i = 0; i < Math.min(displayModel.count, 12); i++) out.push(displayModel.get(i).label)
    return out
  }

  // --------------------------------------------------------------- search

  function refreshIndex() {
    if (indexProc.running) return
    indexProc.command = [root.helper, "--root", root.home, "index", String(root.indexMaxAge)]
    indexProc.running = true
  }

  function setQuery(text) {
    root.query = text
    root.resetSelection = true
    if (text) debounce.restart()
    else {
      debounce.stop()
      root.runSearch()
    }
  }

  function runSearch() {
    root.searchSerial += 1
    root.wantedCommand = (!root.query && root.scope)
      ? [root.helper, "--root", root.home, "list", root.scope]
      : [root.helper, "--root", root.home, "search", root.query, root.scope]
    // A search still running belongs to an older query: stop it, and its exit
    // starts this one.
    if (searchProc.running) searchProc.running = false
    else root.startSearch()
  }

  function startSearch() {
    searchProc.collected = ""
    searchProc.serial = root.searchSerial
    searchProc.command = root.wantedCommand
    searchProc.running = true
  }

  function applyResults(text, exitCode) {
    if (exitCode === 3) {
      root.hasIndex = false
      root.resultRows = []
      root.refreshIndex()
    } else {
      root.hasIndex = true
      var previous = root.currentItem
      var rows = Model.rowsFromOutput(root.home, text, root.removedPaths)
      root.resultRows = rows
      root.selectedIndex = root.resetSelection ? 0 : Model.indexAfterRefresh(rows, previous ? previous.path : "", root.selectedIndex)
    }
    root.resetSelection = false
    if (root.view === "results") root.rebuildDisplay()
  }

  // ----------------------------------------------------------- navigation

  function browseInto(item) {
    if (!item || !item.isDir) return
    root.scopeStack = root.scopeStack.concat([{
      scope: root.scope, query: root.query, rows: root.resultRows, index: root.selectedIndex
    }])
    root.scope = item.rel
    root.query = ""
    root.resultRows = []
    root.selectedIndex = 0
    root.resetSelection = true
    debounce.stop()
    pointerGate.reset()
    displayModel.clear()
    root.runSearch()
  }

  function goUp() {
    pointerGate.reset()
    if (root.scopeStack.length > 0) {
      var previous = root.scopeStack[root.scopeStack.length - 1]
      root.scopeStack = root.scopeStack.slice(0, -1)
      debounce.stop()
      root.searchSerial += 1
      if (searchProc.running) searchProc.running = false
      root.scope = previous.scope
      root.query = previous.query
      root.resultRows = previous.rows.filter(function(row) { return !root.removedPaths[row.path] })
      root.selectedIndex = Math.min(previous.index, Math.max(0, root.resultRows.length - 1))
      root.rebuildDisplay()
      return true
    }
    if (!root.scope) return false
    // Opened straight into a folder: climb to its parent.
    var parent = Model.parentRel(root.scope)
    root.scope = parent
    root.query = ""
    root.resetSelection = true
    root.runSearch()
    return true
  }

  function openActions(item) {
    if (!item) return
    root.resultsIndex = root.selectedIndex
    root.actionTarget = item
    root.actionQuery = ""
    root.view = "actions"
    root.selectedIndex = 0
    pointerGate.reset()
    root.rebuildDisplay()
  }

  function closeActions() {
    root.view = "results"
    root.actionQuery = ""
    root.selectedIndex = root.resultsIndex
    pointerGate.reset()
    root.rebuildDisplay()
  }

  function openApps() {
    if (!root.actionTarget) return
    root.actionsIndex = root.selectedIndex
    root.view = "apps"
    root.actionQuery = ""
    root.apps = []
    root.selectedIndex = 0
    root.appsLoading = true
    pointerGate.reset()
    root.rebuildDisplay()
    appsProc.collected = ""
    appsProc.command = [root.helper, "apps", root.actionTarget.path]
    appsProc.running = true
  }

  function closeApps() {
    root.view = "actions"
    root.actionQuery = ""
    root.selectedIndex = root.actionsIndex
    pointerGate.reset()
    root.rebuildDisplay()
  }

  function back() {
    if (root.view === "apps") root.closeApps()
    else if (root.view === "actions") root.closeActions()
    else return root.goUp()
    return true
  }

  // -------------------------------------------------------------- display

  function rowHeightFor(detail) {
    return detail ? root.detailRowHeight : root.baseRowHeight
  }

  function rebuildDisplay() {
    displayModel.clear()
    if (root.view === "results") {
      // A folder's own listing needs no location line, as the menu shows
      // detail only while a search narrows it.
      var listing = !!root.scope && !root.query
      for (var i = 0; i < root.resultRows.length; i++) {
        var row = root.resultRows[i]
        displayModel.append({ rowKind: "file", icon: row.icon, appIcon: "", label: row.name, detail: listing ? "" : row.detail, trail: "", chevron: row.isDir })
      }
    } else if (root.view === "actions") {
      root.actionRows = Model.filterActions(Model.actionsFor(root.actionTarget), root.actionQuery)
      for (var j = 0; j < root.actionRows.length; j++) {
        var action = root.actionRows[j]
        displayModel.append({ rowKind: "action", icon: action.icon, appIcon: "", label: action.label, detail: "", trail: action.shortcut, chevron: action.submenu })
      }
    } else {
      root.appRows = Model.filterApps(root.apps, root.actionQuery)
      for (var k = 0; k < root.appRows.length; k++) {
        var app = root.appRows[k]
        displayModel.append({ rowKind: "app", icon: "", appIcon: app.icon, label: app.name, detail: "", trail: app.isDefault ? "Default" : "", chevron: false })
      }
    }

    if (displayModel.count === 0) root.selectedIndex = 0
    else root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, displayModel.count - 1))
    root.cursorActive = displayModel.count > 0
    Qt.callLater(root.revealCursor)
  }

  function revealCursor() {
    if (displayModel.count === 0) return
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function select(delta, wrap) {
    if (displayModel.count === 0) return
    pointerGate.reset()
    root.cursorActive = true
    var next = root.selectedIndex + delta
    if (wrap) next = (next + displayModel.count) % displayModel.count
    else next = Math.max(0, Math.min(displayModel.count - 1, next))
    root.selectedIndex = next
    root.revealCursor()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function setActionQuery(text) {
    root.actionQuery = text
    root.selectedIndex = 0
    pointerGate.reset()
    root.rebuildDisplay()
  }

  // -------------------------------------------------------------- actions

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    root.selectedIndex = index
    if (root.view === "results") root.runAction("open", root.resultRows[index])
    else if (root.view === "actions") root.runAction(root.actionRows[index].id, root.actionTarget)
    else root.launchApp(root.appRows[index])
  }

  function runAction(id, item) {
    if (!id || !item) return
    if (id === "openWith") {
      if (root.view === "results") root.openActions(item)
      root.openApps()
      return
    }
    if (id === "trash") {
      root.trashTarget = item
      trashConfirm.selectedIndex = 1
      root.trashConfirmOpen = true
      return
    }
    var command = Model.commandFor(id, item, { home: root.home })
    if (!command) return
    root.dismiss()
    Util.execArgv(command)
  }

  function launchApp(app) {
    if (!app || !root.actionTarget) return
    var command = Model.commandFor("openWith", root.actionTarget, { home: root.home, appId: app.id })
    if (!command) return
    root.dismiss()
    Util.execArgv(command)
  }

  function cancelTrash() {
    root.trashConfirmOpen = false
    root.trashTarget = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmTrash() {
    var target = root.trashTarget
    root.trashConfirmOpen = false
    root.trashTarget = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (!target || trashProc.running) return
    trashProc.target = target
    trashProc.command = Model.commandFor("trash", target, { home: root.home })
    trashProc.running = true
  }

  function trashed(target) {
    var removed = ({})
    for (var key in root.removedPaths) removed[key] = true
    removed[target.path] = true
    root.removedPaths = removed

    var index = root.view === "results" ? root.selectedIndex : root.resultsIndex
    root.resultRows = root.resultRows.filter(function(row) { return row.path !== target.path })
    if (root.view !== "results") {
      root.view = "results"
      root.actionQuery = ""
    }
    root.selectedIndex = Math.min(index, Math.max(0, root.resultRows.length - 1))
    root.rebuildDisplay()
  }

  // Key names the model's shortcut table speaks.
  function keyName(key) {
    if (key === Qt.Key_Return || key === Qt.Key_Enter) return "Enter"
    if (key === Qt.Key_Delete) return "Delete"
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    return ""
  }

  function isPrintable(event) {
    return event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
      && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var filter = root.filterText

    var target = root.currentItem
    if (root.view !== "apps") {
      var shortcut = Model.shortcutAction({ key: root.keyName(event.key), ctrl: ctrl, shift: shift, alt: alt }, target)
      if (shortcut) {
        root.runAction(shortcut, target)
        return true
      }
    }

    if (event.key === Qt.Key_Escape) {
      if (filter) {
        if (root.view === "results") root.setQuery("")
        else root.setActionQuery("")
      } else if (!root.back()) {
        root.dismiss()
      }
      return true
    }

    if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && shift)) {
      if (root.view !== "results") root.back()
      return true
    }

    if (event.key === Qt.Key_Tab || (event.key === Qt.Key_K && ctrl)) {
      if (root.view === "results") root.openActions(target)
      else if (event.key === Qt.Key_K) root.back()
      return true
    }

    if (Util.editsFilter(event, filter)) {
      var edited = Util.editedFilter(event, filter)
      if (root.view === "results") root.setQuery(edited)
      else root.setActionQuery(edited)
      return true
    }

    if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && !filter) {
      root.back()
      return true
    }

    if (event.key === Qt.Key_Right) {
      if (root.view === "results" && target) {
        if (target.isDir) root.browseInto(target)
        else root.openActions(target)
      } else if (root.view === "actions" && root.actionRows[root.selectedIndex] && root.actionRows[root.selectedIndex].submenu) {
        root.openApps()
      }
      return true
    }

    if (event.key === Qt.Key_Up) { root.select(-1, true); return true }
    if (event.key === Qt.Key_Down) { root.select(1, true); return true }
    if (event.key === Qt.Key_PageUp) { root.select(-6, false); return true }
    if (event.key === Qt.Key_PageDown) { root.select(6, false); return true }

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (displayModel.count > 0) root.activateIndex(root.selectedIndex)
      return true
    }

    if (root.isPrintable(event)) {
      if (root.view === "results") root.setQuery(root.query + event.text)
      else root.setActionQuery(root.actionQuery + event.text)
      return true
    }

    return false
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Timer {
    id: debounce
    interval: 50
    onTriggered: root.runSearch()
  }

  Process {
    id: searchProc
    property int serial: 0
    property string collected: ""
    stdout: SplitParser {
      onRead: function(line) { searchProc.collected += line + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (searchProc.serial === root.searchSerial && exitStatus === 0) {
        root.applyResults(searchProc.collected, exitCode)
      } else if (root.opened) {
        Qt.callLater(function() {
          if (!searchProc.running && searchProc.serial !== root.searchSerial) root.startSearch()
        })
      }
    }
  }

  Process {
    id: indexProc
    stdout: SplitParser { onRead: function(line) {} }
    onExited: function(exitCode, exitStatus) {
      // A first build lands while the overlay shows "Indexing…": search again.
      if (root.opened && !root.hasIndex && exitCode === 0) root.runSearch()
    }
  }

  Process {
    id: appsProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(line) { appsProc.collected += line + "\n" }
    }
    onExited: {
      root.apps = Model.parseApps(appsProc.collected)
      root.appsLoading = false
      if (root.view === "apps") root.rebuildDisplay()
    }
  }

  Process {
    id: trashProc
    property var target: null
    onExited: function(exitCode) {
      var target = trashProc.target
      trashProc.target = null
      if (!target) return
      if (exitCode === 0) root.trashed(target)
      else Util.execArgv(["omarchy-notification-send", "-u", "normal", "Could not move to Trash", target.name])
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "crmne-files"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.trashConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.trashConfirmOpen) {
            if (trashConfirm.handleKey(event)) event.accepted = true
            return
          }
          if (root.handleKey(event)) event.accepted = true
        }

        ConfirmDialog {
          id: trashConfirm

          anchors.fill: parent
          opened: root.trashConfirmOpen
          z: 10
          message: "Move “" + ((root.trashTarget && root.trashTarget.name) || "") + "” to the Trash?"
          confirmText: "Trash"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelTrash()
          onConfirmed: root.confirmTrash()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          id: header
          width: parent.width
          height: root.headerHeight

          readonly property string prefix: {
            if (!root.filterText) return ""
            if (root.view === "actions") return root.actionTarget ? root.actionTarget.name + " › " : ""
            if (root.view === "apps") return root.actionTarget ? root.actionTarget.name + " › Open With › " : ""
            return root.scope ? Model.basename(root.scope) + " › " : ""
          }

          Text {
            id: prefixText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * 0.5)
            visible: header.prefix.length > 0
            text: header.prefix
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideMiddle
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: prefixText.visible ? prefixText.right : parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || Model.headerPlaceholder(root.view, root.scope, root.actionTarget ? root.actionTarget.name : "")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            // Long breadcrumbs and queries keep their end in view.
            elide: Text.ElideLeft
          }
        }

        Item {
          width: parent.width
          height: root.listHeight

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds

            delegate: BorderSurface {
              id: row
              required property int index
              required property string rowKind
              required property string icon
              required property string appIcon
              required property string label
              required property string detail
              required property string trail
              required property bool chevron

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
              readonly property bool isApp: row.rowKind === "app"

              width: ListView.view.width
              height: root.rowHeightFor(row.detail)
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Text {
                id: iconText
                textFormat: Text.PlainText
                visible: !row.isApp
                text: row.icon
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Image {
                visible: row.isApp
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: row.isApp && row.appIcon ? Quickshell.iconPath(row.appIcon, "application-x-executable") : ""
                asynchronous: true
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8) + (Style.space(36) - width) / 2
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Column {
                id: contentColumn
                anchors.left: iconText.right
                anchors.leftMargin: Style.space(6)
                anchors.right: trailRow.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  id: labelText
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideMiddle
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.detail
                  visible: row.detail.length > 0
                  color: root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideLeft
                }
              }

              Row {
                id: trailRow
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  visible: row.trail.length > 0
                  text: row.trail
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  width: Style.space(14)
                  text: row.chevron ? "›" : ""
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.chevron ? 0.36 : 0
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Normal
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectFromPointer(row.index, row, { x: mouseArea.mouseX, y: mouseArea.mouseY })
                onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }
                onClicked: {
                  root.cursorActive = true
                  root.activateIndex(row.index)
                }
              }
            }
          }

          // Scroll scrims, as in the Omarchy menu: each edge fades by how
          // much is still hidden past it.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: resultList.contentHeight > resultList.height
              ? Math.max(0, Math.min(1, (resultList.contentY - resultList.originY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: root.background }
              GradientStop { position: 1; color: Util.alpha(root.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: resultList.contentHeight > resultList.height
              ? Math.max(0, Math.min(1, (resultList.originY + resultList.contentHeight - resultList.height - resultList.contentY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.background, 0) }
              GradientStop { position: 1; color: root.background }
            }
          }

          Column {
            id: emptyState
            anchors.centerIn: parent
            spacing: Style.space(8)
            readonly property bool waitingForIndex: root.view === "results" && !root.hasIndex
            visible: displayModel.count === 0
              && (emptyState.waitingForIndex || (root.view === "results" ? !root.searching : (root.view === "actions" || !root.appsLoading)))

            Text {
              text: emptyState.waitingForIndex ? "󰥨" : "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }

            Text {
              textFormat: Text.PlainText
              text: {
                if (emptyState.waitingForIndex) return "Indexing your files…"
                if (root.filterText) return "No matches for “" + root.filterText + "”"
                if (root.view === "apps") return "No applications for this file"
                if (root.scope) return "This folder is empty"
                return "Nothing here yet"
              }
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }
          }
        }

        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            id: statusText
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: Model.footerStatus({
              view: root.view, query: root.query, scope: root.scope, count: root.resultRows.length,
              limit: root.resultLimit, indexing: root.indexing, hasIndex: root.hasIndex
            })
            color: root.foreground
            opacity: 0.52
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
            anchors.left: statusText.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: displayModel.count > 0 ? Model.footerHint(root.view, root.currentItem) : ""
            color: root.foreground
            opacity: 0.52
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }
        }
      }
    }
  }
}
