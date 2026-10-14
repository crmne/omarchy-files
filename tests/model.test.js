const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../FilesModel.js")

const HOME = "/home/demo"

test("files are classified by extension, folders by their trailing slash", () => {
  assert.equal(Model.classify("Pictures/"), "folder")
  assert.equal(Model.classify("Pictures/beach.JPG"), "image")
  assert.equal(Model.classify("Videos/talk.mkv"), "video")
  assert.equal(Model.classify("Music/song.flac"), "audio")
  assert.equal(Model.classify("Documents/invoice.pdf"), "pdf")
  assert.equal(Model.classify("Downloads/release.tar.gz"), "archive")
  assert.equal(Model.classify("Code/app/main.rb"), "code")
  assert.equal(Model.classify("Code/app/Widget.qml"), "code")
  // TypeScript is far more common under $HOME than MPEG transport streams.
  assert.equal(Model.classify("Code/app/index.ts"), "code")
  assert.equal(Model.classify("notes/todo.md"), "text")
  assert.equal(Model.classify("Code/app/README"), "text")
  assert.equal(Model.classify("Code/app/Makefile"), "text")
  assert.equal(Model.classify("Downloads/blob.bin"), "generic")
  assert.equal(Model.classify("Downloads/noextension"), "generic")
  // A leading dot is a hidden name, not an extension.
  assert.equal(Model.classify(".bashrc"), "generic")
  assert.equal(Model.iconFor("folder"), Model.ICONS.folder)
  assert.equal(Model.iconFor("nonsense"), Model.ICONS.generic)
})

test("an index line becomes a row named by its basename and placed by its folder", () => {
  const file = Model.itemFor(HOME, "Documents/Taxes/2025 return.pdf")
  assert.equal(file.name, "2025 return.pdf")
  assert.equal(file.detail, "~/Documents/Taxes")
  assert.equal(file.path, "/home/demo/Documents/Taxes/2025 return.pdf")
  assert.equal(file.rel, "Documents/Taxes/2025 return.pdf")
  assert.equal(file.isDir, false)
  assert.equal(file.kind, "pdf")

  const folder = Model.itemFor(HOME, "Downloads/")
  assert.equal(folder.name, "Downloads")
  assert.equal(folder.detail, "~")
  assert.equal(folder.path, "/home/demo/Downloads")
  assert.equal(folder.rel, "Downloads")
  assert.equal(folder.isDir, true)
})

test("helper output keeps its order and drops blank lines and trashed paths", () => {
  const rows = Model.rowsFromOutput(HOME, "a.txt\n\nPictures/\nb.png\n", { "/home/demo/b.png": true })
  assert.deepEqual(rows.map(r => r.name), ["a.txt", "Pictures"])
  assert.deepEqual(Model.rowsFromOutput(HOME, ""), [])
})

test("actions depend on what the item is", () => {
  const ids = item => Model.actionsFor(item).map(a => a.id)
  const image = Model.itemFor(HOME, "Pictures/sky.png")
  const code = Model.itemFor(HOME, "Code/app/main.go")
  const folder = Model.itemFor(HOME, "Code/app/")
  const pdf = Model.itemFor(HOME, "Documents/a.pdf")

  assert.equal(ids(image)[0], "open", "the primary action leads")
  assert.ok(ids(image).includes("background"))
  assert.ok(!ids(image).includes("editor"))
  assert.ok(ids(code).includes("editor"))
  assert.ok(!ids(code).includes("background"))
  assert.ok(ids(folder).includes("editor"))
  assert.ok(ids(folder).includes("terminal"))
  assert.ok(!ids(pdf).includes("editor"))
  assert.ok(ids(pdf).includes("openWith"))
  assert.equal(ids(pdf).slice(-1)[0], "trash", "the destructive action goes last")

  const labels = Model.actionsFor(folder).map(a => a.label)
  assert.ok(labels.includes("Copy Folder"))
  assert.ok(labels.includes("Open Folder in Editor"))
  assert.ok(Model.actionsFor(pdf).map(a => a.label).includes("Copy File"))
  assert.deepEqual(Model.actionsFor(null), [])
})

