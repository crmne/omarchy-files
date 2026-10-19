// Pure helpers for the Files overlay: turning index lines into rows, picking
// the actions that apply to an item, matching shortcuts, and building the argv
// each action runs.
//
// Kept free of QML types so `node --test tests/model.test.js` can exercise the
// rules directly. Paths arrive relative to $HOME, folders with a trailing "/".

var glyph = function(code) { return String.fromCodePoint(code) }

var ICONS = {
  folder: glyph(0xF024B),
  image: glyph(0xF021F),
  video: glyph(0xF022B),
  audio: glyph(0xF0223),
  pdf: glyph(0xF0226),
  archive: glyph(0xF05C4),
  code: glyph(0xF022E),
  text: glyph(0xF0219),
  generic: glyph(0xF0214)
}

var EXTENSIONS = {
  image: ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff", "svg", "ico", "jxl", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "psd", "xcf", "kra"],
  video: ["mp4", "mkv", "mov", "webm", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "3gp", "ogv"],
  audio: ["mp3", "flac", "wav", "ogg", "oga", "opus", "m4a", "aac", "aif", "aiff", "wma", "alac", "mid", "midi", "bwproject"],
  pdf: ["pdf"],
  archive: ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "tzst", "7z", "rar", "lz", "lzma", "cab", "iso", "dmg", "deb", "rpm", "apk", "jar", "appimage"],
  code: ["js", "mjs", "cjs", "ts", "tsx", "jsx", "qml", "rb", "erb", "py", "go", "rs", "c", "h", "cc", "cpp", "hpp", "cs", "java", "kt", "swift", "m", "mm", "lua", "sh", "bash", "zsh", "fish", "pl", "php", "ex", "exs", "erl", "hs", "ml", "clj", "scala", "dart", "zig", "nim", "r", "jl", "sql", "html", "htm", "css", "scss", "sass", "less", "vue", "svelte", "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "cfg", "xml", "gradle", "cmake", "mk", "nix", "tf", "proto", "graphql", "ipynb", "rake", "gemspec", "lock", "diff", "patch"],
  text: ["txt", "md", "markdown", "rst", "org", "adoc", "tex", "log", "csv", "tsv", "srt", "vtt", "env", "rtf"]
}

// Extensionless names that are plainly text.
var TEXT_NAMES = ["readme", "license", "licence", "makefile", "dockerfile", "gemfile", "rakefile", "procfile", "brewfile", "justfile", "changelog", "authors", "copying", "todo", "notes"]

var KIND_BY_EXTENSION = (function() {
  var out = ({})
  for (var kind in EXTENSIONS) {
    var list = EXTENSIONS[kind]
    for (var i = 0; i < list.length; i++) out[list[i]] = kind
  }
  return out
})()

function isFolderLine(rel) {
  return String(rel || "").slice(-1) === "/"
}

function trimSlash(rel) {
  return String(rel || "").replace(/\/+$/, "")
}

function basename(rel) {
  var clean = trimSlash(rel)
  var at = clean.lastIndexOf("/")
  return at < 0 ? clean : clean.slice(at + 1)
}

function parentRel(rel) {
  var clean = trimSlash(rel)
  var at = clean.lastIndexOf("/")
  return at < 0 ? "" : clean.slice(0, at)
}

function extension(name) {
  var n = String(name || "")
  var dot = n.lastIndexOf(".")
  if (dot <= 0 || dot === n.length - 1) return ""
  return n.slice(dot + 1).toLowerCase()
}

function classify(rel) {
  if (isFolderLine(rel)) return "folder"
  var name = basename(rel)
  var ext = extension(name)
  if (ext && KIND_BY_EXTENSION[ext]) return KIND_BY_EXTENSION[ext]
  // Dotted compound archives: foo.tar.gz is caught by "gz" above.
  if (!ext && TEXT_NAMES.indexOf(name.toLowerCase()) >= 0) return "text"
  return "generic"
}

function iconFor(kind) {
  return ICONS[kind] || ICONS.generic
}

function absolutePath(home, rel) {
  var base = trimSlash(home)
  var clean = trimSlash(rel)
  return clean ? base + "/" + clean : base
}

