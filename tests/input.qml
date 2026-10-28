import QtQuick
import QtTest
import Quickshell
import "plugin" as Plugin

ShellRoot {
  Plugin.Files { id: files }
  TestCase {
    name: "FilesInput"
    when: true
    function cleanupTestCase() {
      console.log("FILES INPUT RESULTS", qtest_results.passCount, "passed", qtest_results.failCount, "failed")
      Qt.callLater(Qt.quit)
    }
    function init() {
      files.open(JSON.stringify({root: Quickshell.env("FILES_TEST_HOME")}))
      wait(100)
    }
    function cleanup() { console.log("TEST", qtest_results.functionName, qtest_results.failed ? "FAILED" : "PASSED"); files.close(); wait(100) }
    function paste(key, modifiers) {
      verify(files.handleKey({key: key, modifiers: modifiers, text: ""}))
    }
    function test_paste_is_explicit_bounded_and_clean() {
      wait(200)
      compare(files.query, "")
      paste(Qt.Key_V, Qt.ControlModifier)
      tryVerify(function() { return files.query.length > 0 }, 4000)
      verify(files.query.indexOf("line one two") === 0)
      verify(files.query.length <= 4096)
      verify(!/[\u0000-\u001f]/.test(files.query))
    }
    function test_shift_insert_filters_actions() {
      files.view = "actions"
      paste(Qt.Key_Insert, Qt.ShiftModifier)
      tryVerify(function() { return files.actionQuery.length > 0 }, 4000)
      compare(files.query, "")
    }
    function test_delayed_paste_discarded_after_edit() {
      paste(Qt.Key_V, Qt.ControlModifier)
      files.setQuery("edited")
      wait(800)
      compare(files.query, "edited")
    }
    function test_delayed_paste_discarded_after_close_and_reopen() {
      paste(Qt.Key_V, Qt.ControlModifier)
      files.close()
      files.open(JSON.stringify({root: Quickshell.env("FILES_TEST_HOME"), query: "new"}))
      wait(800)
      compare(files.query, "new")
    }
    function test_stalled_provider_stops_and_does_not_insert() {
      var proc = findChild(files, "clipboardPaste")
      verify(proc !== null)
      var original = proc.command
      proc.command = ["timeout", "-k", "1", "2", "sh", "-c", "printf partial; sleep 30"]
      paste(Qt.Key_V, Qt.ControlModifier)
      tryCompare(proc, "running", false, 4000)
      compare(files.query, "")
      proc.command = original
    }
    function test_caret_visible_when_open_and_blinks() {
      tryVerify(function() { return JSON.parse(files.state()).inputFocused }, 1000)
      tryVerify(function() { return JSON.parse(files.state()).caretVisible }, 1000)
      tryVerify(function() { return !JSON.parse(files.state()).caretVisible }, 1000)
      files.setQuery("typed")
      tryVerify(function() { return JSON.parse(files.state()).caretVisible }, 1000)
    }
    function test_settings_flip_preserves_search_and_saves() {
      files.setQuery("notes")
      files.flipSettings()
      tryCompare(files, "settingsVisible", true, 1000)
      var settings = findChild(files, "filesSettings")
      verify(settings !== null)
      var folder = findChild(settings, "searchLocation")
      folder.text = Quickshell.env("FILES_TEST_HOME")
      findChild(settings, "excludedFolders").text = "ignored, build"
      settings.previewEnabled = false
      settings.save()
      tryCompare(settings, "saving", false, 4000)
      tryCompare(settings, "message", "Settings saved.", 4000)
      compare(files.preferences.excludes.join(","), "ignored,build")
      wait(250)
      files.flipSettings()
      tryCompare(files, "settingsVisible", false, 1000)
      compare(files.query, "notes")
      tryVerify(function() { return JSON.parse(files.state()).inputFocused }, 1000)
    }
    function key(k, modifiers, text) {
      return files.handleKey({key: k, modifiers: modifiers || Qt.NoModifier, text: text || ""})
    }
    function type(text) {
      for (var i = 0; i < text.length; i++) verify(key(0, Qt.NoModifier, text[i]))
    }
    function test_typed_path_browses_outside_the_search_folder() {
      var outside = Quickshell.env("FILES_TEST_OUTSIDE")
      files.setQuery(outside + "/no")
      tryVerify(function() { return JSON.parse(files.state()).selected === outside + "/notes" }, 4000)
      compare(files.currentItem.absolute, true)
      // A folder typed with its slash leads with itself, so Enter opens it.
      files.setQuery(outside + "/")
      tryVerify(function() { return JSON.parse(files.state()).selected === outside }, 4000)
      verify(key(Qt.Key_Down))
      compare(JSON.parse(files.state()).selected, outside + "/inside")
      verify(key(Qt.Key_Right))
      compare(files.query, outside + "/inside/")
      verify(key(Qt.Key_Backspace, Qt.ControlModifier))
      compare(files.query, outside + "/")
      verify(key(Qt.Key_Backspace, Qt.ControlModifier))
      compare(files.query, outside.replace(/[^/]+$/, ""))
    }
    function test_the_filter_edits_like_a_text_field() {
      // Copy and cut write the session clipboard; put back what was there.
      var saved = Quickshell.clipboardText
      try { editing() } finally { Quickshell.clipboardText = saved }
    }
    function editing() {
      type("hello world")
      compare(files.caret, 11)
      verify(key(Qt.Key_Left, Qt.ControlModifier))
      compare(files.caret, 6)
      type("big ")
      compare(files.query, "hello big world")
      verify(key(Qt.Key_Home))
      verify(key(Qt.Key_Right, Qt.ShiftModifier))
      verify(key(Qt.Key_Right, Qt.ShiftModifier))
      // Copy takes the selected text, not the selected file's path.
      verify(key(Qt.Key_X, Qt.ControlModifier))
      compare(files.query, "llo big world")
      compare(Quickshell.clipboardText, "he")
      verify(key(Qt.Key_Z, Qt.ControlModifier))
      compare(files.query, "hello big world")
      verify(key(Qt.Key_A, Qt.ControlModifier))
      verify(key(Qt.Key_C, Qt.ControlModifier))
      compare(Quickshell.clipboardText, "hello big world")
      type("x")
      compare(files.query, "x")
      verify(key(Qt.Key_End))
      verify(key(Qt.Key_Delete))
      compare(files.query, "x")
      verify(key(Qt.Key_Left))
      verify(key(Qt.Key_Delete))
      compare(files.query, "")
    }
    function test_arrows_navigate_only_at_the_ends_of_the_text() {
      files.setQuery("notes")
      tryVerify(function() { return JSON.parse(files.state()).selected === "notes.txt" }, 4000)
      verify(key(Qt.Key_Left))
      compare(files.caret, 4)
      compare(files.view, "results")
      verify(key(Qt.Key_End))
      verify(key(Qt.Key_Right))
      compare(files.view, "actions")
      verify(key(Qt.Key_Left))
      compare(files.view, "results")
    }
    function test_navigation_still_works() {
      files.setQuery("hello world")
      files.handleKey({key: Qt.Key_Backspace, modifiers: Qt.ControlModifier, text: ""})
      compare(files.query, "hello ")
      files.handleKey({key: Qt.Key_Escape, modifiers: Qt.NoModifier, text: ""})
      compare(files.query, "")
    }
  }
}
