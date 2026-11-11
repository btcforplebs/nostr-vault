package com.nostrvault.fips

/**
 * The pages the in-app browser writes itself for a mesh site: why it can't be read, or where it sends you
 * (iOS/Mac: FipsSchemeHandler.MeshPage). Plain HTML, no script.
 */
enum class MeshPage(val title: String, val detail: String, val retries: Boolean = false) {
    MeshOff("The mesh is off", "Turn it on in Settings → FIPS Mesh to open .fips sites."),
    EngineOff("The mesh isn't running", "The mesh is on but didn't start. Open Settings → FIPS Mesh to see why.", retries = true),
    NoSeeds(
        "No middle server",
        "The middle server is set to None, so this device has no way to reach sites outside your own devices. " +
            "Choose a middle server in Settings → FIPS Mesh → Advanced.",
    ),
    NotReady("Mesh not ready", "The mesh is still finding its way onto the network. Try again in a moment.", retries = true),
    Failed("The mesh didn't open", "Something stopped the mesh from opening a connection. Try again in a moment.", retries = true),
    Unreachable(
        "Can't reach this site",
        "The site didn't answer over the mesh. It may be offline, or not on the same mesh as this device.",
        retries = true,
    ),
    Refused(
        "This address can't open here",
        "Only addresses in the form npub….fips open here, and only on port 80. They never go to the internet.",
    ),
    TooBig("This page is too big", "It went past what one page may load over the mesh."),
    ReadOnly("Reading only", ".fips sites open for reading here; forms that send data can't be used."),
    OldWebView(
        "Update Android System WebView",
        "This phone's WebView is too old to keep a mesh page off the internet, so .fips sites can't open. " +
            "Update Android System WebView from the Play Store.",
    ),
    ;

    companion object {
        fun of(reply: MeshSiteIngress): MeshPage = when (reply) {
            MeshSiteIngress.MeshOff -> MeshOff
            MeshSiteIngress.EngineOff -> EngineOff
            MeshSiteIngress.NoSeeds -> NoSeeds
            MeshSiteIngress.NotReady -> NotReady
            MeshSiteIngress.Failed, is MeshSiteIngress.Ready -> Failed
        }

        private const val STYLE = ":root{color-scheme:dark}" +
            "body{font:17px system-ui,sans-serif;background:#111;color:#eee;margin:0;" +
            "display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center}" +
            "main{max-width:30em;padding:2em}h1{font-size:1.3em;margin:0 0 .6em}p{color:#aaa;line-height:1.45}" +
            "code{color:#777;font-size:.8em;word-break:break-all}" +
            ".b{display:inline-block;margin-top:.6em;padding:.55em 1.2em;border-radius:999px;background:#2a2a2e;color:#fff;text-decoration:none}"

        private fun shell(title: String, body: String, head: String = "") =
            "<!doctype html><html><head><meta charset=\"utf-8\">" +
                "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">$head" +
                "<title>${FipsUrl.htmlEscaped(title)}</title><style>$STYLE</style></head><body><main>$body</main></body></html>"

        /** [page] for [url] (the site address the reader asked for). */
        fun html(page: MeshPage, url: String): String {
            val u = FipsUrl.htmlEscaped(url)
            val retry = if (page.retries) "<p><a class=\"b\" href=\"$u\">Try again</a></p>" else ""
            return shell(page.title, "<h1>${FipsUrl.htmlEscaped(page.title)}</h1><p>${FipsUrl.htmlEscaped(page.detail)}</p>$retry<p><code>$u</code></p>")
        }

        /** A mesh page that redirects to the internet: said, not followed. Its link is a tap, so it asks first. */
        fun leaveHtml(target: String): String {
            val t = FipsUrl.htmlEscaped(target)
            val host = FipsUrl.htmlEscaped(FipsUrl.hostOf(target) ?: target)
            return shell(
                "Leaves the mesh",
                "<h1>This page sends you to $host</h1><p>That's on the internet, not the mesh: the site would see your IP address.</p>" +
                    "<p><a class=\"b\" href=\"$t\">Open on the web</a></p><p><code>$t</code></p>",
            )
        }

        /** A redirect to another page of the same mesh site: the WebView moves, so the bar and history follow. */
        fun redirectHtml(target: String): String =
            "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=${FipsUrl.htmlEscaped(target)}\">" +
                "</head><body style=\"background:#111\"></body></html>"
    }
}
