// One Magic Paste icon on every platform (Logen 2026-10-31): the web component, the iPhone/Mac asset and the Android
// vector draw the same paths, and the old icons (wand, sparkles, plain clipboard) are gone from the Magic Paste spots.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const repo = new URL("../../", import.meta.url)
const read = p => readFileSync(new URL(p, repo), "utf8")
const pathsIn = (text, attr) => [...text.matchAll(new RegExp(`${attr}="([^"]+)"`, "g"))].map(m => m[1])

test("web, iPhone/Mac and Android draw the same paths", () => {
  const web = pathsIn(read("web-vault/src/components/MagicPasteIcon.jsx"), " d")
  const apple = pathsIn(read("HavenApp/Resources/Assets.xcassets/MagicPaste.imageset/magic_paste.svg"), " d")
  const android = pathsIn(read("NostrVault/app/src/main/res/drawable/ic_magic_paste.xml"), "android:pathData")
  assert.equal(web.length, 7)
  assert.deepEqual(apple, web)
  assert.deepEqual(android, web)
  assert.match(read("HavenApp/Resources/Assets.xcassets/MagicPaste.imageset/Contents.json"), /"template-rendering-intent" : "template"/, "tinted like an SF Symbol")
})

test("every Magic Paste spot uses it", () => {
  const spots = {
    "HavenApp/HavenApp/Views/Compose/ComposeView+Chrome.swift": 'Image("MagicPaste")',
    "HavenApp/HavenApp/Views/MediaGallery/MediaGalleryToolbar.swift": 'Image("MagicPaste")',
    "HavenApp/NostrVaultWidgets/MosaicWidget.swift": 'Image("MagicPaste")',
    "NostrVault/app/src/main/java/com/nostrvault/ui/screens/compose/ComposeNoteScreen.kt": "R.drawable.ic_magic_paste",
    "NostrVault/app/src/main/java/com/nostrvault/ui/screens/mediagallery/MediaGalleryScreen.kt": "R.drawable.ic_magic_paste",
    "web-vault/src/desktop/DesktopShell.jsx": "<MagicPasteIcon",
  }
  for (const [file, use] of Object.entries(spots)) assert.ok(read(file).includes(use), file)
  for (const file of Object.keys(spots).filter(f => f.endsWith(".swift"))) assert.ok(!read(file).includes('"wand.and.stars"'), `${file}: no wand left`)
  assert.ok(!read("NostrVault/app/src/main/java/com/nostrvault/ui/screens/mediagallery/MediaGalleryScreen.kt").includes("ContentPaste"))
})