// "~/Downloads" for a file in Downloads, "~" for one directly in $HOME.
function displayFolder(rel) {
  var parent = parentRel(rel)
  return parent ? "~/" + parent : "~"
}

function itemFor(home, rel) {
  var line = String(rel || "")
  var kind = classify(line)
  return {
    rel: trimSlash(line),
    path: absolutePath(home, line),
    name: basename(line),
    detail: displayFolder(line),
    isDir: kind === "folder",
    kind: kind,
    icon: iconFor(kind)
  }
}

// The folder searched: $HOME, or an absolute folder a summon payload names
// (demo content for screenshots). Relative or odd values fall back to home.
function rootFrom(payload, home) {
  var asked = payload && typeof payload.root === "string" ? payload.root.replace(/\/+$/, "") : ""
  if (!asked || asked.charAt(0) !== "/" || /(^|\/)\.\.(\/|$)/.test(asked)) return trimSlash(home)
  return asked
}

// Index or listing output to rows. Lines for paths the session has already
// trashed are dropped, since the index only learns about it on its next build.
function rowsFromOutput(home, text, removed) {
  var gone = removed || ({})
  var lines = String(text || "").split("\n")
  var rows = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line || line === "/") continue
    var item = itemFor(home, line)
    if (gone[item.path]) continue
    rows.push(item)
  }
  return rows
}

function isEditable(item) {
  return !!item && (item.isDir || item.kind === "code" || item.kind === "text")
}

// Every action, in panel order. `applies` decides whether an item gets it;
// `shortcut` is matched against key combos and shown in the row's trail.
var ACTIONS = [
  { id: "open", label: "Open", icon: glyph(0xF03CC), shortcut: { key: "Enter" } },
  { id: "openWith", label: "Open With…", icon: glyph(0xF003B), submenu: true },
  { id: "reveal", label: "Show in Files", icon: glyph(0xF0770), shortcut: { key: "Enter", ctrl: true } },
  { id: "editor", label: "Open in Editor", icon: glyph(0xF03EB), shortcut: { key: "E", ctrl: true }, applies: isEditable },
  { id: "terminal", label: "Open Terminal Here", icon: glyph(0xF018D), shortcut: { key: "T", ctrl: true } },
  { id: "copyPath", label: "Copy Path", icon: glyph(0xF018F), shortcut: { key: "C", ctrl: true } },
  { id: "copyFile", label: "Copy File", icon: glyph(0xF0191), shortcut: { key: "C", ctrl: true, shift: true } },
  { id: "share", label: "Share", icon: glyph(0xF0497), shortcut: { key: "Enter", alt: true } },
  { id: "background", label: "Set as Background", icon: glyph(0xF0E09), applies: function(item) { return item.kind === "image" } },
  { id: "trash", label: "Move to Trash", icon: glyph(0xF0A7A), shortcut: { key: "Delete", ctrl: true } }
]

var KEY_LABELS = { Enter: "↵", Delete: "Del" }

function shortcutLabel(shortcut) {
  if (!shortcut) return ""
  var parts = []
  if (shortcut.ctrl) parts.push("Ctrl")
  if (shortcut.alt) parts.push("Alt")
  if (shortcut.shift) parts.push("Shift")
  parts.push(KEY_LABELS[shortcut.key] || shortcut.key)
  return parts.join(" ")
}

function labelFor(action, item) {
  if (action.id === "copyFile" && item && item.isDir) return "Copy Folder"
  if (action.id === "editor" && item && item.isDir) return "Open Folder in Editor"
  return action.label
}

function actionsFor(item) {
  if (!item) return []
  var out = []
  for (var i = 0; i < ACTIONS.length; i++) {
    var action = ACTIONS[i]
    if (action.applies && !action.applies(item)) continue
    out.push({
      id: action.id,
      label: labelFor(action, item),
      icon: action.icon,
      shortcut: shortcutLabel(action.shortcut),
      submenu: !!action.submenu
    })
  }
  return out
}

