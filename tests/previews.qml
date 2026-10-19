import QtQuick
import QtTest
import Quickshell
import "plugin" as Plugin
ShellRoot {
  Plugin.Preview {
    id: preview
    width: 330; height: 500
    helper: Quickshell.env("FILES_TEST_SOURCE") + "/bin/files-support"
    searchRoot: Quickshell.env("FILES_TEST_HOME")
  }
  TestCase {
    name: "FilePreviews"
    when: true
    function init() { preview.active = true }
    function cleanup() { console.log("TEST",qtest_results.functionName,qtest_results.failed ? "FAILED" : "PASSED"); preview.active = false; wait(100) }
    function cleanupTestCase() { console.log("FILES PREVIEW RESULTS",qtest_results.passCount,"passed",qtest_results.failCount,"failed"); Qt.callLater(Qt.quit) }
    function select(name, kind) {
      preview.path = preview.searchRoot + "/" + name
      tryVerify(function() { return preview.result.kind === kind },5000)
    }
    function test_pdf_pages() {
      select("pages.pdf","pdf")
      compare(preview.result.pages,2)
      var first = preview.result.image
      preview.page = 2; preview.refresh(false)
      tryVerify(function() { return preview.result.page === 2 },5000)
      verify(preview.result.image !== first)
    }
    function test_audio_is_explicit_and_stops_when_selection_changes() {
      select("tone.wav","audio")
      var audio = findChild(preview,"previewAudio")
      verify(!audio.running)
      preview.seek(1)
      compare(preview.position,1)
      preview.playAudio()
      tryCompare(audio,"running",true,1000)
      select("code.py","text")
      tryCompare(audio,"running",false,1000)
      compare(preview.playbackError,"")
    }
    function test_highlighting_escapes_markup_and_cache_clears_on_close() {
      select("code.py","text")
      verify(preview.result.tokens.length > 0)
      var markup = preview.highlighted()
      verify(markup.indexOf("<img") === -1)
      verify(markup.indexOf("&lt;img") !== -1)
      verify(preview.cacheOrder.length > 0)
      preview.active = false
      compare(preview.cacheOrder.length,0)
    }
    function test_neovim_colors_are_used_and_validated() {
      preview.result = {tokens: [["keyword", "return", "#123abc"], ["string", "<img>", '\" bad=\"']]}
      var markup = preview.highlighted()
      verify(markup.indexOf('color="#123abc"') !== -1)
      verify(markup.indexOf('bad=') === -1)
      verify(markup.indexOf('&lt;img&gt;') !== -1)
    }
    function test_stale_selection_is_discarded() {
      preview.path = preview.searchRoot + "/pages.pdf"
      select("code.py","text")
      wait(400)
      compare(preview.result.name,"code.py")
    }
  }
}
