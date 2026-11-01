// The welcome screen's Get the app (components/get-app.js): a phone visitor gets the native app for their device,
// iPhone and iPad the TestFlight beta, Android Zapstore; a computer gets no button.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { appDownload, TESTFLIGHT, ZAPSTORE } from "../src/components/get-app.js"

const UA = {
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
  ipadOld: "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
  mac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
  android: "Mozilla/5.0 (Linux; Android 15; moto g) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
  windows: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
}

test("an iPhone gets TestFlight, with a line saying what TestFlight is", () => {
  const a = appDownload(UA.iphone, 5)
  assert.equal(a.url, TESTFLIGHT)
  assert.equal(a.label, "Get the app for iPhone")
  assert.match(a.line, /TestFlight/)
})

test("an iPad gets TestFlight, including iPadOS Safari that says Macintosh", () => {
  assert.equal(appDownload(UA.ipadOld, 5).url, TESTFLIGHT)
  assert.equal(appDownload(UA.mac, 5).label, "Get the app for iPad")
})

test("an Android phone gets Zapstore", () => {
  const a = appDownload(UA.android, 5)
  assert.equal(a.url, ZAPSTORE)
  assert.equal(a.label, "Get the app for Android")
  assert.match(a.line, /Zapstore/)
})

test("a computer gets no button: a Mac (no touch) and Windows", () => {
  assert.equal(appDownload(UA.mac, 0), null)
  assert.equal(appDownload(UA.windows, 0), null)
})

test("the welcome screen shows it above the ways in, as a link that opens the download", () => {
  const src = readFileSync(new URL("../src/screens/WelcomeScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /const app = appDownload\(\)/)
  const actions = src.indexOf('class="welcome-actions"')
  const get = src.indexOf('class="welcome-door welcome-get" href={app.url}')
  assert.ok(actions > 0 && get > actions && get < src.indexOf(">Create an account<"))
})