// Typing in the panel narrows it: names containing the text come first, then
// names holding its letters in order ("cp" finds Copy Path). Panel order is
// kept within each group.
function isSubsequence(needle, hay) {
  var at = 0
  for (var i = 0; i < hay.length && at < needle.length; i++) {
    if (hay.charAt(i) === needle.charAt(at)) at++
  }
  return at === needle.length
}

function filterActions(actions, query) {
  var q = String(query || "").trim().toLowerCase().replace(/\s+/g, " ")
  if (!q) return (actions || []).slice()
  var compact = q.replace(/ /g, "")
  var exact = []
  var loose = []
  for (var i = 0; i < (actions || []).length; i++) {
    var label = String(actions[i].label || "").toLowerCase()
    if (label.indexOf(q) >= 0) exact.push(actions[i])
    else if (isSubsequence(compact, label.replace(/ /g, ""))) loose.push(actions[i])
  }
  return exact.concat(loose)
}

// The action a key combo triggers for an item from the results list, or "".
// combo: { key: "Enter" | "C" | ..., ctrl, shift, alt }. Plain Enter is the
// list's own business, so it is not matched here.
function shortcutAction(combo, item) {
  if (!combo || !item) return ""
  var ctrl = !!combo.ctrl, shift = !!combo.shift, alt = !!combo.alt
  if (!ctrl && !shift && !alt) return ""
  for (var i = 0; i < ACTIONS.length; i++) {
    var action = ACTIONS[i]
    var s = action.shortcut
    if (!s || s.key !== combo.key) continue
    if (!!s.ctrl !== ctrl || !!s.shift !== shift || !!s.alt !== alt) continue
    if (action.applies && !action.applies(item)) return ""
    return action.id
  }
  return ""
}

// Header path while browsing: "Files › Downloads › Invoices".
function breadcrumb(scopeRel) {
  var parts = ["Files"]
  var clean = trimSlash(scopeRel)
  if (clean) parts = parts.concat(clean.split("/"))
  return parts.join(" › ")
}

function headerPlaceholder(view, scopeRel, targetName) {
  if (view === "actions") return targetName + " ›"
  if (view === "apps") return targetName + " › Open With"
  if (scopeRel) return breadcrumb(scopeRel) + "…"
  return "Search files…"
}

function footerHint(view, item) {
  if (view === "actions") return "↵ Run   esc Back"
  if (view === "apps") return "↵ Open   esc Back"
  if (!item) return ""
  if (item.isDir) return "↵ Open   ⇥ Actions   → Browse"
  return "↵ Open   ⇥ Actions"
}

function footerStatus(state) {
  if (state.indexing && !state.hasIndex) return "Indexing…"
  if (state.view !== "results") return ""
  if (!state.query && !state.scope) return "Recent"
  if (!state.query) return state.count === 1 ? "1 item" : state.count + " items"
  if (state.count >= state.limit) return state.limit + "+ results"
  return state.count === 1 ? "1 result" : state.count + " results"
}

// file:// URI with each path segment percent-encoded, as text/uri-list wants.
function fileUri(path) {
  return "file://" + String(path || "").split("/").map(encodeURIComponent).join("/")
}

