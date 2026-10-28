const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync, spawnSync } = require("node:child_process")
const Model = require("../FilesModel.js")

const HELPER = path.join(__dirname, "..", "bin", "crmne-files")

// Every program the helper runs, wrapped so each records its command line
// before running the real one.
const PROGRAMS = ["fzf", "gawk", "grep", "head", "find", "sort", "fd", "cut", "cksum", "mkdir", "mktemp",
  "mv", "flock", "date", "stat", "file", "xdg-mime", "gio"]

// Synthetic private names: none of these words may reach a command line.
const PRIVATE = /Taxes|retur|Secret|priv|Diary/

function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "crmne-files-test-"))
  const root = path.join(dir, "home")
  const bin = path.join(dir, "bin")
  const log = path.join(dir, "argv.log")
  for (const file of ["Taxes/2025 return.pdf", "Secret/it's private.txt", "Secret/Diary/", "Downloads/notes.md"]) {
    const full = path.join(root, file)
    if (file.endsWith("/")) fs.mkdirSync(full, { recursive: true })
    else {
      fs.mkdirSync(path.dirname(full), { recursive: true })
      fs.writeFileSync(full, "plain text\n")
    }
  }
  fs.mkdirSync(bin)
  for (const name of PROGRAMS) {
    let real = ""
    try { real = execFileSync("bash", ["-c", 'command -v "$1"', "which", name]).toString().trim() } catch (e) { continue }
    fs.writeFileSync(path.join(bin, name), `#!/bin/bash\nprintf '%s\\n' "$0 $*" >>${JSON.stringify(log)}\nexec ${JSON.stringify(real)} "$@"\n`, { mode: 0o755 })
  }
  const env = { ...process.env, PATH: bin + ":" + process.env.PATH, XDG_CACHE_HOME: path.join(dir, "cache") }
  delete env.FZF_DEFAULT_OPTS
  delete env.FZF_DEFAULT_OPTS_FILE
  return { dir, root, log, env }
}

function lines(buffer) {
  return buffer.toString().split("\n").filter(Boolean)
}

// fzf exits 1 when nothing matches, and the helper with it.
function run(command, args, options) {
  const result = spawnSync(command, args, options)
  assert.ok(result.status === 0 || result.status === 1, command + " failed: " + result.stderr)
  return lines(result.stdout)
}

function call(box, request) {
  for (const arg of request.command) assert.doesNotMatch(arg, PRIVATE)
  return run(request.command[0], request.command.slice(1), { env: { ...box.env, ...request.environment } })
}

test("no query, folder, or file name reaches a command line", () => {
  const box = sandbox()
  try {
    assert.deepEqual(lines(execFileSync(HELPER, ["--root", box.root, "index"], { env: box.env })), ["built"])

    const searched = call(box, Model.searchCommand(HELPER, box.root, "2025 retur", ""))
    assert.equal(searched[0], "Taxes/2025 return.pdf")
    assert.deepEqual(call(box, Model.searchCommand(HELPER, box.root, "it's priv", "Secret")), ["Secret/it's private.txt"])
    assert.deepEqual(call(box, Model.searchCommand(HELPER, box.root, "", "Secret")), ["Secret/Diary/", "Secret/it's private.txt"])
    const apps = call(box, Model.appsCommand(HELPER, path.join(box.root, "Secret/it's private.txt")))
    for (const app of apps) assert.equal(app.split("\t").length, 4)

    const argv = fs.readFileSync(box.log, "utf8")
    assert.match(argv, /\/fd /, "the index ran through fd")
    assert.match(argv, /\/fzf /, "the search ran through fzf")
    assert.match(argv, /\/file /, "Open With looked up the file's type")
    assert.doesNotMatch(argv, PRIVATE)
  } finally {
    fs.rmSync(box.dir, { recursive: true, force: true })
  }
})