test("every action with a shortcut shows it, and Open With is a submenu", () => {
  const actions = Model.actionsFor(Model.itemFor(HOME, "Pictures/sky.png"))
  const byId = Object.fromEntries(actions.map(a => [a.id, a]))
  assert.equal(byId.open.shortcut, "↵")
  assert.equal(byId.reveal.shortcut, "Ctrl ↵")
  assert.equal(byId.share.shortcut, "Alt ↵")
  assert.equal(byId.copyPath.shortcut, "Ctrl C")
  assert.equal(byId.copyFile.shortcut, "Ctrl Shift C")
  assert.equal(byId.trash.shortcut, "Ctrl Del")
  assert.equal(byId.background.shortcut, "")
  assert.equal(byId.openWith.submenu, true)
  assert.equal(byId.open.submenu, false)
})

test("typing narrows actions by substring first, then by letters in order", () => {
  const actions = Model.actionsFor(Model.itemFor(HOME, "Pictures/sky.png"))
  assert.deepEqual(Model.filterActions(actions, "copy").map(a => a.id), ["copyPath", "copyFile"])
  assert.deepEqual(Model.filterActions(actions, "trash").map(a => a.id), ["trash"])
  assert.equal(Model.filterActions(actions, "cp")[0].id, "copyPath")
  assert.equal(Model.filterActions(actions, "  OPEN ")[0].id, "open")
  assert.deepEqual(Model.filterActions(actions, "zzz"), [])
  assert.equal(Model.filterActions(actions, "").length, actions.length)
})

test("shortcuts map to actions straight from the results list", () => {
  const file = Model.itemFor(HOME, "Documents/a.pdf")
  const code = Model.itemFor(HOME, "Code/app/main.go")
  assert.equal(Model.shortcutAction({ key: "Enter", ctrl: true }, file), "reveal")
  assert.equal(Model.shortcutAction({ key: "Enter", alt: true }, file), "share")
  assert.equal(Model.shortcutAction({ key: "C", ctrl: true }, file), "copyPath")
  assert.equal(Model.shortcutAction({ key: "C", ctrl: true, shift: true }, file), "copyFile")
  assert.equal(Model.shortcutAction({ key: "Delete", ctrl: true }, file), "trash")
  assert.equal(Model.shortcutAction({ key: "T", ctrl: true }, file), "terminal")
  assert.equal(Model.shortcutAction({ key: "E", ctrl: true }, code), "editor")
  // Not offered for a PDF, so its shortcut does nothing either.
  assert.equal(Model.shortcutAction({ key: "E", ctrl: true }, file), "")
  // Plain keys belong to the list and the search field.
  assert.equal(Model.shortcutAction({ key: "Enter" }, file), "")
  assert.equal(Model.shortcutAction({ key: "C" }, file), "")
  assert.equal(Model.shortcutAction({ key: "Delete" }, file), "")
  assert.equal(Model.shortcutAction({ key: "C", ctrl: true }, null), "")
})

test("the header reads as a breadcrumb while browsing", () => {
  assert.equal(Model.breadcrumb(""), "Files")
  assert.equal(Model.breadcrumb("Downloads"), "Files › Downloads")
  assert.equal(Model.breadcrumb("Code/app/"), "Files › Code › app")
  assert.equal(Model.headerPlaceholder("results", "", ""), "Search files…")
  assert.equal(Model.headerPlaceholder("results", "Downloads", ""), "Files › Downloads…")
  assert.equal(Model.headerPlaceholder("actions", "", "sky.png"), "sky.png ›")
  assert.equal(Model.headerPlaceholder("apps", "", "sky.png"), "sky.png › Open With")
})

test("the footer hint follows the selection and the view", () => {
  assert.equal(Model.footerHint("results", Model.itemFor(HOME, "Downloads/")), "↵ Open   ⇥ Actions   → Browse")
  assert.equal(Model.footerHint("results", Model.itemFor(HOME, "a.pdf")), "↵ Open   ⇥ Actions")
  assert.equal(Model.footerHint("results", null), "")
  assert.equal(Model.footerHint("actions", null), "↵ Run   esc Back")

  const status = s => Model.footerStatus(Object.assign({ view: "results", query: "", scope: "", count: 0, limit: 200, indexing: false, hasIndex: true }, s))
  assert.equal(status({}), "Recent")
  assert.equal(status({ scope: "Downloads", count: 3 }), "3 items")
  assert.equal(status({ query: "tax", count: 1 }), "1 result")
  assert.equal(status({ query: "tax", count: 200 }), "200+ results")
  assert.equal(status({ indexing: true, hasIndex: false }), "Indexing…")
  assert.equal(status({ view: "actions" }), "")
})