// argv for an action. Nothing here passes through a shell as code: the few
// commands that need a pipe use a constant script with positional arguments.
// options: { home, appId } (appId only for openWith).
function commandFor(actionId, item, options) {
  if (!item) return null
  var extra = options || ({})
  var path = item.path
  var dir = item.isDir ? path : (path.replace(/\/[^/]*$/, "") || "/")
  var home = String(extra.home || "").replace(/\/+$/, "")
  var shown = home && path.indexOf(home + "/") === 0 ? "~" + path.slice(home.length) : path
  switch (actionId) {
    case "open":
      return item.isDir
        ? ["uwsm-app", "--", "nautilus", "--new-window", path]
        : ["uwsm-app", "--", "xdg-open", path]
    case "openWith":
      if (!extra.appId) return null
      return ["uwsm-app", "--", extra.appId, path]
    case "reveal":
      return item.isDir
        ? ["uwsm-app", "--", "nautilus", "--new-window", path]
        : ["uwsm-app", "--", "nautilus", "--new-window", "--select", path]
    case "editor":
      return ["omarchy-launch-editor", path]
    case "terminal":
      return ["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + dir]
    case "copyPath":
      return ["bash", "-c", 'wl-copy -- "$1" && omarchy-notification-send -g "$3" "Path copied" "$2"', "copy-path", path, shown, glyph(0xF018F)]
    case "copyFile":
      return ["bash", "-c", 'printf "%s\\r\\n" "$1" | wl-copy --type text/uri-list && omarchy-notification-send -g "$4" "$3 copied" "$2"', "copy-file", fileUri(path), shown, item.isDir ? "Folder" : "File", glyph(0xF0191)]
    case "share":
      return ["omarchy-menu-share", item.isDir ? "folder" : "file", path]
    case "background":
      return item.kind === "image" ? ["omarchy-theme-bg-set", path] : null
    case "trash":
      return ["gio", "trash", "--", path]
  }
  return null
}

// `crmne-files apps` output: id, name, icon, default flag per line. The
// default handler comes first and is marked.
function parseApps(text) {
  var out = []
  var seen = ({})
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    var id = parts[0] || ""
    var name = parts[1] || ""
    if (!id || !name || seen[id]) continue
    seen[id] = true
    out.push({ id: id, name: name, icon: parts[2] || "", isDefault: parts[3] === "1" })
  }
  return out
}

function filterApps(apps, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return (apps || []).slice()
  var out = []
  for (var i = 0; i < (apps || []).length; i++) {
    if (String(apps[i].name).toLowerCase().indexOf(q) >= 0) out.push(apps[i])
  }
  return out
}

// Keep the cursor on the same path when results refresh under it, otherwise
// clamp it into range.
function indexAfterRefresh(rows, previousPath, previousIndex) {
  if (!rows || rows.length === 0) return 0
  if (previousPath) {
    for (var i = 0; i < rows.length; i++) if (rows[i].path === previousPath) return i
  }
  return Math.max(0, Math.min(previousIndex || 0, rows.length - 1))
}

// The helper call for what the overlay shows: a folder's listing when nothing
// is typed inside one, a search otherwise. What was typed and the folder go in
// the environment, which only the user can read, never on a command line,
// which every user on the machine can.
function searchCommand(helper, home, query, scope) {
  return {
    command: [helper, "--root", home, (!query && scope) ? "list" : "search"],
    environment: {
      CRMNE_FILES_QUERY: String(query || ""),
      CRMNE_FILES_FOLDER: String(scope || "")
    }
  }
}

// The helper call that lists the applications for Open With, the file's path
// in the environment for the same reason.
function appsCommand(helper, path) {
  return {
    command: [helper, "apps"],
    environment: { CRMNE_FILES_PATH: String(path || "") }
  }
}

// Clipboard text becomes one search line, with controls and truncated Unicode removed.
function pastedFilter(filter, value) {
  var text = String(value || "").slice(0, 4096)
    .replace(/\r\n?|\n|\t/g, " ")
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
    .replace(/\ufffd+$/, "")
  if (/[\ud800-\udbff]$/.test(text)) text = text.slice(0, -1)
  return filter + text
}

if (typeof module !== "undefined") {
  module.exports = {
    ICONS: ICONS,
    pastedFilter: pastedFilter,
    classify: classify,
    iconFor: iconFor,
    basename: basename,
    parentRel: parentRel,
    displayFolder: displayFolder,
    itemFor: itemFor,
    rootFrom: rootFrom,
    rowsFromOutput: rowsFromOutput,
    isEditable: isEditable,
    actionsFor: actionsFor,
    shortcutLabel: shortcutLabel,
    filterActions: filterActions,
    shortcutAction: shortcutAction,
    breadcrumb: breadcrumb,
    headerPlaceholder: headerPlaceholder,
    footerHint: footerHint,
    footerStatus: footerStatus,
    fileUri: fileUri,
    commandFor: commandFor,
    searchCommand: searchCommand,
    appsCommand: appsCommand,
    parseApps: parseApps,
    filterApps: filterApps,
    indexAfterRefresh: indexAfterRefresh
  }
}