test("a typed path lists any folder, filtered, with hidden names only when asked for", () => {
  const box = sandbox()
  try {
    const outside = path.join(box.dir, "Secret elsewhere")
    fs.mkdirSync(path.join(outside, "Diary"), { recursive: true })
    fs.mkdirSync(path.join(outside, ".private"))
    fs.writeFileSync(path.join(outside, "it's private.txt"), "")
    fs.writeFileSync(path.join(outside, ".gitignore"), "*.txt\n")
    fs.symlinkSync(path.join(outside, "Diary"), path.join(outside, "linked"))
    const prefix = outside + "/"
    const browse = query => call(box, Model.searchCommand(HELPER, box.root, prefix + query, ""))

    assert.deepEqual(browse(""), [prefix, prefix + "Diary/", prefix + "linked/", prefix + "it's private.txt"])
    assert.deepEqual(browse("priv"), [prefix + "it's private.txt"])
    assert.deepEqual(browse(".pri"), [prefix + ".private/"])
    // A name typed in full leads, ahead of longer names fzf ranks first.
    fs.mkdirSync(path.join(outside, "Diary archive"))
    fs.writeFileSync(path.join(outside, "linked-Diary"), "")
    assert.equal(browse("Diary")[0], prefix + "Diary/")
    const missing = Model.searchCommand(HELPER, box.root, "/no such folder/x", "")
    assert.equal(spawnSync(missing.command[0], missing.command.slice(1), { env: { ...box.env, ...missing.environment } }).status, 4)
    assert.doesNotMatch(fs.readFileSync(box.log, "utf8"), PRIVATE)
  } finally {
    fs.rmSync(box.dir, { recursive: true, force: true })
  }
})

test("a query matches as it would on fzf's command line, whatever its quotes and symbols", () => {
  const box = sandbox()
  try {
    fs.writeFileSync(path.join(box.root, `odd 'quote' "double" $(x) \\back.txt`), "")
    execFileSync(HELPER, ["--root", box.root, "index"], { env: box.env })
    const index = fs.readdirSync(path.join(box.env.XDG_CACHE_HOME, "crmne-files")).find(name => /^index-\d+$/.test(name))
    const indexed = fs.readFileSync(path.join(box.env.XDG_CACHE_HOME, "crmne-files", index))

    for (const query of [`'quote' "double"`, "$(x) \\back", "'", "''", "--help", "2025 return", "!notes", "no such file"]) {
      const expected = run("fzf", ["--filter=" + query, "--tiebreak=index"], { input: indexed, env: box.env })
      assert.deepEqual(call(box, Model.searchCommand(HELPER, box.root, query, "")), expected.slice(0, 200), query)
    }
  } finally {
    fs.rmSync(box.dir, { recursive: true, force: true })
  }
})

test("exclusions apply to both indexes and browsing, and cached paths stay private", () => {
  const box = sandbox()
  try {
    const filtered = { ...box.env, CRMNE_FILES_EXCLUDES: "Secret" }
    execFileSync(HELPER, ["--root", box.root, "index"], {env: filtered})
    const rows = run(HELPER, ["--root", box.root, "search"], {env: filtered})
    assert.ok(rows.every(row => !row.startsWith("Secret")))
    const listed = run(HELPER, ["--root", box.root, "list"], {env: filtered})
    assert.ok(!listed.includes("Secret/"))
    const unfiltered = {...box.env, CRMNE_FILES_EXCLUDES: ""}
    assert.equal(spawnSync(HELPER, ["--root", box.root, "search"], {env: unfiltered}).status, 3)
    execFileSync(HELPER, ["--root", box.root, "index"], {env: unfiltered})
    assert.ok(run(HELPER, ["--root", box.root, "search"], {env: unfiltered}).some(row => row.startsWith("Secret/")))
    const cache = path.join(box.env.XDG_CACHE_HOME, "crmne-files")
    assert.equal(fs.statSync(cache).mode & 0o777, 0o700)
    for (const name of fs.readdirSync(cache)) assert.equal(fs.statSync(path.join(cache,name)).mode & 0o077, 0)
  } finally { fs.rmSync(box.dir, {recursive:true, force:true}) }
})
