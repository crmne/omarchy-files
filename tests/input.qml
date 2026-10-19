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
    function test_navigation_still_works() {
      files.setQuery("hello world")
      files.handleKey({key: Qt.Key_Backspace, modifiers: Qt.ControlModifier, text: ""})
      compare(files.query, "hello ")
      files.handleKey({key: Qt.Key_Escape, modifiers: Qt.NoModifier, text: ""})
      compare(files.query, "")
    }
  }
}
