const test = require("node:test")
const assert = require("node:assert/strict")
const manifest = require("../manifest.json")

test("the marketplace accepts the manifest description", () => {
  // The marketplace rejects updates whose description exceeds 500 characters.
  assert.ok(manifest.description.length <= 500, `${manifest.description.length} characters`)
})