test("action commands are argv vectors with the path as its own argument", () => {
  const file = Model.itemFor(HOME, "Docs/a b; $(rm -rf ~).pdf")
  const folder = Model.itemFor(HOME, "Code/app/")
  const image = Model.itemFor(HOME, "Pictures/sky.png")
  const opts = { home: HOME }

  assert.deepEqual(Model.commandFor("open", file, opts), ["uwsm-app", "--", "xdg-open", file.path])
  assert.deepEqual(Model.commandFor("open", folder, opts), ["uwsm-app", "--", "nautilus", "--new-window", folder.path])
  assert.deepEqual(Model.commandFor("reveal", file, opts), ["uwsm-app", "--", "nautilus", "--new-window", "--select", file.path])
  assert.deepEqual(Model.commandFor("reveal", folder, opts), ["uwsm-app", "--", "nautilus", "--new-window", folder.path])
  assert.deepEqual(Model.commandFor("terminal", file, opts), ["uwsm-app", "--", "xdg-terminal-exec", "--dir=/home/demo/Docs"])
  assert.deepEqual(Model.commandFor("terminal", folder, opts), ["uwsm-app", "--", "xdg-terminal-exec", "--dir=/home/demo/Code/app"])
  assert.deepEqual(Model.commandFor("editor", folder, opts), ["omarchy-launch-editor", folder.path])
  assert.deepEqual(Model.commandFor("share", file, opts), ["omarchy-menu-share", "file", file.path])
  assert.deepEqual(Model.commandFor("share", folder, opts), ["omarchy-menu-share", "folder", folder.path])
  assert.deepEqual(Model.commandFor("background", image, opts), ["omarchy-theme-bg-set", image.path])
  assert.equal(Model.commandFor("background", file, opts), null)
  assert.deepEqual(Model.commandFor("trash", file, opts), ["gio", "trash", "--", file.path])
  assert.deepEqual(Model.commandFor("openWith", image, { home: HOME, appId: "imv.desktop" }), ["uwsm-app", "--", "imv.desktop", image.path])
  assert.equal(Model.commandFor("openWith", image, opts), null)
  assert.equal(Model.commandFor("unknown", image, opts), null)

  // The copy commands run a constant script; the path only ever arrives as $1.
  const copy = Model.commandFor("copyPath", file, opts)
  assert.equal(copy[0], "bash")
  assert.ok(!copy[2].includes(file.path))
  assert.equal(copy[4], file.path)
  assert.equal(copy[5], "~/Docs/a b; $(rm -rf ~).pdf")
  const copyFile = Model.commandFor("copyFile", folder, opts)
  assert.equal(copyFile[4], "file:///home/demo/Code/app")
  assert.equal(copyFile[6], "Folder")
})

test("file URIs percent-encode each segment", () => {
  assert.equal(Model.fileUri("/home/demo/a b/c#d.txt"), "file:///home/demo/a%20b/c%23d.txt")
})

test("Open With lists the default handler first and filters by name", () => {
  const apps = Model.parseApps("imv.desktop\tImage Viewer\timv\t1\nchromium.desktop\tChromium\tchromium\t0\nimv.desktop\tImage Viewer\timv\t0\nbad\n")
  assert.deepEqual(apps.map(a => a.id), ["imv.desktop", "chromium.desktop"])
  assert.equal(apps[0].isDefault, true)
  assert.equal(apps[1].icon, "chromium")
  assert.deepEqual(Model.filterApps(apps, "chrom").map(a => a.id), ["chromium.desktop"])
  assert.equal(Model.filterApps(apps, "").length, 2)
})

test("the cursor follows its path across refreshes, otherwise stays in range", () => {
  const rows = Model.rowsFromOutput(HOME, "a\nb\nc\n")
  assert.equal(Model.indexAfterRefresh(rows, "/home/demo/c", 0), 2)
  assert.equal(Model.indexAfterRefresh(rows, "/home/demo/gone", 7), 2)
  assert.equal(Model.indexAfterRefresh([], "/home/demo/a", 3), 0)
})
